const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const workspace_mod = @import("../core/workspace.zig");
const hub_mod = @import("../core/workspace_hub.zig");
const mcp_mod = @import("mcp.zig");
const format_mod = @import("../core/format.zig");
const query_mod = @import("../core/query.zig");
const version_mod = @import("../core/version.zig");
const safe_name = @import("../core/safe_name.zig");
const ratelimit_mod = @import("../core/ratelimit.zig");
const auth_mod = @import("../core/auth.zig");

pub const max_body_bytes: usize = 16 * 1024 * 1024;

pub const ServeConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8787,
    max_body_bytes: usize = max_body_bytes,
};

var g_listen_fd: std.atomic.Value(std.posix.socket_t) = .init(-1);
var g_shutdown: std.atomic.Value(bool) = .init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    g_shutdown.store(true, .seq_cst);
    const fd = g_listen_fd.load(.seq_cst);
    if (fd >= 0) {
        _ = std.c.shutdown(fd, std.posix.SHUT.RDWR);
    }
}

fn installSignalHandlers() void {
    if (std.posix.Sigaction == void) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "::1");
}

fn envTruthy(name: [*:0]const u8) bool {
    if (std.c.getenv(name)) |v| {
        const s = std.mem.span(v);
        return std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true");
    }
    return false;
}

fn envRateLimit() f64 {
    if (std.c.getenv("SYNAPSE_RATE_LIMIT")) |v| {
        return std.fmt.parseFloat(f64, std.mem.span(v)) catch 0;
    }
    return 0;
}

fn pipesDirMtime(io: Io, root: []const u8) i128 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const pipes_dir = std.fmt.bufPrint(&path_buf, "{s}/pipes", .{root}) catch return 0;
    var dir = Io.Dir.cwd().openDir(io, pipes_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var newest: i128 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pipe.json")) continue;
        var fpath: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&fpath, "{s}/{s}", .{ pipes_dir, entry.name }) catch continue;
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        const ns = st.mtime.toNanoseconds();
        if (ns > newest) newest = ns;
    }
    return newest;
}

fn maybeReloadPipes(io: Io, ws: *workspace_mod.Workspace, last_mtime: *i128) void {
    const m = pipesDirMtime(io, ws.root);
    if (m == 0 or m <= last_mtime.*) return;
    last_mtime.* = m;
    ws.reloadPipes() catch |err| {
        std.log.warn("pipe reload failed: {s}", .{@errorName(err)});
        return;
    };
    std.log.info("pipes reloaded (mtime watch)", .{});
}

// ── Single-workspace serve (dev mode) ────────────────────────────────────────

pub fn serve(allocator: Allocator, io: Io, ws: *workspace_mod.Workspace, config: ServeConfig) !void {
    g_shutdown.store(false, .seq_cst);
    installSignalHandlers();

    const address = try Io.net.IpAddress.parseIp4(config.host, config.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    g_listen_fd.store(server.socket.handle, .seq_cst);
    defer g_listen_fd.store(-1, .seq_cst);

    if (!isLoopbackHost(config.host) and !envTruthy("SYNAPSE_REQUIRE_AUTH")) {
        std.log.warn("binding {s}:{d} without SYNAPSE_REQUIRE_AUTH=1 — tokens not enforced", .{ config.host, config.port });
    }
    std.log.info("synapse listening on http://{s}:{d} version={s}", .{ config.host, config.port, version_mod.version });

    var limiter: ?ratelimit_mod.Limiter = null;
    const rate = envRateLimit();
    if (rate > 0) {
        limiter = ratelimit_mod.Limiter.init(allocator, rate, @max(rate, 1));
        std.log.info("rate limit enabled: {d:.1} req/s", .{rate});
    }
    defer if (limiter) |*l| l.deinit();

    var last_pipes_mtime: i128 = pipesDirMtime(io, ws.root);

    while (!g_shutdown.load(.seq_cst)) {
        maybeReloadPipes(io, ws, &last_pipes_mtime);
        var stream = server.accept(io) catch |err| {
            if (g_shutdown.load(.seq_cst)) break;
            switch (err) {
                error.SocketNotListening => break,
                error.ConnectionAborted => continue,
                else => {
                    if (g_shutdown.load(.seq_cst)) break;
                    std.log.err("accept failed: {s}", .{@errorName(err)});
                    continue;
                },
            }
        };
        // Advance durable workflows (sleeps / retries) between connections.
        if (ws.workflowTick()) |ticked| {
            defer allocator.free(ticked);
        } else |_| {}

        handleConn(allocator, io, ws, &stream, config.max_body_bytes, if (limiter) |*l| l else null) catch |err| {
            std.log.err("request failed: {s}", .{@errorName(err)});
        };
        stream.close(io);
    }
    std.log.info("synapse shutdown complete", .{});
}

// ── Multi-workspace serve (cloud mode) ───────────────────────────────────────

pub fn serveCloud(allocator: Allocator, io: Io, hub: *hub_mod.WorkspaceHub, config: ServeConfig) !void {
    g_shutdown.store(false, .seq_cst);
    installSignalHandlers();

    const address = try Io.net.IpAddress.parseIp4(config.host, config.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    g_listen_fd.store(server.socket.handle, .seq_cst);
    defer g_listen_fd.store(-1, .seq_cst);

    if (!isLoopbackHost(config.host) and !envTruthy("SYNAPSE_REQUIRE_AUTH")) {
        std.log.warn("binding {s}:{d} without SYNAPSE_REQUIRE_AUTH=1 — tokens not enforced (cloud mode)", .{ config.host, config.port });
    }
    std.log.info("synapse cloud listening on http://{s}:{d} version={s}", .{ config.host, config.port, version_mod.version });

    var limiter: ?ratelimit_mod.Limiter = null;
    const rate = envRateLimit();
    if (rate > 0) {
        limiter = ratelimit_mod.Limiter.init(allocator, rate, @max(rate, 1));
        std.log.info("rate limit enabled: {d:.1} req/s", .{rate});
    }
    defer if (limiter) |*l| l.deinit();

    while (!g_shutdown.load(.seq_cst)) {
        // Tick durable workflows across all loaded workspaces.
        hub.tickAll();

        var stream = server.accept(io) catch |err| {
            if (g_shutdown.load(.seq_cst)) break;
            switch (err) {
                error.SocketNotListening => break,
                error.ConnectionAborted => continue,
                else => {
                    if (g_shutdown.load(.seq_cst)) break;
                    std.log.err("accept failed: {s}", .{@errorName(err)});
                    continue;
                },
            }
        };

        handleConnCloud(allocator, io, hub, &stream, config.max_body_bytes, if (limiter) |*l| l else null) catch |err| {
            std.log.err("request failed: {s}", .{@errorName(err)});
        };
        stream.close(io);
    }
    std.log.info("synapse cloud shutdown complete", .{});
}

// ── Request metadata ─────────────────────────────────────────────────────────

const RequestMeta = struct {
    id_buf: [36]u8 = undefined,
    id: []const u8 = "",
    method: []const u8 = "",
    path: []const u8 = "",
    started: Io.Timestamp,
    status: u16 = 500,
};

fn newRequestId(io: Io, buf: *[36]u8) []const u8 {
    var rand_buf: [8]u8 = undefined;
    const seed: u64 = @intCast(@max(Io.Clock.real.now(io).toNanoseconds(), 0));
    var prng = std.Random.DefaultPrng.init(seed ^ 0x9e3779b97f4a7c15);
    prng.random().bytes(&rand_buf);
    const hex = std.fmt.bytesToHex(rand_buf, .lower);
    const written = std.fmt.bufPrint(buf, "req_{s}", .{&hex}) catch "req_unknown";
    return written;
}

fn extractIncomingRequestId(head_buffer: []const u8) ?[]const u8 {
    const needles = [_][]const u8{ "X-Request-Id: ", "x-request-id: " };
    for (needles) |n| {
        if (std.mem.indexOf(u8, head_buffer, n)) |i| {
            const start = i + n.len;
            var end = start;
            while (end < head_buffer.len and head_buffer[end] != '\r' and head_buffer[end] != '\n') : (end += 1) {}
            const v = std.mem.trim(u8, head_buffer[start..end], " \t");
            if (v.len == 0 or v.len > 64) continue;
            var ok = true;
            for (v) |c| {
                const good = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                    (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.';
                if (!good) {
                    ok = false;
                    break;
                }
            }
            if (ok) return v;
        }
    }
    return null;
}

fn logAccess(io: Io, meta: *const RequestMeta) void {
    const now = Io.Clock.real.now(io);
    const dur_ms = @max(now.toMilliseconds() - meta.started.toMilliseconds(), 0);
    const ts = @max(now.toSeconds(), 0);
    std.log.info(
        \\{{"ts":{d},"request_id":"{s}","method":"{s}","path":"{s}","status":{d},"duration_ms":{d}}}
    ,
        .{ ts, meta.id, meta.method, meta.path, meta.status, dur_ms },
    );
}

fn respond(
    request: *std.http.Server.Request,
    meta: *RequestMeta,
    body: []const u8,
    status: std.http.Status,
    content_type: []const u8,
) !void {
    meta.status = @intFromEnum(status);
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "x-request-id", .value = meta.id },
        },
    });
}

// ── Single-workspace connection handler ───────────────────────────────────────

fn handleConn(
    allocator: Allocator,
    io: Io,
    ws: *workspace_mod.Workspace,
    stream: *Io.net.Stream,
    max_body: usize,
    limiter: ?*ratelimit_mod.Limiter,
) !void {
    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &in_buf);
    var stream_writer = stream.writer(io, &out_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = try http_server.receiveHead();

    const method = request.head.method;
    const target = request.head.target;
    const path = pathOnlyStr(target);

    var meta: RequestMeta = .{
        .started = Io.Clock.real.now(io),
        .method = @tagName(method),
        .path = path,
    };
    if (extractIncomingRequestId(request.head_buffer)) |incoming| {
        const n = @min(incoming.len, meta.id_buf.len);
        @memcpy(meta.id_buf[0..n], incoming[0..n]);
        meta.id = meta.id_buf[0..n];
    } else {
        meta.id = newRequestId(io, &meta.id_buf);
    }
    defer logAccess(io, &meta);

    if (method == .GET and std.mem.eql(u8, path, "/health")) {
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf,
            \\{{"ok":true,"product":"{s}","version":"{s}"}}
            \\
        , .{ version_mod.product, version_mod.version });
        try respond(&request, &meta, body, .ok, "application/json");
        return;
    }
    if (method == .GET and std.mem.eql(u8, path, "/ready")) {
        const ready = ws.pipes.count() > 0;
        var buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"ready\":{s},\"pipes\":{d}}}\n", .{
            if (ready) "true" else "false",
            ws.pipes.count(),
        });
        try respond(&request, &meta, body, if (ready) .ok else .service_unavailable, "application/json");
        return;
    }

    if (limiter) |lim| {
        const key = auth_mod.Auth.extractPresentedToken(request.head_buffer) orelse "anon";
        const now_ns = Io.Clock.real.now(io).toNanoseconds();
        if (!lim.allow(key, now_ns)) {
            try respond(&request, &meta, "{\"error\":\"rate_limited\"}\n", .too_many_requests, "application/json");
            return;
        }
    }

    const require_auth = envTruthy("SYNAPSE_REQUIRE_AUTH");
    if (require_auth and !ws.authorize(request.head_buffer, method, path)) {
        try respond(&request, &meta, "{\"error\":\"unauthorized\"}\n", .unauthorized, "application/json");
        return;
    }

    try routeWorkspace(allocator, io, ws, &request, &meta, path, target, max_body);
}

// ── Multi-workspace connection handler ────────────────────────────────────────

fn handleConnCloud(
    allocator: Allocator,
    io: Io,
    hub: *hub_mod.WorkspaceHub,
    stream: *Io.net.Stream,
    max_body: usize,
    limiter: ?*ratelimit_mod.Limiter,
) !void {
    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &in_buf);
    var stream_writer = stream.writer(io, &out_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = try http_server.receiveHead();

    const method = request.head.method;
    const target = request.head.target;
    const path = pathOnlyStr(target);

    var meta: RequestMeta = .{
        .started = Io.Clock.real.now(io),
        .method = @tagName(method),
        .path = path,
    };
    if (extractIncomingRequestId(request.head_buffer)) |incoming| {
        const n = @min(incoming.len, meta.id_buf.len);
        @memcpy(meta.id_buf[0..n], incoming[0..n]);
        meta.id = meta.id_buf[0..n];
    } else {
        meta.id = newRequestId(io, &meta.id_buf);
    }
    defer logAccess(io, &meta);

    // Standard health/ready (no workspace context needed).
    if (method == .GET and std.mem.eql(u8, path, "/health")) {
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf,
            \\{{"ok":true,"product":"{s}","version":"{s}","mode":"cloud"}}
            \\
        , .{ version_mod.product, version_mod.version });
        try respond(&request, &meta, body, .ok, "application/json");
        return;
    }
    if (method == .GET and std.mem.eql(u8, path, "/ready")) {
        var buf: [128]u8 = undefined;
        const n_ws = hub.platform.workspaces.items.len;
        const body = try std.fmt.bufPrint(&buf, "{{\"ready\":true,\"workspaces\":{d}}}\n", .{n_ws});
        try respond(&request, &meta, body, .ok, "application/json");
        return;
    }

    // Rate limiting.
    if (limiter) |lim| {
        const key = auth_mod.Auth.extractPresentedToken(request.head_buffer) orelse "anon";
        const now_ns = Io.Clock.real.now(io).toNanoseconds();
        if (!lim.allow(key, now_ns)) {
            try respond(&request, &meta, "{\"error\":\"rate_limited\"}\n", .too_many_requests, "application/json");
            return;
        }
    }

    // Platform control plane: /v1/platform/*
    if (std.mem.startsWith(u8, path, "/v1/platform")) {
        const require_auth = envTruthy("SYNAPSE_REQUIRE_AUTH");
        if (require_auth and !hub.isAdminRequest(request.head_buffer)) {
            try respond(&request, &meta, "{\"error\":\"unauthorized\"}\n", .unauthorized, "application/json");
            return;
        }
        try platformControlPlane(allocator, io, hub, &request, &meta, path, target, max_body);
        return;
    }

    // Workspace routing: /v1/w/{workspace_id}/...
    // After stripping "/v1/w/{id}", prepend "/v1" so handlers see standard paths.
    if (std.mem.startsWith(u8, path, "/v1/w/")) {
        const after_w = path["/v1/w/".len..];
        const slash_pos = std.mem.indexOfScalar(u8, after_w, '/');
        const workspace_id = if (slash_pos) |sp| after_w[0..sp] else after_w;
        if (!safe_name.isSafeName(workspace_id)) {
            try respond(&request, &meta, "{\"error\":\"invalid_workspace_id\"}\n", .bad_request, "application/json");
            return;
        }

        const ws = (hub.get(workspace_id) catch |err| switch (err) {
            error.FileNotFound => {
                try respond(&request, &meta, "{\"error\":\"workspace_not_found\"}\n", .not_found, "application/json");
                return;
            },
            else => |e| return e,
        }) orelse {
            try respond(&request, &meta, "{\"error\":\"workspace_not_found\"}\n", .not_found, "application/json");
            return;
        };

        // Build rewritten path: strip "/v1/w/{id}" and prepend "/v1".
        const prefix_len = "/v1/w/".len + workspace_id.len;
        const remainder = if (slash_pos != null) path[prefix_len..] else "/";
        const rewritten_path = try std.fmt.allocPrint(allocator, "/v1{s}", .{remainder});
        defer allocator.free(rewritten_path);

        // Build rewritten target (includes query string).
        const rewritten_target: []u8 = blk: {
            const q = std.mem.indexOfScalar(u8, target, '?');
            if (q) |qi| {
                break :blk try std.fmt.allocPrint(allocator, "/v1{s}?{s}", .{ remainder, target[qi + 1 ..] });
            }
            break :blk try std.fmt.allocPrint(allocator, "/v1{s}", .{remainder});
        };
        defer allocator.free(rewritten_target);

        // Auth: workspace tokens OR platform-scoped tokens.
        const require_auth = envTruthy("SYNAPSE_REQUIRE_AUTH");
        if (require_auth and !hub.authorizeForWorkspace(ws, workspace_id, request.head_buffer, method, rewritten_path)) {
            try respond(&request, &meta, "{\"error\":\"unauthorized\"}\n", .unauthorized, "application/json");
            return;
        }

        try routeWorkspace(allocator, io, ws, &request, &meta, rewritten_path, rewritten_target, max_body);
        return;
    }

    try respond(&request, &meta,
        \\{"error":"not_found","hint":"Use /v1/w/{workspace_id}/... or /v1/platform/..."}
        \\
    , .not_found, "application/json");
}

// ── Platform control plane handlers ──────────────────────────────────────────

fn platformControlPlane(
    allocator: Allocator,
    io: Io,
    hub: *hub_mod.WorkspaceHub,
    request: *std.http.Server.Request,
    meta: *RequestMeta,
    path: []const u8,
    _target: []const u8,
    max_body: usize,
) !void {
    _ = io;
    _ = _target;

    // GET /v1/platform/orgs
    if (request.head.method == .GET and std.mem.eql(u8, path, "/v1/platform/orgs")) {
        const json = try hub.platform.listOrgsJson(allocator);
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }

    // POST /v1/platform/orgs  — body: {"name": "..."}
    if (request.head.method == .POST and std.mem.eql(u8, path, "/v1/platform/orgs")) {
        const body = readBody(allocator, request, max_body) catch |err| switch (err) {
            error.StreamTooLong => {
                try respond(request, meta, "{\"error\":\"payload_too_large\"}\n", .payload_too_large, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const name = parsed.value.object.get("name").?.string;
        const json = hub.platform.createOrg(name) catch |err| switch (err) {
            error.OrgAlreadyExists => {
                try respond(request, meta, "{\"error\":\"org_already_exists\"}\n", .conflict, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }

    // GET /v1/platform/workspaces
    if (request.head.method == .GET and std.mem.eql(u8, path, "/v1/platform/workspaces")) {
        const json = try hub.platform.listWorkspacesJson(allocator);
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }

    // POST /v1/platform/workspaces  — body: {"name": "...", "org_id": "..."}
    if (request.head.method == .POST and std.mem.eql(u8, path, "/v1/platform/workspaces")) {
        const body = readBody(allocator, request, max_body) catch |err| switch (err) {
            error.StreamTooLong => {
                try respond(request, meta, "{\"error\":\"payload_too_large\"}\n", .payload_too_large, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const name = parsed.value.object.get("name").?.string;
        const org_id = parsed.value.object.get("org_id").?.string;
        const json = hub.platform.createWorkspace(org_id, name) catch |err| switch (err) {
            error.OrgNotFound => {
                try respond(request, meta, "{\"error\":\"org_not_found\"}\n", .bad_request, "application/json");
                return;
            },
            error.WorkspaceAlreadyExists => {
                try respond(request, meta, "{\"error\":\"workspace_already_exists\"}\n", .conflict, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(json);

        // Scaffold workspace directory.
        var ws_id_parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer ws_id_parsed.deinit();
        const ws_id = ws_id_parsed.value.object.get("workspace_id").?.string;
        hub.scaffoldWorkspace(ws_id, name) catch |err| {
            std.log.warn("workspace scaffold failed for {s}: {s}", .{ ws_id, @errorName(err) });
        };
        try respond(request, meta, json, .ok, "application/json");
        return;
    }

    // POST /v1/platform/tokens  — body: {"workspace_id": "...", "name": "...", "scope": "..."}
    if (request.head.method == .POST and std.mem.eql(u8, path, "/v1/platform/tokens")) {
        const body = readBody(allocator, request, max_body) catch |err| switch (err) {
            error.StreamTooLong => {
                try respond(request, meta, "{\"error\":\"payload_too_large\"}\n", .payload_too_large, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const workspace_id = obj.get("workspace_id").?.string;
        const name = if (obj.get("name")) |v| v.string else "api";
        const scope = if (obj.get("scope")) |v| v.string else "ADMIN";
        const json = hub.platform.mintToken(workspace_id, name, scope) catch |err| switch (err) {
            error.WorkspaceNotFound => {
                try respond(request, meta, "{\"error\":\"workspace_not_found\"}\n", .bad_request, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }

    try respond(request, meta, "{\"error\":\"not_found\"}\n", .not_found, "application/json");
}

// ── Workspace request dispatcher (shared by single and multi mode) ────────────

fn routeWorkspace(
    allocator: Allocator,
    io: Io,
    ws: *workspace_mod.Workspace,
    request: *std.http.Server.Request,
    meta: *RequestMeta,
    path: []const u8,
    target: []const u8,
    max_body: usize,
) !void {
    const method = request.head.method;

    if (method == .GET and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/ui") or std.mem.eql(u8, path, "/ui/"))) {
        const html = try loadUiHtml(allocator, io, ws.root);
        defer allocator.free(html);
        try respond(request, meta, html, .ok, "text/html; charset=utf-8");
        return;
    }

    if (method == .GET and std.mem.eql(u8, path, "/v1/workspace")) {
        const json = try ws.listPipesJson(allocator);
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }

    if (method == .GET and std.mem.eql(u8, path, "/v1/endpoints")) {
        const json = try ws.listEndpointsJson(allocator);
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }

    if (method == .POST and std.mem.startsWith(u8, path, "/v1/events/")) {
        const ds = path["/v1/events/".len..];
        if (!safe_name.isSafeName(ds)) {
            try respond(request, meta, "{\"error\":\"invalid_datasource\"}\n", .bad_request, "application/json");
            return;
        }
        const body = readBody(allocator, request, max_body) catch |err| switch (err) {
            error.StreamTooLong => {
                try respond(request, meta, "{\"error\":\"payload_too_large\"}\n", .payload_too_large, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(body);
        const n = ws.store.ingestNdjson(ds, body) catch |err| switch (err) {
            error.SchemaViolation, error.InvalidJson, error.MissingField => {
                try respond(request, meta, "{\"error\":\"schema_violation\"}\n", .bad_request, "application/json");
                return;
            },
            else => |e| return e,
        };
        ws.runMaterializedPipes() catch {};
        ws.logOp("ingest", ds, "ok");
        var resp_buf: [64]u8 = undefined;
        const resp = try std.fmt.bufPrint(&resp_buf, "{{\"ingested\":{d}}}\n", .{n});
        try respond(request, meta, resp, .ok, "application/json");
        return;
    }

    if (method == .POST and std.mem.eql(u8, path, "/v1/query")) {
        const body = readBody(allocator, request, max_body) catch |err| switch (err) {
            error.StreamTooLong => {
                try respond(request, meta, "{\"error\":\"payload_too_large\"}\n", .payload_too_large, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const ds = obj.get("datasource").?.string;
        if (!safe_name.isSafeName(ds)) {
            try respond(request, meta, "{\"error\":\"invalid_datasource\"}\n", .bad_request, "application/json");
            return;
        }
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
        const limit_raw: usize = if (obj.get("limit")) |l| switch (l) {
            .integer => |i| @intCast(@max(i, 0)),
            else => query_mod.default_limit,
        } else query_mod.default_limit;
        const offset_raw: usize = if (obj.get("offset")) |o| switch (o) {
            .integer => |i| @intCast(@max(i, 0)),
            else => 0,
        } else 0;
        const json = try query_mod.runQuery(allocator, &ws.store, ds, where, limit_raw, offset_raw);
        defer allocator.free(json);
        ws.logOp("query", ds, "ok");
        try respond(request, meta, json, .ok, "application/json");
        return;
    }

    if (method == .GET and std.mem.startsWith(u8, path, "/v1/datasources/") and std.mem.endsWith(u8, path, "/data")) {
        const mid = path["/v1/datasources/".len .. path.len - "/data".len];
        if (!safe_name.isSafeName(mid)) {
            try respond(request, meta, "{\"error\":\"invalid_datasource\"}\n", .bad_request, "application/json");
            return;
        }
        return runDatasourceQuery(allocator, request, meta, ws, mid, target);
    }

    if (method == .POST and std.mem.eql(u8, path, "/v1/remember")) {
        const body = readBody(allocator, request, max_body) catch |err| switch (err) {
            error.StreamTooLong => {
                try respond(request, meta, "{\"error\":\"payload_too_large\"}\n", .payload_too_large, "application/json");
                return;
            },
            else => |e| return e,
        };
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
        try respond(request, meta, json, .ok, "application/json");
        return;
    }

    if (method == .GET and std.mem.startsWith(u8, path, "/v1/pipes/")) {
        const tail = path["/v1/pipes/".len..];
        const split = format_mod.splitNameFormat(tail);
        return runAlias(allocator, request, meta, ws, split.name, target, split.format);
    }

    if (method == .GET and std.mem.eql(u8, path, "/v1/recall")) {
        return runAlias(allocator, request, meta, ws, "recall_context", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/metrics/tool_failure_rate")) {
        return runAlias(allocator, request, meta, ws, "tool_failure_rate", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/metrics/llm_tokens")) {
        return runAlias(allocator, request, meta, ws, "llm_token_burn", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/impact")) {
        return runAlias(allocator, request, meta, ws, "blast_radius", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/plan")) {
        return runAlias(allocator, request, meta, ws, "plan_goal", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/route")) {
        return runAlias(allocator, request, meta, ws, "route_query", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/dispute")) {
        return runAlias(allocator, request, meta, ws, "find_contradictions", target, null);
    }
    if (method == .POST and std.mem.eql(u8, path, "/v1/dispute")) {
        const body = readBody(allocator, request, max_body) catch |err| switch (err) {
            error.StreamTooLong => {
                try respond(request, meta, "{\"error\":\"payload_too_large\"}\n", .payload_too_large, "application/json");
                return;
            },
            else => |e| return e,
        };
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
        try respond(request, meta, json, .ok, "application/json");
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
        try respond(request, meta, json, .ok, "application/json");
        return;
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/embed")) {
        return runAlias(allocator, request, meta, ws, "embed_recall", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/diff")) {
        return runAlias(allocator, request, meta, ws, "diff_run", target, null);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/consolidate")) {
        return runAlias(allocator, request, meta, ws, "consolidate_claims", target, null);
    }
    if (method == .POST and std.mem.eql(u8, path, "/v1/checkpoint")) {
        const body = readBody(allocator, request, max_body) catch |err| switch (err) {
            error.StreamTooLong => {
                try respond(request, meta, "{\"error\":\"payload_too_large\"}\n", .payload_too_large, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const name = obj.get("name").?.string;
        const ds = if (obj.get("datasource")) |d| d.string else "harness_events";
        if (!safe_name.isSafeName(name)) {
            try respond(request, meta, "{\"error\":\"invalid_checkpoint_name\"}\n", .bad_request, "application/json");
            return;
        }
        const json = ws.checkpoint(name, ds) catch |err| switch (err) {
            error.InvalidCheckpointName, error.InvalidDatasourceName => {
                try respond(request, meta, "{\"error\":\"invalid_checkpoint_name\"}\n", .bad_request, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }
    if (method == .POST and std.mem.eql(u8, path, "/v1/reload")) {
        try ws.reloadPipes();
        try respond(request, meta, "{\"reloaded\":true}\n", .ok, "application/json");
        return;
    }

    if (method == .POST and std.mem.eql(u8, path, "/v1/mcp")) {
        const body = readBody(allocator, request, max_body) catch |err| switch (err) {
            error.StreamTooLong => {
                try respond(request, meta, "{\"error\":\"payload_too_large\"}\n", .payload_too_large, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(body);
        const resp = try mcp_mod.handle(allocator, ws, body);
        defer allocator.free(resp);
        try respond(request, meta, resp, .ok, "application/json");
        return;
    }

    // --- Durable workflows ---
    if (method == .GET and std.mem.eql(u8, path, "/v1/workflows")) {
        const json = try ws.workflowList();
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }
    if (method == .POST and std.mem.eql(u8, path, "/v1/workflows/tick")) {
        const json = try ws.workflowTick();
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }
    if (method == .GET and std.mem.startsWith(u8, path, "/v1/workflows/") and !std.mem.eql(u8, path, "/v1/workflows/tick")) {
        const name = path["/v1/workflows/".len..];
        if (std.mem.indexOfScalar(u8, name, '/') == null and safe_name.isSafeName(name)) {
            const json = ws.workflowShow(name) catch {
                try respond(request, meta, "{\"error\":\"workflow_not_found\"}\n", .not_found, "application/json");
                return;
            };
            defer allocator.free(json);
            try respond(request, meta, json, .ok, "application/json");
            return;
        }
    }
    if (method == .POST and std.mem.startsWith(u8, path, "/v1/workflows/") and std.mem.endsWith(u8, path, "/runs")) {
        const mid = path["/v1/workflows/".len .. path.len - "/runs".len];
        if (!safe_name.isSafeName(mid)) {
            try respond(request, meta, "{\"error\":\"invalid_workflow_name\"}\n", .bad_request, "application/json");
            return;
        }
        const body = readBody(allocator, request, max_body) catch |err| switch (err) {
            error.StreamTooLong => {
                try respond(request, meta, "{\"error\":\"payload_too_large\"}\n", .payload_too_large, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(body);
        var input_owned: ?[]u8 = null;
        defer if (input_owned) |o| allocator.free(o);
        var run_id_owned: ?[]u8 = null;
        defer if (run_id_owned) |o| allocator.free(o);
        var input: []const u8 = "{}";
        var run_id: ?[]const u8 = null;
        if (body.len > 0) {
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("input")) |inp| {
                    var aw: std.Io.Writer.Allocating = .init(allocator);
                    defer aw.deinit();
                    try std.json.Stringify.value(inp, .{}, &aw.writer);
                    input_owned = try allocator.dupe(u8, aw.written());
                    input = input_owned.?;
                }
                if (parsed.value.object.get("run_id")) |r| {
                    run_id_owned = try allocator.dupe(u8, r.string);
                    run_id = run_id_owned;
                }
            }
        }
        const json = ws.workflowStart(mid, input, run_id) catch {
            try respond(request, meta, "{\"error\":\"workflow_start_failed\"}\n", .bad_request, "application/json");
            return;
        };
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/workflow-runs")) {
        const json = try ws.workflowListRuns();
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }
    if (method == .GET and std.mem.startsWith(u8, path, "/v1/workflow-runs/")) {
        const rid = path["/v1/workflow-runs/".len..];
        if (!safe_name.isSafeName(rid)) {
            try respond(request, meta, "{\"error\":\"invalid_run_id\"}\n", .bad_request, "application/json");
            return;
        }
        const json = ws.workflowStatus(rid) catch {
            try respond(request, meta, "{\"error\":\"run_not_found\"}\n", .not_found, "application/json");
            return;
        };
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }
    if (method == .POST and std.mem.startsWith(u8, path, "/v1/workflow-runs/") and std.mem.endsWith(u8, path, "/signal")) {
        const rid = path["/v1/workflow-runs/".len .. path.len - "/signal".len];
        if (!safe_name.isSafeName(rid)) {
            try respond(request, meta, "{\"error\":\"invalid_run_id\"}\n", .bad_request, "application/json");
            return;
        }
        const body = readBody(allocator, request, max_body) catch |err| switch (err) {
            error.StreamTooLong => {
                try respond(request, meta, "{\"error\":\"payload_too_large\"}\n", .payload_too_large, "application/json");
                return;
            },
            else => |e| return e,
        };
        defer allocator.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const typ_raw = parsed.value.object.get("type") orelse {
            try respond(request, meta, "{\"error\":\"missing_type\"}\n", .bad_request, "application/json");
            return;
        };
        const typ = try allocator.dupe(u8, typ_raw.string);
        defer allocator.free(typ);
        var payload_owned: ?[]u8 = null;
        defer if (payload_owned) |p| allocator.free(p);
        const payload: []const u8 = blk: {
            if (parsed.value.object.get("payload")) |p| {
                var aw: std.Io.Writer.Allocating = .init(allocator);
                defer aw.deinit();
                try std.json.Stringify.value(p, .{}, &aw.writer);
                payload_owned = try allocator.dupe(u8, aw.written());
                break :blk payload_owned.?;
            }
            break :blk "{}";
        };
        const json = ws.workflowSignal(rid, typ, payload) catch {
            try respond(request, meta, "{\"error\":\"signal_failed\"}\n", .bad_request, "application/json");
            return;
        };
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }
    if (method == .POST and std.mem.startsWith(u8, path, "/v1/workflow-runs/") and std.mem.endsWith(u8, path, "/cancel")) {
        const rid = path["/v1/workflow-runs/".len .. path.len - "/cancel".len];
        if (!safe_name.isSafeName(rid)) {
            try respond(request, meta, "{\"error\":\"invalid_run_id\"}\n", .bad_request, "application/json");
            return;
        }
        const json = try ws.workflowCancel(rid);
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }
    if (method == .POST and std.mem.startsWith(u8, path, "/v1/workflow-runs/") and std.mem.endsWith(u8, path, "/tick")) {
        const rid = path["/v1/workflow-runs/".len .. path.len - "/tick".len];
        if (!safe_name.isSafeName(rid)) {
            try respond(request, meta, "{\"error\":\"invalid_run_id\"}\n", .bad_request, "application/json");
            return;
        }
        const json = try ws.workflowTickRun(rid);
        defer allocator.free(json);
        try respond(request, meta, json, .ok, "application/json");
        return;
    }

    try respond(request, meta, "{\"error\":\"not_found\"}\n", .not_found, "application/json");
}

// ── Utilities ─────────────────────────────────────────────────────────────────

fn pathOnlyStr(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[0..i];
    return target;
}

fn runDatasourceQuery(
    allocator: Allocator,
    request: *std.http.Server.Request,
    meta: *RequestMeta,
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
    const limit = query_mod.parseLimit(params, query_mod.default_limit);
    const offset = query_mod.parseOffset(params);
    const json = try query_mod.runQuery(allocator, &ws.store, ds, where, limit, offset);
    defer allocator.free(json);
    ws.logOp("query", ds, "ok");
    try respond(request, meta, json, .ok, "application/json");
}

fn runAlias(
    allocator: Allocator,
    request: *std.http.Server.Request,
    meta: *RequestMeta,
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
        try respond(request, meta, "{\"error\":\"pipe_not_found\"}\n", .not_found, "application/json");
        return;
    };
    defer result.deinit();

    const limit_opt: ?usize = if (params.get("limit") != null) query_mod.parseLimit(params, query_mod.default_limit) else null;
    const offset = query_mod.parseOffset(params);
    const paged = try query_mod.applyPagination(allocator, result.json, limit_opt, offset);
    defer allocator.free(paged);

    const body = try format_mod.convert(allocator, paged, format);
    defer allocator.free(body);

    ws.logOp("endpoint", pipe_name, @tagName(format));
    try respond(request, meta, body, .ok, format.contentType());
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

fn readBody(allocator: Allocator, request: *std.http.Server.Request, max_body: usize) ![]u8 {
    var transfer_buf: [8 * 1024]u8 = undefined;
    const body_reader = request.readerExpectContinue(&transfer_buf) catch {
        return try allocator.dupe(u8, "");
    };
    return body_reader.allocRemaining(allocator, .limited(max_body)) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.StreamTooLong,
    };
}

fn loadUiHtml(allocator: Allocator, io: Io, workspace_root: []const u8) ![]u8 {
    _ = workspace_root;
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
