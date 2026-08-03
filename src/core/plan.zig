const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const graph_mod = @import("graph.zig");

pub const Tool = struct {
    name: []const u8,
    requires: []const []const u8,
    provides: []const []const u8,
    cost_tokens: u32 = 1000,
    cost_latency_ms: u32 = 200,
};

pub const ToolCatalog = struct {
    allocator: Allocator,
    tools: []Tool,
    /// Owned string storage for requires/provides/name.
    arena_strings: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *ToolCatalog) void {
        for (self.tools) |t| {
            self.allocator.free(t.requires);
            self.allocator.free(t.provides);
        }
        self.allocator.free(self.tools);
        for (self.arena_strings.items) |s| self.allocator.free(s);
        self.arena_strings.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Built-in tool catalog for harness planning.
pub const default_tools = [_]Tool{
    .{
        .name = "grep",
        .requires = &.{"codebase"},
        .provides = &.{"search_hits"},
        .cost_tokens = 500,
        .cost_latency_ms = 80,
    },
    .{
        .name = "read_file",
        .requires = &.{"path"},
        .provides = &.{"file_contents"},
        .cost_tokens = 800,
        .cost_latency_ms = 40,
    },
    .{
        .name = "run_tests",
        .requires = &.{ "codebase", "file_contents" },
        .provides = &.{"test_report"},
        .cost_tokens = 2000,
        .cost_latency_ms = 1500,
    },
    .{
        .name = "write_patch",
        .requires = &.{ "file_contents", "search_hits" },
        .provides = &.{"patch"},
        .cost_tokens = 3000,
        .cost_latency_ms = 200,
    },
    .{
        .name = "deploy_check",
        .requires = &.{ "patch", "test_report" },
        .provides = &.{"deploy_ready"},
        .cost_tokens = 1000,
        .cost_latency_ms = 900,
    },
};

/// Load `{root}/tools.json` if present. Caller owns catalog.
pub fn loadToolsFile(allocator: Allocator, io: Io, root: []const u8) !ToolCatalog {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/tools.json", .{root});
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch {
        // Fallback: copy default_tools into owned catalog
        return try catalogFromDefaults(allocator);
    };
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("tools") orelse return try catalogFromDefaults(allocator);

    var cat: ToolCatalog = .{ .allocator = allocator, .tools = &.{} };
    errdefer cat.deinit();

    var tools: std.ArrayList(Tool) = .empty;
    errdefer {
        for (tools.items) |t| {
            allocator.free(t.requires);
            allocator.free(t.provides);
        }
        tools.deinit(allocator);
    }

    for (arr.array.items) |item| {
        const obj = item.object;
        const name = try allocator.dupe(u8, obj.get("name").?.string);
        try cat.arena_strings.append(allocator, name);

        var reqs: std.ArrayList([]const u8) = .empty;
        if (obj.get("requires")) |r| {
            for (r.array.items) |rv| {
                const s = try allocator.dupe(u8, rv.string);
                try cat.arena_strings.append(allocator, s);
                try reqs.append(allocator, s);
            }
        }
        var prov: std.ArrayList([]const u8) = .empty;
        if (obj.get("provides")) |p| {
            for (p.array.items) |pv| {
                const s = try allocator.dupe(u8, pv.string);
                try cat.arena_strings.append(allocator, s);
                try prov.append(allocator, s);
            }
        }
        const cost_tokens: u32 = if (obj.get("cost_tokens")) |c| switch (c) {
            .integer => |i| @intCast(i),
            else => 1000,
        } else 1000;
        const cost_latency_ms: u32 = if (obj.get("cost_latency_ms")) |c| switch (c) {
            .integer => |i| @intCast(i),
            else => 200,
        } else 200;

        try tools.append(allocator, .{
            .name = name,
            .requires = try reqs.toOwnedSlice(allocator),
            .provides = try prov.toOwnedSlice(allocator),
            .cost_tokens = cost_tokens,
            .cost_latency_ms = cost_latency_ms,
        });
    }

    cat.tools = try tools.toOwnedSlice(allocator);
    return cat;
}

fn catalogFromDefaults(allocator: Allocator) !ToolCatalog {
    var cat: ToolCatalog = .{ .allocator = allocator, .tools = &.{} };
    var tools: std.ArrayList(Tool) = .empty;
    errdefer {
        for (tools.items) |t| {
            allocator.free(t.requires);
            allocator.free(t.provides);
        }
        tools.deinit(allocator);
        cat.deinit();
    }
    for (default_tools) |t| {
        const name = try allocator.dupe(u8, t.name);
        try cat.arena_strings.append(allocator, name);
        var reqs: std.ArrayList([]const u8) = .empty;
        for (t.requires) |r| {
            const s = try allocator.dupe(u8, r);
            try cat.arena_strings.append(allocator, s);
            try reqs.append(allocator, s);
        }
        var prov: std.ArrayList([]const u8) = .empty;
        for (t.provides) |p| {
            const s = try allocator.dupe(u8, p);
            try cat.arena_strings.append(allocator, s);
            try prov.append(allocator, s);
        }
        try tools.append(allocator, .{
            .name = name,
            .requires = try reqs.toOwnedSlice(allocator),
            .provides = try prov.toOwnedSlice(allocator),
            .cost_tokens = t.cost_tokens,
            .cost_latency_ms = t.cost_latency_ms,
        });
    }
    cat.tools = try tools.toOwnedSlice(allocator);
    return cat;
}

/// Goal keywords → desired provides.
/// When `catalog` is non-empty, also match goal tokens against catalog `provides` strings.
fn goalProvides(allocator: Allocator, goal: []const u8, catalog: []const Tool) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    const lower_buf = try allocator.alloc(u8, goal.len);
    defer allocator.free(lower_buf);
    for (goal, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const g = lower_buf;

    const appendUnique = struct {
        fn go(list: *std.ArrayList([]const u8), alloc: Allocator, s: []const u8) !void {
            for (list.items) |x| if (std.mem.eql(u8, x, s)) return;
            try list.append(alloc, s);
        }
    }.go;

    if (std.mem.indexOf(u8, g, "test") != null or std.mem.indexOf(u8, g, "verify") != null) {
        try appendUnique(&out, allocator, "test_report");
    }
    if (std.mem.indexOf(u8, g, "fix") != null or std.mem.indexOf(u8, g, "patch") != null or std.mem.indexOf(u8, g, "implement") != null) {
        try appendUnique(&out, allocator, "patch");
    }
    if (std.mem.indexOf(u8, g, "deploy") != null or std.mem.indexOf(u8, g, "ship") != null) {
        try appendUnique(&out, allocator, "deploy_ready");
    }
    if (std.mem.indexOf(u8, g, "search") != null or std.mem.indexOf(u8, g, "find") != null or std.mem.indexOf(u8, g, "risk") != null) {
        try appendUnique(&out, allocator, "search_hits");
    }
    // Catalog-driven: if goal mentions a provides token (or tool name), target it.
    for (catalog) |t| {
        for (t.provides) |p| {
            if (p.len >= 3 and std.mem.indexOf(u8, g, p) != null) {
                try appendUnique(&out, allocator, p);
            }
        }
        if (t.name.len >= 3 and std.mem.indexOf(u8, g, t.name) != null) {
            for (t.provides) |p| try appendUnique(&out, allocator, p);
        }
    }
    if (out.items.len == 0) {
        try appendUnique(&out, allocator, "search_hits");
        try appendUnique(&out, allocator, "file_contents");
    }
    return try out.toOwnedSlice(allocator);
}

fn hasFact(have: *const std.StringArrayHashMapUnmanaged(void), need: []const u8) bool {
    return have.contains(need);
}

fn allRequires(have: *const std.StringArrayHashMapUnmanaged(void), reqs: []const []const u8) bool {
    for (reqs) |r| if (!hasFact(have, r)) return false;
    return true;
}

fn seedHaveFromGraph(have: *std.StringArrayHashMapUnmanaged(void), allocator: Allocator, graph: ?*const graph_mod.Graph) !void {
    try have.put(allocator, "codebase", {});
    try have.put(allocator, "path", {});
    if (graph) |g| {
        for (g.nodes.values()) |n| {
            if (std.mem.eql(u8, n.kind, "tool") or std.mem.eql(u8, n.kind, "file")) {
                // Presence of tools/files implies we can search/read.
                try have.put(allocator, "codebase", {});
                try have.put(allocator, "path", {});
            }
            if (std.mem.eql(u8, n.kind, "tool_op")) {
                try have.put(allocator, "search_hits", {});
            }
        }
    }
}

/// Plan a goal against a tool catalog (+ optional graph seeding).
pub fn planGoal(allocator: Allocator, goal: []const u8, graph: ?*const graph_mod.Graph, tools: []const Tool) ![]u8 {
    var have: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer have.deinit(allocator);
    try seedHaveFromGraph(&have, allocator, graph);

    const catalog = if (tools.len > 0) tools else default_tools[0..];

    const targets = try goalProvides(allocator, goal, catalog);
    defer allocator.free(targets);

    var steps: std.ArrayList(struct { name: []const u8, provides: []const []const u8 }) = .empty;
    defer steps.deinit(allocator);

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(allocator);

    var guard: usize = 0;
    while (guard < 16) : (guard += 1) {
        var unmet: bool = false;
        for (targets) |t| {
            if (!hasFact(&have, t)) {
                unmet = true;
                break;
            }
        }
        if (!unmet) break;

        var picked: ?Tool = null;
        for (catalog) |tool| {
            var useful = false;
            for (tool.provides) |p| {
                if (!hasFact(&have, p)) {
                    for (targets) |t| {
                        if (std.mem.eql(u8, p, t)) useful = true;
                    }
                    if (!useful) useful = true;
                }
            }
            if (!useful) continue;
            if (!allRequires(&have, tool.requires)) continue;
            var new_prov = false;
            for (tool.provides) |p| {
                if (!hasFact(&have, p)) new_prov = true;
            }
            if (!new_prov) continue;
            picked = tool;
            break;
        }
        if (picked == null) {
            for (targets) |t| {
                if (!hasFact(&have, t)) try missing.append(allocator, t);
            }
            break;
        }
        const tool = picked.?;
        try steps.append(allocator, .{ .name = tool.name, .provides = tool.provides });
        for (tool.provides) |p| try have.put(allocator, p, {});
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print("{{\"goal\":{f},\"tools_used\":{d},\"steps\":[", .{ std.json.fmt(goal, .{}), catalog.len });
    for (steps.items, 0..) |s, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print("{{\"id\":\"step:{d}\",\"tool\":{f},\"provides\":[", .{ i, std.json.fmt(s.name, .{}) });
        for (s.provides, 0..) |p, j| {
            if (j > 0) try aw.writer.writeAll(",");
            try aw.writer.print("{f}", .{std.json.fmt(p, .{})});
        }
        try aw.writer.writeAll("]}");
    }
    try aw.writer.writeAll("],\"edges\":[");
    for (0..steps.items.len) |i| {
        if (i + 1 >= steps.items.len) break;
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print(
            \\{{"src":"step:{d}","dst":"step:{d}","kind":"enables"}}
        , .{ i, i + 1 });
    }
    try aw.writer.writeAll("],\"missing\":[");
    for (missing.items, 0..) |m, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print("{f}", .{std.json.fmt(m, .{})});
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

test "planGoal produces steps for fix+test" {
    const json = try planGoal(std.testing.allocator, "fix risk bug and run tests", null, &.{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "steps") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "grep") != null or std.mem.indexOf(u8, json, "read_file") != null);
}
