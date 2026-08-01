const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const store_mod = @import("store.zig");
const pipe_mod = @import("pipe.zig");
const belief_mod = @import("belief.zig");

pub const Workspace = struct {
    allocator: Allocator,
    io: Io,
    root: []const u8,
    name: []const u8,
    token: ?[]const u8,
    store: store_mod.Store,
    pipes: std.StringArrayHashMapUnmanaged(pipe_mod.Pipe) = .empty,

    pub fn load(allocator: Allocator, io: Io, root: []const u8) !Workspace {
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const ws_path = try std.fmt.bufPrint(&path_buf, "{s}/workspace.json", .{root});
        const bytes = try Io.Dir.cwd().readFileAlloc(io, ws_path, allocator, .unlimited);
        defer allocator.free(bytes);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        const name = try allocator.dupe(u8, parsed.value.object.get("name").?.string);

        var token: ?[]const u8 = null;
        const token_path = try std.fmt.bufPrint(&path_buf, "{s}/.synapse/token", .{root});
        if (Io.Dir.cwd().readFileAlloc(io, token_path, allocator, .unlimited)) |tok_bytes| {
            defer allocator.free(tok_bytes);
            token = try allocator.dupe(u8, std.mem.trim(u8, tok_bytes, " \t\r\n"));
        } else |_| {}

        var store = try store_mod.Store.init(allocator, io, root);
        errdefer store.deinit();

        var ws: Workspace = .{
            .allocator = allocator,
            .io = io,
            .root = try allocator.dupe(u8, root),
            .name = name,
            .token = token,
            .store = store,
        };
        errdefer ws.deinit();

        try ws.loadPipes();
        return ws;
    }

    pub fn deinit(self: *Workspace) void {
        var it = self.pipes.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit();
            self.allocator.free(e.key_ptr.*);
        }
        self.pipes.deinit(self.allocator);
        self.store.deinit();
        self.allocator.free(self.root);
        self.allocator.free(self.name);
        if (self.token) |t| self.allocator.free(t);
        self.* = undefined;
    }

    fn loadPipes(self: *Workspace) !void {
        var pipes_dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const pipes_dir = try std.fmt.bufPrint(&pipes_dir_buf, "{s}/pipes", .{self.root});

        var dir = Io.Dir.cwd().openDir(self.io, pipes_dir, .{ .iterate = true }) catch {
            // Fallback to known names if pipes dir missing/unreadable
            try self.loadKnownPipes(pipes_dir);
            return;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".pipe.json")) continue;
            var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ pipes_dir, entry.name });
            var pipe = try pipe_mod.loadPipeFile(self.allocator, self.io, path);
            const name_owned = try self.allocator.dupe(u8, pipe.name);
            if (self.pipes.fetchSwapRemove(name_owned)) |old| {
                self.allocator.free(old.key);
                var old_pipe = old.value;
                old_pipe.deinit();
            }
            try self.pipes.put(self.allocator, name_owned, pipe);
        }
    }

    fn loadKnownPipes(self: *Workspace, pipes_dir: []const u8) !void {
        const known = [_][]const u8{
            "recall_context.pipe.json",
            "tool_failure_rate.pipe.json",
            "blast_radius.pipe.json",
            "plan_goal.pipe.json",
            "route_query.pipe.json",
            "find_contradictions.pipe.json",
        };
        for (known) |fname| {
            var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ pipes_dir, fname });
            const pipe = pipe_mod.loadPipeFile(self.allocator, self.io, path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |e| return e,
            };
            const key = try self.allocator.dupe(u8, pipe.name);
            try self.pipes.put(self.allocator, key, pipe);
        }
    }

    pub fn getPipe(self: *Workspace, name: []const u8) ?*pipe_mod.Pipe {
        return self.pipes.getPtr(name);
    }

    pub fn listPipesJson(self: *Workspace, allocator: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try aw.writer.writeAll("{\"workspace\":");
        try aw.writer.print("{f}", .{std.json.fmt(self.name, .{})});
        try aw.writer.writeAll(",\"pipes\":[");
        var first = true;
        var it = self.pipes.iterator();
        while (it.next()) |e| {
            if (!first) try aw.writer.writeAll(",");
            first = false;
            const path = e.value_ptr.endpoint_path orelse "";
            try aw.writer.print(
                \\{{"name":{f},"endpoint":{f}}}
            ,
                .{ std.json.fmt(e.key_ptr.*, .{}), std.json.fmt(path, .{}) },
            );
        }
        try aw.writer.writeAll("]}");
        return try aw.toOwnedSlice();
    }

    pub fn runPipe(
        self: *Workspace,
        name: []const u8,
        params: std.StringHashMapUnmanaged([]const u8),
    ) !pipe_mod.PipeResult {
        const pipe = self.getPipe(name) orelse return error.PipeNotFound;
        return pipe_mod.execute(self.allocator, &self.store, pipe, params);
    }

    pub fn remember(
        self: *Workspace,
        run_id: []const u8,
        agent_id: []const u8,
        text: []const u8,
        confidence: f32,
    ) ![]u8 {
        const ts = "2026-08-01T00:00:00Z";
        const line = try belief_mod.rememberEventJson(self.allocator, run_id, agent_id, text, confidence, ts);
        defer self.allocator.free(line);
        _ = try self.store.ingestNdjson("harness_events", line);
        _ = try self.store.ingestNdjson("memory_writes", line);
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        try aw.writer.print(
            \\{{"remembered":true,"run_id":{f},"text":{f},"confidence":{d:.3}}}
        ,
            .{ std.json.fmt(run_id, .{}), std.json.fmt(text, .{}), confidence },
        );
        return try aw.toOwnedSlice();
    }

    pub fn checkBearer(self: *Workspace, head_buffer: []const u8) bool {
        const token = self.token orelse return true; // no token configured → open
        // Require Authorization header when token is set
        if (std.mem.indexOf(u8, head_buffer, "Authorization:") == null and
            std.mem.indexOf(u8, head_buffer, "authorization:") == null)
        {
            // Allow health without auth
            return false;
        }
        return std.mem.indexOf(u8, head_buffer, token) != null;
    }
};

pub fn initWorkspace(allocator: Allocator, io: Io, root: []const u8, name: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, root);
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;

    const data = try std.fmt.bufPrint(&path_buf, "{s}/.synapse/data", .{root});
    try Io.Dir.cwd().createDirPath(io, data);
    const pipes = try std.fmt.bufPrint(&path_buf, "{s}/pipes", .{root});
    try Io.Dir.cwd().createDirPath(io, pipes);
    const ds = try std.fmt.bufPrint(&path_buf, "{s}/datasources", .{root});
    try Io.Dir.cwd().createDirPath(io, ds);

    var ws_json: std.Io.Writer.Allocating = .init(allocator);
    defer ws_json.deinit();
    try ws_json.writer.print(
        \\{{
        \\  "name": "{s}",
        \\  "version": 1
        \\}}
        \\
    ,
        .{name},
    );
    const ws_path = try std.fmt.bufPrint(&path_buf, "{s}/workspace.json", .{root});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = ws_path, .data = ws_json.written() });

    const token = "dev-token-local";
    const token_path = try std.fmt.bufPrint(&path_buf, "{s}/.synapse/token", .{root});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = token_path, .data = token });

    try writeDefaultDatasources(io, root);
    try writeDefaultPipes(io, root);
}

fn writeDefaultDatasources(io: Io, root: []const u8) !void {
    const names = store_mod.builtin_datasources;
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    for (names) |n| {
        const path = try std.fmt.bufPrint(&path_buf, "{s}/datasources/{s}.json", .{ root, n });
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf,
            \\{{"name":"{s}","format":"ndjson"}}
            \\
        , .{n});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
    }
}

fn writeDefaultPipes(io: Io, root: []const u8) !void {
    const files = [_]struct { []const u8, []const u8 }{
        .{ "recall_context.pipe.json",
            \\{
            \\  "name": "recall_context",
            \\  "nodes": [
            \\    { "type": "filter", "datasource": "harness_events", "where": { "run_id": "{{run_id}}" } },
            \\    { "type": "materialize_graph", "layers": ["mind", "world", "work"] },
            \\    { "type": "project", "op": "context_pack", "budget_tokens": 4000 }
            \\  ],
            \\  "endpoint": { "path": "/v1/recall", "params": ["run_id", "query"] }
            \\}
            \\
        },
        .{ "tool_failure_rate.pipe.json",
            \\{
            \\  "name": "tool_failure_rate",
            \\  "nodes": [
            \\    { "type": "filter", "datasource": "harness_events", "where": { "run_id": "{{run_id}}", "type": "tool_call" } },
            \\    { "type": "aggregate", "op": "rate", "group_by": "name", "success_field": "ok" }
            \\  ],
            \\  "endpoint": { "path": "/v1/metrics/tool_failure_rate", "params": ["run_id"] }
            \\}
            \\
        },
        .{ "blast_radius.pipe.json",
            \\{
            \\  "name": "blast_radius",
            \\  "nodes": [
            \\    { "type": "filter", "datasource": "harness_events", "where": { "run_id": "{{run_id}}" } },
            \\    { "type": "materialize_graph", "layers": ["world", "work"] },
            \\    { "type": "project", "op": "blast_radius" }
            \\  ],
            \\  "endpoint": { "path": "/v1/impact", "params": ["run_id", "node_id"] }
            \\}
            \\
        },
        .{ "plan_goal.pipe.json",
            \\{
            \\  "name": "plan_goal",
            \\  "nodes": [
            \\    { "type": "filter", "datasource": "harness_events", "where": { "run_id": "{{run_id}}" } },
            \\    { "type": "materialize_graph", "layers": ["world", "work"] },
            \\    { "type": "project", "op": "plan" }
            \\  ],
            \\  "endpoint": { "path": "/v1/plan", "params": ["goal", "run_id"] }
            \\}
            \\
        },
        .{ "route_query.pipe.json",
            \\{
            \\  "name": "route_query",
            \\  "nodes": [
            \\    { "type": "filter", "datasource": "harness_events", "where": { "run_id": "{{run_id}}" } },
            \\    { "type": "materialize_graph", "layers": ["world", "work"] },
            \\    { "type": "project", "op": "route" }
            \\  ],
            \\  "endpoint": { "path": "/v1/route", "params": ["query", "run_id"] }
            \\}
            \\
        },
        .{ "find_contradictions.pipe.json",
            \\{
            \\  "name": "find_contradictions",
            \\  "nodes": [
            \\    { "type": "filter", "datasource": "harness_events", "where": { "run_id": "{{run_id}}" } },
            \\    { "type": "materialize_graph", "layers": ["mind"] },
            \\    { "type": "project", "op": "contradict" }
            \\  ],
            \\  "endpoint": { "path": "/v1/dispute", "params": ["run_id"] }
            \\}
            \\
        },
    };

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    for (files) |f| {
        const path = try std.fmt.bufPrint(&path_buf, "{s}/pipes/{s}", .{ root, f[0] });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = f[1] });
    }
}
