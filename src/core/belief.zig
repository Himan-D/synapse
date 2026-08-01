const std = @import("std");
const Allocator = std.mem.Allocator;
const event_mod = @import("event.zig");
const graph_mod = @import("graph.zig");

pub const Belief = struct {
    id: []const u8,
    text: []const u8,
    confidence: f32,
    evidence_json: []const u8,
    valid_from: []const u8,
    contradicts: []const []const u8 = &.{},
};

fn claimId(allocator: Allocator, text: []const u8) ![]u8 {
    var hash: u64 = 14695981039346656037;
    for (text) |c| {
        hash ^= c;
        hash *%= 1099511628211;
    }
    return try std.fmt.allocPrint(allocator, "claim:{x}", .{hash});
}

/// Build a memory_write / belief event line (owned).
pub fn rememberEventJson(
    allocator: Allocator,
    run_id: []const u8,
    agent_id: []const u8,
    text: []const u8,
    confidence: f32,
    ts: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print(
        \\{{"ts":{f},"run_id":{f},"agent_id":{f},"type":"memory_write","payload":{{"text":{f},"content":{f},"confidence":{d:.3},"belief":true}}}}
    ,
        .{
            std.json.fmt(ts, .{}),
            std.json.fmt(run_id, .{}),
            std.json.fmt(agent_id, .{}),
            std.json.fmt(text, .{}),
            std.json.fmt(text, .{}),
            confidence,
        },
    );
    return try aw.toOwnedSlice();
}

fn tokenSet(allocator: Allocator, text: []const u8) !std.StringArrayHashMapUnmanaged(void) {
    var set: std.StringArrayHashMapUnmanaged(void) = .empty;
    errdefer set.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r.,;:!?\"'()[]{}");
    while (it.next()) |tok| {
        if (tok.len < 3) continue;
        const dup = try allocator.dupe(u8, tok);
        const gop = try set.getOrPut(allocator, dup);
        if (gop.found_existing) allocator.free(dup);
    }
    return set;
}

fn jaccard(allocator: Allocator, a: []const u8, b: []const u8) !f32 {
    var sa = try tokenSet(allocator, a);
    defer {
        var it = sa.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        sa.deinit(allocator);
    }
    var sb = try tokenSet(allocator, b);
    defer {
        var it = sb.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        sb.deinit(allocator);
    }
    if (sa.count() == 0 or sb.count() == 0) return 0;
    var inter: f32 = 0;
    var ita = sa.iterator();
    while (ita.next()) |e| {
        if (sb.contains(e.key_ptr.*)) inter += 1;
    }
    const uni: f32 = @floatFromInt(sa.count() + sb.count());
    return (2.0 * inter) / uni; // dice-ish
}

fn oppositeCue(a: []const u8, b: []const u8) bool {
    const pairs = [_][2][]const u8{
        .{ "low", "high" },
        .{ "reject", "accept" },
        .{ "fail", "pass" },
        .{ "false", "true" },
        .{ "down", "up" },
        .{ "deny", "allow" },
    };
    for (pairs) |p| {
        const a_has0 = std.mem.indexOf(u8, a, p[0]) != null;
        const a_has1 = std.mem.indexOf(u8, a, p[1]) != null;
        const b_has0 = std.mem.indexOf(u8, b, p[0]) != null;
        const b_has1 = std.mem.indexOf(u8, b, p[1]) != null;
        if ((a_has0 and b_has1) or (a_has1 and b_has0)) return true;
    }
    return false;
}

/// Detect contradictions among Mind claim nodes. Returns owned JSON.
pub fn findContradictions(allocator: Allocator, graph: *const graph_mod.Graph) ![]u8 {
    const values = graph.nodes.values();
    var claims: std.ArrayList(graph_mod.Node) = .empty;
    defer claims.deinit(allocator);
    for (values) |n| {
        if (std.mem.eql(u8, n.kind, "claim") or std.mem.eql(u8, n.layer.toString(), "mind") and std.mem.eql(u8, n.kind, "claim")) {
            try claims.append(allocator, n);
        } else if (std.mem.eql(u8, n.kind, "claim")) {
            try claims.append(allocator, n);
        }
    }
    // simpler: all claim kinds
    claims.clearRetainingCapacity();
    for (values) |n| {
        if (std.mem.eql(u8, n.kind, "claim")) try claims.append(allocator, n);
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"disputes\":[");
    var first = true;
    var i: usize = 0;
    while (i < claims.items.len) : (i += 1) {
        var j = i + 1;
        while (j < claims.items.len) : (j += 1) {
            const ca = claims.items[i];
            const cb = claims.items[j];
            const text_a = (try event_mod.payloadString(allocator, ca.props_json, "text")) orelse
                try allocator.dupe(u8, ca.props_json);
            defer allocator.free(text_a);
            const text_b = (try event_mod.payloadString(allocator, cb.props_json, "text")) orelse
                try allocator.dupe(u8, cb.props_json);
            defer allocator.free(text_b);

            const sim = try jaccard(allocator, text_a, text_b);
            if (sim >= 0.25 and oppositeCue(text_a, text_b)) {
                if (!first) try aw.writer.writeAll(",");
                first = false;
                try aw.writer.print(
                    \\{{"a":{f},"b":{f},"similarity":{d:.3},"reason":"opposing_cues"}}
                ,
                    .{ std.json.fmt(ca.id, .{}), std.json.fmt(cb.id, .{}), sim },
                );
            }
        }
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

/// Extract confidence from claim props (default 0.8).
pub fn confidenceOf(allocator: Allocator, props_json: []const u8) f32 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, props_json, .{}) catch return 0.8;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return 0.8,
    };
    const v = obj.get("confidence") orelse return 0.8;
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0.8,
    };
}

test "rememberEventJson shape" {
    const line = try rememberEventJson(std.testing.allocator, "run_1", "agent", "margin is low", 0.9, "2026-07-31T14:00:00Z");
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "memory_write") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "confidence") != null);
}

test "claimId stable" {
    const a = try claimId(std.testing.allocator, "hello");
    defer std.testing.allocator.free(a);
    const b = try claimId(std.testing.allocator, "hello");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}
