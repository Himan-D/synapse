const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const workspace_mod = @import("../core/workspace.zig");
const mcp_mod = @import("mcp.zig");
const format_mod = @import("../core/format.zig");
const query_mod = @import("../core/query.zig");

pub fn serve(allocator: Allocator, io: Io, ws: *workspace_mod.Workspace, port: u16) !void {
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("synapse listening on http://127.0.0.1:{d}", .{port});

    while (true) {
        var stream = server.accept(io) catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        handleConn(allocator, io, ws, &stream) catch |err| {
            std.log.err("request failed: {s}", .{@errorName(err)});
        };
        stream.close(io);
    }
}

fn handleConn(allocator: Allocator, io: Io, ws: *workspace_mod.Workspace, stream: *Io.net.Stream) !void {
    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &in_buf);
    var stream_writer = stream.writer(io, &out_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = try http_server.receiveHead();

    const method = request.head.method;
    const target = request.head.target;
    const path = pathOnlyStr(target);

    if (method == .GET and std.mem.eql(u8, path, "/health")) {
        try request.respond("{\"ok\":true,\"product\":\"synapse\"}\n", .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    // Optional Bearer auth: set SYNAPSE_REQUIRE_AUTH=1 to enforce scoped tokens.
    const require_auth = blk: {
        if (std.c.getenv("SYNAPSE_REQUIRE_AUTH")) |v| {
            const s = std.mem.span(v);
            break :blk std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true");
        }
        break :blk false;
    };
    if (require_auth and !ws.authorize(request.head_buffer, method, path)) {
        try request.respond("{\"error\":\"unauthorized\"}\n", .{
            .status = .unauthorized,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    if (method == .GET and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/ui") or std.mem.eql(u8, path, "/ui/"))) {
        const html = try loadUiHtml(allocator, io, ws.root);
        defer allocator.free(html);
        try request.respond(html, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
        return;
    }

    if (method == .GET and std.mem.eql(u8, path, "/v1/workspace")) {
        const json = try ws.listPipesJson(allocator);
        defer allocator.free(json);
        try request.respond(json, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    if (method == .GET and std.mem.eql(u8, path, "/v1/endpoints")) {
        const json = try ws.listEndpointsJson(allocator);
        defer allocator.free(json);
        try request.respond(json, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    if (method == .POST and std.mem.startsWith(u8, path, "/v1/events/")) {
        const ds = path["/v1/events/".len..];
        const body = try readBody(allocator, &request);
        defer allocator.free(body);
        const n = try ws.store.ingestNdjson(ds, body);
        ws.runMaterializedPipes() catch {};
        ws.logOp("ingest", ds, "ok");
        var resp_buf: [64]u8 = undefined;
        const resp = try std.fmt.bufPrint(&resp_buf, "{{\"ingested\":{d}}}\n", .{n});
        try request.respond(resp, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    if (method == .POST and std.mem.eql(u8, path, "/v1/query")) {
        const body = try readBody(allocator, &request);
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const ds = obj.get("datasource").?.string;
        var where: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer {
            var wit = where.iterator();
            while (wit.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            where.deinit(allocator);
        }
        if (obj.get("where")) |w| {
            var it = w.object.iterator();
            while (it.next()) |e| {
                try where.put(allocator, try allocator.dupe(u8, e.key_ptr.*), try allocator.dupe(u8, e.value_ptr.string));
            }
        }
        const limit: usize = if (obj.get("limit")) |l| switch (l) {
            .integer => |i| @intCast(i),
            else => 100,
        } else 100;
        const offset: usize = if (obj.get("offset")) |o| switch (o) {
            .integer => |i| @intCast(i),
            else => 0,
        } else 0;
        const json = try query_mod.runQuery(allocator, &ws.store, ds, where, limit, offset);
        defer allocator.free(json);
        ws.logOp("query", ds, "ok");
        try request.respond(json, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    if (method == .GET and std.mem.startsWith(u8, path, "/v1/datasources/") and std.mem.endsWith(u8, path, "/data")) {
        // /v1/datasources/{name}/data?...
        const mid = path["/v1/datasources/".len .. path.len - "/data".len];
        return runDatasourceQuery(allocator, &request, ws, mid, target);
    }

    if (method == .POST and std.mem.eql(u8, path, "/v1/remember")) {
        const body = try readBody(allocator, &request);
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const run_id = obj.get("run_id").?.string;
        const agent_id = if (obj.get("agent_id")) |a| a.string else "agent";
        const text = obj.get("text").?.string;
        const confidence: f32 = if (obj.get("confidence")) |c| switch (c) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => 0.8,
        } else 0.8;
        const json = try ws.remember(run_id, agent_id, text, confidence);
        defer allocator.free(json);
        ws.logOp("remember", run_id, "ok");
        try request.respond(json, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    if (method == .GET and std.mem.startsWith(u8, path, "/v1/pipes/")) {
        const tail = path["/v1/pipes/".len..];
        const split = format_mod.splitNameFormat(tail);
        return runAlias(allocator, &request, ws, split.name, target, split.format);
    }

    if (method == .GET and std.mem.eql(u8, path, "/v1/recall")) {
        return runAlias(allocator, &request, ws, "recall_context", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/metrics/tool_failure_rate")) {
        return runAlias(allocator, &request, ws, "tool_failure_rate", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/impact")) {
        return runAlias(allocator, &request, ws, "blast_radius", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/plan")) {
        return runAlias(allocator, &request, ws, "plan_goal", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/route")) {
        return runAlias(allocator, &request, ws, "route_query", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/dispute")) {
        return runAlias(allocator, &request, ws, "find_contradictions", target, null);
    }
    if (method == .POST and std.mem.eql(u8, path, "/v1/dispute")) {
        const body = try readBody(allocator, &request);
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const json = try ws.writeDispute(
            obj.get("run_id").?.string,
            obj.get("a").?.string,
            obj.get("b").?.string,
            if (obj.get("reason")) |r| r.string else "manual",
        );
        defer allocator.free(json);
        try request.respond(json, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/graph")) {
        const qmark = std.mem.indexOfScalar(u8, target, '?');
        const query = if (qmark) |i| target[i + 1 ..] else "";
        var params: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer {
            var it = params.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            params.deinit(allocator);
        }
        try parseQuery(allocator, query, &params);
        const json = try ws.graphJson(allocator, params.get("run_id") orelse "");
        defer allocator.free(json);
        try request.respond(json, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/embed")) {
        return runAlias(allocator, &request, ws, "embed_recall", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/diff")) {
        return runAlias(allocator, &request, ws, "diff_run", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/consolidate")) {
        return runAlias(allocator, &request, ws, "consolidate_claims", target, null);
    }
    if (method == .POST and std.mem.eql(u8, path, "/v1/checkpoint")) {
        const body = try readBody(allocator, &request);
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const name = obj.get("name").?.string;
        const ds = if (obj.get("datasource")) |d| d.string else "harness_events";
        const json = try ws.checkpoint(name, ds);
        defer allocator.free(json);
        try request.respond(json, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }
    if (method == .POST and std.mem.eql(u8, path, "/v1/reload")) {
        try ws.reloadPipes();
        try request.respond("{\"reloaded\":true}\n", .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    if (method == .POST and std.mem.eql(u8, path, "/v1/mcp")) {
        const body = try readBody(allocator, &request);
        defer allocator.free(body);
        const resp = try mcp_mod.handle(allocator, ws, body);
        defer allocator.free(resp);
        try request.respond(resp, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    try request.respond("{\"error\":\"not_found\"}\n", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

fn pathOnlyStr(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[0..i];
    return target;
}

fn runDatasourceQuery(
    allocator: Allocator,
    request: *std.http.Server.Request,
    ws: *workspace_mod.Workspace,
    ds: []const u8,
    target: []const u8,
) !void {
    const qmark = std.mem.indexOfScalar(u8, target, '?');
    const query = if (qmark) |i| target[i + 1 ..] else "";
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = params.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        params.deinit(allocator);
    }
    try parseQuery(allocator, query, &params);

    var where: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = where.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        where.deinit(allocator);
    }
    var it = params.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "limit") or std.mem.eql(u8, e.key_ptr.*, "offset") or std.mem.eql(u8, e.key_ptr.*, "format")) continue;
        try where.put(allocator, try allocator.dupe(u8, e.key_ptr.*), try allocator.dupe(u8, e.value_ptr.*));
    }
    const limit = query_mod.parseLimit(params, 100);
    const offset = query_mod.parseOffset(params);
    const json = try query_mod.runQuery(allocator, &ws.store, ds, where, limit, offset);
    defer allocator.free(json);
    ws.logOp("query", ds, "ok");
    try request.respond(json, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

fn runAlias(
    allocator: Allocator,
    request: *std.http.Server.Request,
    ws: *workspace_mod.Workspace,
    pipe_name: []const u8,
    target: []const u8,
    path_format: ?format_mod.Format,
) !void {
    const qmark = std.mem.indexOfScalar(u8, target, '?');
    const query = if (qmark) |i| target[i + 1 ..] else "";
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = params.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        params.deinit(allocator);
    }
    try parseQuery(allocator, query, &params);

    var format = path_format orelse format_mod.Format.json;
    if (params.get("format")) |f| {
        if (format_mod.Format.fromString(f)) |ff| format = ff;
    }

    var result = ws.runPipe(pipe_name, params) catch {
        try request.respond("{\"error\":\"pipe_not_found\"}\n", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    };
    defer result.deinit();

    const limit_opt: ?usize = if (params.get("limit") != null) query_mod.parseLimit(params, 100) else null;
    const offset = query_mod.parseOffset(params);
    const paged = try query_mod.applyPagination(allocator, result.json, limit_opt, offset);
    defer allocator.free(paged);

    const body = try format_mod.convert(allocator, paged, format);
    defer allocator.free(body);

    ws.logOp("endpoint", pipe_name, @tagName(format));
    try request.respond(body, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = format.contentType() },
        },
    });
}

fn parseQuery(allocator: Allocator, query: []const u8, params: *std.StringHashMapUnmanaged([]const u8)) !void {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = try allocator.dupe(u8, pair[0..eq]);
        const val_raw = pair[eq + 1 ..];
        var val_buf: std.ArrayList(u8) = .empty;
        defer val_buf.deinit(allocator);
        var i: usize = 0;
        while (i < val_raw.len) : (i += 1) {
            if (val_raw[i] == '+') {
                try val_buf.append(allocator, ' ');
            } else if (val_raw[i] == '%' and i + 2 < val_raw.len) {
                const hex = val_raw[i + 1 .. i + 3];
                const byte = std.fmt.parseInt(u8, hex, 16) catch {
                    try val_buf.append(allocator, val_raw[i]);
                    continue;
                };
                try val_buf.append(allocator, byte);
                i += 2;
            } else {
                try val_buf.append(allocator, val_raw[i]);
            }
        }
        const val = try allocator.dupe(u8, val_buf.items);
        try params.put(allocator, key, val);
    }
}

fn readBody(allocator: Allocator, request: *std.http.Server.Request) ![]u8 {
    var transfer_buf: [8 * 1024]u8 = undefined;
    const body_reader = request.readerExpectContinue(&transfer_buf) catch {
        return try allocator.dupe(u8, "");
    };
    return body_reader.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.StreamTooLong,
    };
}

fn loadUiHtml(allocator: Allocator, io: Io, workspace_root: []const u8) ![]u8 {
    _ = workspace_root;
    // Prefer repo web/ relative to cwd, then embedded fallback.
    const candidates = [_][]const u8{ "web/index.html", "ui/index.html" };
    for (candidates) |p| {
        if (Io.Dir.cwd().readFileAlloc(io, p, allocator, .unlimited)) |bytes| return bytes else |_| {}
    }
    return try allocator.dupe(u8,
        \\<!doctype html><html><body style="font-family:system-ui;padding:2rem">
        \\<h1>Synapse</h1><p>Place <code>web/index.html</code> next to the binary cwd for the playground.</p>
        \\<p><a href="/v1/workspace">/v1/workspace</a></p></body></html>
    );
}
