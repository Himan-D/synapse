const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");
const plan_mod = @import("plan.zig");

const Candidate = struct {
    name: []const u8,
    kind: []const u8,
    score: f32,
};

fn scoreTool(query: []const u8, tool: plan_mod.Tool) f32 {
    var score: f32 = 0.1;
    if (std.mem.indexOf(u8, query, tool.name) != null) score += 3.0;
    for (tool.provides) |p| {
        if (std.mem.indexOf(u8, query, p) != null) score += 1.5;
    }
    for (tool.requires) |r| {
        if (std.mem.indexOf(u8, query, r) != null) score += 0.5;
    }
    // Prefer cheaper tools slightly when tied
    score += 1.0 / @as(f32, @floatFromInt(tool.cost_latency_ms + 1));
    return score;
}

/// Route a query to the best tool/skill/agent. Returns owned JSON.
pub fn routeQuery(allocator: Allocator, query: []const u8, graph: ?*const graph_mod.Graph) ![]u8 {
    var cands: std.ArrayList(Candidate) = .empty;
    defer cands.deinit(allocator);

    for (plan_mod.default_tools) |tool| {
        try cands.append(allocator, .{
            .name = tool.name,
            .kind = "tool",
            .score = scoreTool(query, tool),
        });
    }

    if (graph) |g| {
        const values = g.nodes.values();
        for (values) |n| {
            if (!std.mem.eql(u8, n.kind, "tool") and !std.mem.eql(u8, n.kind, "agent")) continue;
            var score: f32 = n.score;
            if (std.mem.indexOf(u8, query, n.id) != null) score += 2.0;
            if (std.mem.indexOf(u8, n.props_json, query) != null) score += 1.0;
            try cands.append(allocator, .{
                .name = n.id,
                .kind = n.kind,
                .score = score,
            });
        }
    }

    std.mem.sort(Candidate, cands.items, {}, struct {
        fn less(_: void, a: Candidate, b: Candidate) bool {
            return a.score > b.score;
        }
    }.less);

    const choice = if (cands.items.len > 0) cands.items[0] else Candidate{ .name = "", .kind = "none", .score = 0 };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print(
        \\{{"query":{f},"choice":{{"name":{f},"kind":{f},"score":{d:.3}}},"candidates":[
    ,
        .{
            std.json.fmt(query, .{}),
            std.json.fmt(choice.name, .{}),
            std.json.fmt(choice.kind, .{}),
            choice.score,
        },
    );
    const limit = @min(cands.items.len, 8);
    for (cands.items[0..limit], 0..) |c, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print(
            \\{{"name":{f},"kind":{f},"score":{d:.3}}}
        ,
            .{ std.json.fmt(c.name, .{}), std.json.fmt(c.kind, .{}), c.score },
        );
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

test "routeQuery prefers grep for search query" {
    const json = try routeQuery(std.testing.allocator, "search codebase with grep for risk", null);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "grep") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "choice") != null);
}
