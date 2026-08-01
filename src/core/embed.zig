const std = @import("std");
const Allocator = std.mem.Allocator;
const graph_mod = @import("graph.zig");

pub const DIM: usize = 32;

/// Local hashing embedder (no external model). Deterministic bag-of-tokens → unit vector.
pub fn embedText(allocator: Allocator, text: []const u8, out: *[DIM]f32) !void {
    _ = allocator;
    @memset(out, 0);
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r.,;:!?\"'()[]{}");
    while (it.next()) |tok| {
        if (tok.len < 2) continue;
        var h: u64 = 14695981039346656037;
        for (tok) |c| {
            h ^= std.ascii.toLower(c);
            h *%= 1099511628211;
        }
        const idx = h % DIM;
        out[idx] += 1.0;
    }
    // L2 normalize
    var sum: f32 = 0;
    for (out.*) |v| sum += v * v;
    const norm = @sqrt(@max(sum, 1e-9));
    for (out) |*v| v.* /= norm;
}

pub fn cosine(a: *const [DIM]f32, b: *const [DIM]f32) f32 {
    var dot: f32 = 0;
    for (a.*, b.*) |x, y| dot += x * y;
    return dot;
}

/// Rank Mind claim nodes by hybrid structural score + embedding similarity to query.
/// Returns owned JSON: { query, hits:[{id,score,text}] }.
pub fn hybridRecall(
    allocator: Allocator,
    graph: *const graph_mod.Graph,
    query: []const u8,
    limit: usize,
) ![]u8 {
    var qv: [DIM]f32 = undefined;
    try embedText(allocator, query, &qv);

    const Ranked = struct { id: []const u8, text: []const u8, score: f32 };
    var ranked: std.ArrayList(Ranked) = .empty;
    defer {
        for (ranked.items) |r| allocator.free(r.text);
        ranked.deinit(allocator);
    }

    const values = graph.nodes.values();
    for (values) |n| {
        if (!std.mem.eql(u8, n.kind, "claim")) continue;
        const text = blk: {
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, n.props_json, .{}) catch {
                break :blk try allocator.dupe(u8, n.props_json);
            };
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("text")) |t| break :blk try allocator.dupe(u8, t.string);
                if (parsed.value.object.get("content")) |t| break :blk try allocator.dupe(u8, t.string);
            }
            break :blk try allocator.dupe(u8, n.props_json);
        };
        var nv: [DIM]f32 = undefined;
        try embedText(allocator, text, &nv);
        const sim = cosine(&qv, &nv);
        const struct_boost: f32 = if (std.mem.indexOf(u8, text, query) != null) 0.25 else 0;
        try ranked.append(allocator, .{ .id = n.id, .text = text, .score = sim + struct_boost });
    }

    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn less(_: void, a: Ranked, b: Ranked) bool {
            return a.score > b.score;
        }
    }.less);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print("{{\"query\":{f},\"hits\":[", .{std.json.fmt(query, .{})});
    const n = @min(limit, ranked.items.len);
    for (ranked.items[0..n], 0..) |r, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print(
            \\{{"id":{f},"score":{d:.4},"text":{f}}}
        ,
            .{ std.json.fmt(r.id, .{}), r.score, std.json.fmt(r.text, .{}) },
        );
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

test "embedText stable" {
    var a: [DIM]f32 = undefined;
    var b: [DIM]f32 = undefined;
    try embedText(std.testing.allocator, "margin risk low", &a);
    try embedText(std.testing.allocator, "margin risk low", &b);
    try std.testing.expect(cosine(&a, &b) > 0.99);
}
