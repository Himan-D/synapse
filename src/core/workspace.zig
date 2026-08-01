const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const store_mod = @import("store.zig");
const pipe_mod = @import("pipe.zig");
const belief_mod = @import("belief.zig");
const auth_mod = @import("auth.zig");
const graph_mod = @import("graph.zig");
const diff_mod = @import("diff.zig");

pub const Workspace = struct {
    allocator: Allocator,
    io: Io,
    root: []const u8,
    name: []const u8,
    token: ?[]const u8,
    auth: auth_mod.Auth,
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

        var auth = try auth_mod.Auth.load(allocator, io, root);
        errdefer auth.deinit();
        const token = if (auth.admin) |a| try allocator.dupe(u8, a) else null;

        var store = try store_mod.Store.init(allocator, io, root);
        errdefer store.deinit();

        var ws: Workspace = .{
            .allocator = allocator,
            .io = io,
            .root = try allocator.dupe(u8, root),
            .name = name,
            .token = token,
            .auth = auth,
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
        self.auth.deinit();
        self.allocator.free(self.root);
        self.allocator.free(self.name);
        if (self.token) |t| self.allocator.free(t);
        self.* = undefined;
    }

    pub fn reloadPipes(self: *Workspace) !void {
        var it = self.pipes.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit();
            self.allocator.free(e.key_ptr.*);
        }
        self.pipes.clearRetainingCapacity();
        try self.loadPipes();
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
            const pipe = try pipe_mod.loadPipeFile(self.allocator, self.io, path);
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
            "copy_tool_calls.pipe.json",
            "sink_metrics.pipe.json",
            "materialize_memory.pipe.json",
            "diff_run.pipe.json",
            "embed_recall.pipe.json",
            "consolidate_claims.pipe.json",
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
                \\{{"name":{f},"type":"{s}","endpoint":{f}}}
            ,
                .{ std.json.fmt(e.key_ptr.*, .{}), @tagName(e.value_ptr.kind), std.json.fmt(path, .{}) },
            );
        }
        try aw.writer.writeAll("]}");
        return try aw.toOwnedSlice();
    }

    pub fn listEndpointsJson(self: *Workspace, allocator: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try aw.writer.writeAll("{\"endpoints\":[");
        var first = true;
        var it = self.pipes.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.kind != .endpoint and e.value_ptr.endpoint_path == null) continue;
            if (!first) try aw.writer.writeAll(",");
            first = false;
            const path = e.value_ptr.endpoint_path orelse blk: {
                break :blk try std.fmt.allocPrint(allocator, "/v1/pipes/{s}", .{e.key_ptr.*});
            };
            defer if (e.value_ptr.endpoint_path == null) allocator.free(path);
            try aw.writer.print(
                \\{{"name":{f},"url":{f},"formats":["json","ndjson","csv"]}}
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

    /// Tinybird MATERIALIZED analog: run all materialized pipes after ingest.
    pub fn runMaterializedPipes(self: *Workspace) !void {
        var params: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer params.deinit(self.allocator);
        var it = self.pipes.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.kind != .materialized) continue;
            var result = self.runPipe(e.key_ptr.*, params) catch continue;
            result.deinit();
        }
    }

    pub fn logOp(
        self: *Workspace,
        kind: []const u8,
        resource: []const u8,
        detail: []const u8,
    ) void {
        const ts = formatUtcNow(self.allocator, self.io) catch return;
        defer self.allocator.free(ts);
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        aw.writer.print(
            \\{{"ts":{f},"run_id":"ops","agent_id":"synapse","type":"ops","payload":{{"kind":{f},"resource":{f},"detail":{f}}}}}
        ,
            .{
                std.json.fmt(ts, .{}),
                std.json.fmt(kind, .{}),
                std.json.fmt(resource, .{}),
                std.json.fmt(detail, .{}),
            },
        ) catch return;
        _ = self.store.ingestNdjson("synapse_ops_log", aw.written()) catch {};
    }

    pub fn remember(
        self: *Workspace,
        run_id: []const u8,
        agent_id: []const u8,
        text: []const u8,
        confidence: f32,
    ) ![]u8 {
        const ts = try formatUtcNow(self.allocator, self.io);
        defer self.allocator.free(ts);
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
        return self.authorize(head_buffer, .GET, "/v1/workspace");
    }

    pub fn authorize(self: *Workspace, head_buffer: []const u8, method: std.http.Method, path: []const u8) bool {
        if (self.auth.admin == null and self.auth.entries.items.len == 0) return true;
        return self.auth.authorize(head_buffer, method, path);
    }

    pub fn writeDispute(
        self: *Workspace,
        run_id: []const u8,
        claim_a: []const u8,
        claim_b: []const u8,
        reason: []const u8,
    ) ![]u8 {
        const ts = try formatUtcNow(self.allocator, self.io);
        defer self.allocator.free(ts);
        const line = try belief_mod.disputeEventJson(self.allocator, run_id, claim_a, claim_b, reason, ts);
        defer self.allocator.free(line);
        _ = try self.store.ingestNdjson("harness_events", line);
        _ = try self.store.ingestNdjson("beliefs", line);
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"disputed":true,"a":{f},"b":{f},"reason":{f}}}
        ,
            .{ std.json.fmt(claim_a, .{}), std.json.fmt(claim_b, .{}), std.json.fmt(reason, .{}) },
        );
    }

    pub fn graphJson(self: *Workspace, allocator: Allocator, run_id: []const u8) ![]u8 {
        var where: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer where.deinit(allocator);
        if (run_id.len > 0) try where.put(allocator, "run_id", run_id);
        const evs = try self.store.filterEvents(allocator, "harness_events", where);
        defer allocator.free(evs);
        const layers = [_]graph_mod.Layer{ .world, .work, .mind };
        var g = try graph_mod.materialize(allocator, evs, &layers);
        defer g.deinit();

        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try aw.writer.writeAll("{\"nodes\":[");
        var first = true;
        var nit = g.nodes.iterator();
        while (nit.next()) |e| {
            if (!first) try aw.writer.writeAll(",");
            first = false;
            try aw.writer.print(
                \\{{"id":{f},"layer":{f},"kind":{f},"props":{s}}}
            ,
                .{
                    std.json.fmt(e.value_ptr.id, .{}),
                    std.json.fmt(e.value_ptr.layer.toString(), .{}),
                    std.json.fmt(e.value_ptr.kind, .{}),
                    e.value_ptr.props_json,
                },
            );
        }
        try aw.writer.writeAll("],\"edges\":[");
        first = true;
        for (g.edges.items) |edge| {
            if (!first) try aw.writer.writeAll(",");
            first = false;
            try aw.writer.print(
                \\{{"id":{f},"src":{f},"dst":{f},"kind":{f},"confidence":{d:.2}}}
            ,
                .{
                    std.json.fmt(edge.id, .{}),
                    std.json.fmt(edge.src, .{}),
                    std.json.fmt(edge.dst, .{}),
                    std.json.fmt(edge.kind, .{}),
                    edge.confidence,
                },
            );
        }
        try aw.writer.writeAll("]}");
        return try aw.toOwnedSlice();
    }

    pub fn checkpoint(self: *Workspace, name: []const u8, datasource: []const u8) ![]u8 {
        return diff_mod.saveCheckpoint(self.allocator, self.io, &self.store, self.root, datasource, name);
    }

    pub fn createBranch(self: *Workspace, name: []const u8) ![]u8 {
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const src = try std.fmt.bufPrint(&path_buf, "{s}/.synapse/data", .{self.root});
        const dst_dir = try std.fmt.allocPrint(self.allocator, "{s}/.synapse/branches/{s}/data", .{ self.root, name });
        defer self.allocator.free(dst_dir);
        try Io.Dir.cwd().createDirPath(self.io, dst_dir);

        // Copy each ndjson file
        if (Io.Dir.cwd().openDir(self.io, src, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close(self.io);
            var it = dir.iterate();
            while (it.next(self.io) catch null) |entry| {
                if (entry.kind != .file) continue;
                const from = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ src, entry.name });
                defer self.allocator.free(from);
                const to = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dst_dir, entry.name });
                defer self.allocator.free(to);
                const bytes = try Io.Dir.cwd().readFileAlloc(self.io, from, self.allocator, .unlimited);
                defer self.allocator.free(bytes);
                try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = to, .data = bytes });
            }
        } else |_| {}

        return try std.fmt.allocPrint(self.allocator, "{{\"branch\":{f},\"path\":{f}}}", .{
            std.json.fmt(name, .{}),
            std.json.fmt(dst_dir, .{}),
        });
    }
};

fn formatUtcNow(allocator: Allocator, io: Io) ![]u8 {
    const secs_i = Io.Clock.real.now(io).toSeconds();
    const secs: u64 = @intCast(@max(secs_i, 0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return try std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            yd.year,
            md.month.numeric(),
            @as(u8, md.day_index) + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        },
    );
}

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
            \\  "type": "endpoint",
            \\  "nodes": [
            \\    { "type": "filter", "datasource": "harness_events", "where": { "run_id": "{{run_id}}" } },
            \\    { "type": "materialize_graph", "layers": ["mind"] },
            \\    { "type": "project", "op": "contradict" }
            \\  ],
            \\  "endpoint": { "path": "/v1/dispute", "params": ["run_id"] }
            \\}
            \\
        },
        .{ "copy_tool_calls.pipe.json",
            \\{
            \\  "name": "copy_tool_calls",
            \\  "type": "copy",
            \\  "description": "Copy tool_call events into tool_calls datasource",
            \\  "target_datasource": "tool_calls",
            \\  "nodes": [
            \\    { "type": "filter", "datasource": "harness_events", "where": { "type": "tool_call" } },
            \\    { "type": "copy", "target_datasource": "tool_calls" }
            \\  ]
            \\}
            \\
        },
        .{ "sink_metrics.pipe.json",
            \\{
            \\  "name": "sink_metrics",
            \\  "type": "sink",
            \\  "description": "Export tool failure metrics to a local file",
            \\  "sink_path": ".synapse/exports/tool_failure_rate.json",
            \\  "nodes": [
            \\    { "type": "filter", "datasource": "harness_events", "where": { "run_id": "{{run_id}}", "type": "tool_call" } },
            \\    { "type": "aggregate", "op": "rate", "group_by": "name", "success_field": "ok" },
            \\    { "type": "sink", "sink_path": ".synapse/exports/tool_failure_rate.json" }
            \\  ]
            \\}
            \\
        },
        .{ "materialize_memory.pipe.json",
            \\{
            \\  "name": "materialize_memory",
            \\  "type": "materialized",
            \\  "description": "On ingest, copy memory_write events into memory_writes",
            \\  "target_datasource": "memory_writes",
            \\  "nodes": [
            \\    { "type": "filter", "datasource": "harness_events", "where": { "type": "memory_write" } },
            \\    { "type": "copy", "target_datasource": "memory_writes" }
            \\  ]
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
