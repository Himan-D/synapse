const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const workspace_mod = @import("workspace.zig");
const store_mod = @import("store.zig");
const pipe_mod = @import("pipe.zig");

pub const BuildReport = struct {
    allocator: Allocator,
    ok: bool,
    json: []u8,

    pub fn deinit(self: *BuildReport) void {
        self.allocator.free(self.json);
        self.* = undefined;
    }
};

/// Tinybird `tb build` analog: validate workspace datasources + pipes.
pub fn buildWorkspace(allocator: Allocator, io: Io, root: []const u8) !BuildReport {
    var ws = try workspace_mod.Workspace.load(allocator, io, root);
    defer ws.deinit();

    var errors: std.ArrayList([]const u8) = .empty;
    defer {
        for (errors.items) |e| allocator.free(e);
        errors.deinit(allocator);
    }
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| allocator.free(w);
        warnings.deinit(allocator);
    }

    // Datasource files
    var ds_count: usize = 0;
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const ds_dir = try std.fmt.bufPrint(&path_buf, "{s}/datasources", .{root});
    if (Io.Dir.cwd().openDir(io, ds_dir, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            ds_count += 1;
            const fpath = try std.fmt.bufPrint(&path_buf, "{s}/datasources/{s}", .{ root, entry.name });
            const bytes = Io.Dir.cwd().readFileAlloc(io, fpath, allocator, .unlimited) catch {
                try errors.append(allocator, try std.fmt.allocPrint(allocator, "cannot read datasource {s}", .{entry.name}));
                continue;
            };
            defer allocator.free(bytes);
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
                try errors.append(allocator, try std.fmt.allocPrint(allocator, "invalid JSON in datasource {s}", .{entry.name}));
                continue;
            };
            defer parsed.deinit();
            if (parsed.value != .object or parsed.value.object.get("name") == null) {
                try errors.append(allocator, try std.fmt.allocPrint(allocator, "datasource {s} missing name", .{entry.name}));
            }
            // Optional schema: required envelope fields
            if (parsed.value == .object) {
                if (parsed.value.object.get("schema")) |schema| {
                    if (schema != .object) {
                        try errors.append(allocator, try std.fmt.allocPrint(allocator, "datasource {s} schema must be object", .{entry.name}));
                    } else if (schema.object.get("required")) |req| {
                        if (req != .array) {
                            try errors.append(allocator, try std.fmt.allocPrint(allocator, "datasource {s} schema.required must be array", .{entry.name}));
                        } else {
                            for (req.array.items) |field| {
                                if (field != .string) {
                                    try errors.append(allocator, try std.fmt.allocPrint(allocator, "datasource {s} schema.required entries must be strings", .{entry.name}));
                                    break;
                                }
                            }
                        }
                    }
                } else {
                    try warnings.append(allocator, try std.fmt.allocPrint(allocator, "datasource {s} has no schema (recommended)", .{entry.name}));
                }
            }
        }
    } else |_| {
        try warnings.append(allocator, try allocator.dupe(u8, "no datasources/ directory"));
    }

    // tools.json presence
    const tools_path = try std.fmt.bufPrint(&path_buf, "{s}/tools.json", .{root});
    if (Io.Dir.cwd().access(io, tools_path, .{})) |_| {
        // ok
    } else |_| {
        try warnings.append(allocator, try allocator.dupe(u8, "no tools.json — plan/route will use built-in catalog"));
    }

    // Pipes
    var pipe_count: usize = 0;
    var endpoint_count: usize = 0;
    var it = ws.pipes.iterator();
    while (it.next()) |e| {
        pipe_count += 1;
        const pipe = e.value_ptr;
        if (pipe.nodes.items.len == 0) {
            try errors.append(allocator, try std.fmt.allocPrint(allocator, "pipe {s} has no nodes", .{pipe.name}));
        }
        if (pipe.kind == .endpoint) endpoint_count += 1;
        if (pipe.kind == .copy or pipe.kind == .materialized) {
            if (pipe.target_datasource == null) {
                // also allow node-level target
                var has_target = false;
                for (pipe.nodes.items) |n| {
                    if (n.target_datasource != null or n.type == .copy) has_target = true;
                }
                if (!has_target) {
                    try errors.append(allocator, try std.fmt.allocPrint(allocator, "pipe {s} ({s}) missing target_datasource", .{ pipe.name, @tagName(pipe.kind) }));
                }
            }
        }
        if (pipe.kind == .sink) {
            if (pipe.sink_path == null) {
                var has_sink = false;
                for (pipe.nodes.items) |n| {
                    if (n.sink_path != null or n.type == .sink) has_sink = true;
                }
                if (!has_sink) {
                    try errors.append(allocator, try std.fmt.allocPrint(allocator, "pipe {s} (sink) missing sink_path", .{pipe.name}));
                }
            }
        }
        for (pipe.nodes.items) |n| {
            if (n.type == .filter) {
                if (n.datasource) |ds| {
                    // warn if unknown (still allowed — may be created at runtime)
                    var known = false;
                    for (store_mod.builtin_datasources) |b| {
                        if (std.mem.eql(u8, b, ds)) known = true;
                    }
                    if (!known and ws.store.tables.get(ds) == null) {
                        try warnings.append(allocator, try std.fmt.allocPrint(allocator, "pipe {s} filters unknown datasource {s}", .{ pipe.name, ds }));
                    }
                } else {
                    try errors.append(allocator, try std.fmt.allocPrint(allocator, "pipe {s} filter node missing datasource", .{pipe.name}));
                }
            }
        }
        _ = pipe_mod.PipeKind;
    }

    const ok = errors.items.len == 0;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print(
        \\{{"ok":{s},"workspace":{f},"datasources":{d},"pipes":{d},"endpoints":{d},"errors":[
    ,
        .{ if (ok) "true" else "false", std.json.fmt(ws.name, .{}), ds_count, pipe_count, endpoint_count },
    );
    for (errors.items, 0..) |e, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print("{f}", .{std.json.fmt(e, .{})});
    }
    try aw.writer.writeAll("],\"warnings\":[");
    for (warnings.items, 0..) |w, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print("{f}", .{std.json.fmt(w, .{})});
    }
    try aw.writer.writeAll("]}");

    return .{
        .allocator = allocator,
        .ok = ok,
        .json = try aw.toOwnedSlice(),
    };
}
