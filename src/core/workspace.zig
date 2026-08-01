const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const store_mod = @import("store.zig");
const pipe_mod = @import("pipe.zig");

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

        // Load known example pipe files by scanning via a simple convention:
        // read directory entries using openDir if available; else try fixed names.
        const known = [_][]const u8{
            "recall_context.pipe.json",
            "tool_failure_rate.pipe.json",
            "blast_radius.pipe.json",
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

    pub fn runPipe(
        self: *Workspace,
        name: []const u8,
        params: std.StringHashMapUnmanaged([]const u8),
    ) !pipe_mod.PipeResult {
        const pipe = self.getPipe(name) orelse return error.PipeNotFound;
        return pipe_mod.execute(self.allocator, &self.store, pipe, params);
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

    // Seed datasources metadata + default pipes
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
    const recall =
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
    ;
    const metrics =
        \\{
        \\  "name": "tool_failure_rate",
        \\  "nodes": [
        \\    { "type": "filter", "datasource": "harness_events", "where": { "run_id": "{{run_id}}", "type": "tool_call" } },
        \\    { "type": "aggregate", "op": "rate", "group_by": "name", "success_field": "ok" }
        \\  ],
        \\  "endpoint": { "path": "/v1/metrics/tool_failure_rate", "params": ["run_id"] }
        \\}
        \\
    ;
    const blast =
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
    ;

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const p1 = try std.fmt.bufPrint(&path_buf, "{s}/pipes/recall_context.pipe.json", .{root});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p1, .data = recall });
    const p2 = try std.fmt.bufPrint(&path_buf, "{s}/pipes/tool_failure_rate.pipe.json", .{root});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p2, .data = metrics });
    const p3 = try std.fmt.bufPrint(&path_buf, "{s}/pipes/blast_radius.pipe.json", .{root});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p3, .data = blast });
}
