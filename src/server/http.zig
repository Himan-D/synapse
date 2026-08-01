const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const workspace_mod = @import("../core/workspace.zig");
const mcp_mod = @import("mcp.zig");

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

    if (method == .GET and pathOnly(target, "/health")) {
        try request.respond("{\"ok\":true}\n", .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    if (method == .POST and std.mem.startsWith(u8, pathOnlyStr(target), "/v1/events/")) {
        const path = pathOnlyStr(target);
        const ds = path["/v1/events/".len..];
        const body = try readBody(allocator, &request);
        defer allocator.free(body);
        const n = try ws.store.ingestNdjson(ds, body);
        var resp_buf: [64]u8 = undefined;
        const resp = try std.fmt.bufPrint(&resp_buf, "{{\"ingested\":{d}}}\n", .{n});
        try request.respond(resp, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    if (method == .GET and std.mem.startsWith(u8, pathOnlyStr(target), "/v1/pipes/")) {
        const path = pathOnlyStr(target);
        const name = path["/v1/pipes/".len..];
        return runAlias(allocator, &request, ws, name, target);
    }

    if (method == .GET and std.mem.startsWith(u8, pathOnlyStr(target), "/v1/recall")) {
        return runAlias(allocator, &request, ws, "recall_context", target);
    }
    if (method == .GET and std.mem.startsWith(u8, pathOnlyStr(target), "/v1/metrics/tool_failure_rate")) {
        return runAlias(allocator, &request, ws, "tool_failure_rate", target);
    }
    if (method == .GET and std.mem.startsWith(u8, pathOnlyStr(target), "/v1/impact")) {
        return runAlias(allocator, &request, ws, "blast_radius", target);
    }

    if (method == .POST and pathOnly(target, "/v1/mcp")) {
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

fn pathOnly(target: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, pathOnlyStr(target), want);
}

fn pathOnlyStr(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[0..i];
    return target;
}

fn runAlias(
    allocator: Allocator,
    request: *std.http.Server.Request,
    ws: *workspace_mod.Workspace,
    pipe_name: []const u8,
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
    try request.respond(result.json, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

fn parseQuery(allocator: Allocator, query: []const u8, params: *std.StringHashMapUnmanaged([]const u8)) !void {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = try allocator.dupe(u8, pair[0..eq]);
        const val = try allocator.dupe(u8, pair[eq + 1 ..]);
        try params.put(allocator, key, val);
    }
}

fn readBody(allocator: Allocator, request: *std.http.Server.Request) ![]u8 {
    var transfer_buf: [8 * 1024]u8 = undefined;
    const body_reader = request.readerExpectContinue(&transfer_buf) catch {
        return try allocator.dupe(u8, "");
    };
    const bytes = body_reader.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.StreamTooLong,
    };
    return bytes;
}
