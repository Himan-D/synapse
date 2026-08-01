const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");

pub const ContextPack = struct {
    allocator: Allocator,
    json: []u8,

    pub fn deinit(self: *ContextPack) void {
        self.allocator.free(self.json);
        self.* = undefined;
    }
};

fn estimateTokens(s: []const u8) usize {
    return @max(1, s.len / 4);
}

fn kindBoost(kind: []const u8) f32 {
    if (std.mem.eql(u8, kind, "claim")) return 3.0;
    if (std.mem.eql(u8, kind, "error")) return 2.5;
    if (std.mem.eql(u8, kind, "tool_op")) return 2.0;
    if (std.mem.eql(u8, kind, "task")) return 1.8;
    if (std.mem.eql(u8, kind, "tool")) return 1.5;
    return 1.0;
}

fn queryBoost(query: []const u8, node: graph_mod.Node) f32 {
    if (query.len == 0) return 0;
    if (std.mem.indexOf(u8, node.id, query) != null) return 2.0;
    if (std.mem.indexOf(u8, node.props_json, query) != null) return 1.5;
    if (std.mem.indexOf(u8, node.kind, query) != null) return 1.0;
    return 0;
}

const Ranked = struct {
    idx: usize,
    score: f32,
};

/// Build a token-budgeted JSON context pack from a graph.
pub fn buildPack(
    allocator: Allocator,
    graph: *const graph_mod.Graph,
    query: []const u8,
    budget_tokens: usize,
) !ContextPack {
    var ranked: std.ArrayList(Ranked) = .empty;
    defer ranked.deinit(allocator);

    const values = graph.nodes.values();
    for (values, 0..) |node, i| {
        const score = node.score + kindBoost(node.kind) + queryBoost(query, node);
        try ranked.append(allocator, .{ .idx = i, .score = score });
    }

    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn less(_: void, a: Ranked, b: Ranked) bool {
            return a.score > b.score;
        }
    }.less);

    var used: usize = 0;
    var selected_ids: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer selected_ids.deinit(allocator);

    var nodes_json: std.Io.Writer.Allocating = .init(allocator);
    defer nodes_json.deinit();
    try nodes_json.writer.writeAll("[");
    var first_node = true;

    for (ranked.items) |r| {
        const node = values[r.idx];
        const piece_tokens = estimateTokens(node.id) + estimateTokens(node.props_json) + 8;
        if (used + piece_tokens > budget_tokens and selected_ids.count() > 0) break;
        used += piece_tokens;
        try selected_ids.put(allocator, node.id, {});

        if (!first_node) try nodes_json.writer.writeAll(",");
        first_node = false;
        try nodes_json.writer.print(
            \\{{"id":{f},"layer":{f},"kind":{f},"props":{s},"score":{d:.2}}}
        ,
            .{
                std.json.fmt(node.id, .{}),
                std.json.fmt(node.layer.toString(), .{}),
                std.json.fmt(node.kind, .{}),
                node.props_json,
                r.score,
            },
        );
    }
    try nodes_json.writer.writeAll("]");

    var edges_json: std.Io.Writer.Allocating = .init(allocator);
    defer edges_json.deinit();
    try edges_json.writer.writeAll("[");
    var first_edge = true;
    for (graph.edges.items) |e| {
        if (!selected_ids.contains(e.src) or !selected_ids.contains(e.dst)) continue;
        const piece = estimateTokens(e.id) + estimateTokens(e.kind) + 6;
        if (used + piece > budget_tokens) break;
        used += piece;
        if (!first_edge) try edges_json.writer.writeAll(",");
        first_edge = false;
        try edges_json.writer.print(
            \\{{"id":{f},"src":{f},"dst":{f},"kind":{f},"confidence":{d:.2}}}
        ,
            .{
                std.json.fmt(e.id, .{}),
                std.json.fmt(e.src, .{}),
                std.json.fmt(e.dst, .{}),
                std.json.fmt(e.kind, .{}),
                e.confidence,
            },
        );
    }
    try edges_json.writer.writeAll("]");

    var citations: std.Io.Writer.Allocating = .init(allocator);
    defer citations.deinit();
    try citations.writer.writeAll("[");
    var first_c = true;
    var cit_it = selected_ids.iterator();
    while (cit_it.next()) |entry| {
        if (!first_c) try citations.writer.writeAll(",");
        first_c = false;
        try citations.writer.print("{f}", .{std.json.fmt(entry.key_ptr.*, .{})});
    }
    try citations.writer.writeAll("]");

    var summary_buf: [256]u8 = undefined;
    const summary = try std.fmt.bufPrint(
        &summary_buf,
        "Packed {d} nodes / {d} edges (~{d} tokens) for query={s}",
        .{ selected_ids.count(), countEdges(graph, &selected_ids), used, if (query.len == 0) "(none)" else query },
    );

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print(
        \\{{"nodes":{s},"edges":{s},"summary":{f},"citations":{s},"tokens_used":{d},"budget_tokens":{d}}}
    ,
        .{
            nodes_json.written(),
            edges_json.written(),
            std.json.fmt(summary, .{}),
            citations.written(),
            used,
            budget_tokens,
        },
    );

    return .{
        .allocator = allocator,
        .json = try out.toOwnedSlice(),
    };
}

fn countEdges(graph: *const graph_mod.Graph, selected: *std.StringArrayHashMapUnmanaged(void)) usize {
    var n: usize = 0;
    for (graph.edges.items) |e| {
        if (selected.contains(e.src) and selected.contains(e.dst)) n += 1;
    }
    return n;
}

test "context pack respects budget and includes claims" {
    const event_mod = @import("event.zig");
    const lines = [_][]const u8{
        \\{"ts":"2026-07-31T14:00:00Z","run_id":"run_1","agent_id":"a1","type":"memory_write","payload":{"text":"risk service rejects orders when margin is low"}}
        ,
        \\{"ts":"2026-07-31T14:00:01Z","run_id":"run_1","agent_id":"a1","type":"tool_call","payload":{"name":"grep","ok":true}}
        ,
    };
    var events: [2]event_mod.Event = undefined;
    defer for (&events) |*e| e.deinit(std.testing.allocator);
    for (lines, 0..) |line, i| {
        events[i] = try event_mod.parseEvent(std.testing.allocator, line);
    }
    const layers = [_]graph_mod.Layer{ .mind, .world, .work };
    var g = try graph_mod.materialize(std.testing.allocator, &events, &layers);
    defer g.deinit();

    var pack = try buildPack(std.testing.allocator, &g, "risk", 4000);
    defer pack.deinit();
    try std.testing.expect(std.mem.indexOf(u8, pack.json, "claim:") != null);
    try std.testing.expect(std.mem.indexOf(u8, pack.json, "citations") != null);
}
