const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");

pub const Tool = struct {
    name: []const u8,
    requires: []const []const u8,
    provides: []const []const u8,
    cost_tokens: u32 = 1000,
    cost_latency_ms: u32 = 200,
};

/// Built-in tool catalog for harness planning (extend via workspace later).
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

/// Goal keywords → desired provides.
fn goalProvides(allocator: Allocator, goal: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    const lower_buf = try allocator.alloc(u8, goal.len);
    defer allocator.free(lower_buf);
    for (goal, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const g = lower_buf;

    if (std.mem.indexOf(u8, g, "test") != null or std.mem.indexOf(u8, g, "verify") != null) {
        try out.append(allocator, "test_report");
    }
    if (std.mem.indexOf(u8, g, "fix") != null or std.mem.indexOf(u8, g, "patch") != null or std.mem.indexOf(u8, g, "implement") != null) {
        try out.append(allocator, "patch");
    }
    if (std.mem.indexOf(u8, g, "deploy") != null or std.mem.indexOf(u8, g, "ship") != null) {
        try out.append(allocator, "deploy_ready");
    }
    if (std.mem.indexOf(u8, g, "search") != null or std.mem.indexOf(u8, g, "find") != null or std.mem.indexOf(u8, g, "risk") != null) {
        try out.append(allocator, "search_hits");
    }
    if (out.items.len == 0) {
        try out.append(allocator, "search_hits");
        try out.append(allocator, "file_contents");
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

/// Plan a goal against the default tool catalog (+ optional graph tools).
/// Returns owned JSON.
pub fn planGoal(allocator: Allocator, goal: []const u8, graph: ?*const graph_mod.Graph) ![]u8 {
    _ = graph; // reserved: seed have-set from World/Work nodes
    var have: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer have.deinit(allocator);
    try have.put(allocator, "codebase", {});
    try have.put(allocator, "path", {});

    const targets = try goalProvides(allocator, goal);
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
        for (default_tools) |tool| {
            // Prefer tools that provide something still missing and whose requires are satisfied.
            var useful = false;
            for (tool.provides) |p| {
                if (!hasFact(&have, p)) {
                    for (targets) |t| {
                        if (std.mem.eql(u8, p, t)) useful = true;
                    }
                    // also allow intermediate provides
                    if (!useful) useful = true;
                }
            }
            if (!useful) continue;
            if (!allRequires(&have, tool.requires)) continue;
            // skip if all provides already had
            var new_prov = false;
            for (tool.provides) |p| if (!hasFact(&have, p)) new_prov = true;
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
    try aw.writer.print("{{\"goal\":{f},\"steps\":[", .{std.json.fmt(goal, .{})});
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
    const json = try planGoal(std.testing.allocator, "fix risk bug and run tests", null);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "steps") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "grep") != null or std.mem.indexOf(u8, json, "read_file") != null);
}
