const std = @import("std");
const Allocator = std.mem.Allocator;
const store_mod = @import("store.zig");
const event_mod = @import("event.zig");

/// Hard ceiling for query/pagination windows (production bound).
pub const max_limit: usize = 10_000;
pub const default_limit: usize = 100;

pub fn clampLimit(n: usize) usize {
    if (n == 0) return default_limit;
    return @min(n, max_limit);
}

pub fn clampOffset(n: usize) usize {
    return @min(n, 1_000_000);
}

/// Tinybird Query-API analog: filter a datasource without owning SQL.
/// Body/params: datasource, where{...}, limit, offset.
pub fn runQuery(
    allocator: Allocator,
    store: *store_mod.Store,
    datasource: []const u8,
    where: std.StringHashMapUnmanaged([]const u8),
    limit: usize,
    offset: usize,
) ![]u8 {
    const lim = clampLimit(limit);
    const off = clampOffset(offset);
    const all = try store.filterEvents(allocator, datasource, where);
    defer allocator.free(all);

    const start = @min(off, all.len);
    const end = @min(start + lim, all.len);
    const slice = all[start..end];

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print(
        \\{{"meta":{{"datasource":{f},"total":{d},"offset":{d},"limit":{d},"returned":{d}}},"data":[
    ,
        .{ std.json.fmt(datasource, .{}), all.len, off, lim, slice.len },
    );
    for (slice, 0..) |ev, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.writeAll(ev.raw_json);
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

pub fn parseLimit(params: std.StringHashMapUnmanaged([]const u8), default: usize) usize {
    const s = params.get("limit") orelse return clampLimit(default);
    const n = std.fmt.parseInt(usize, s, 10) catch return clampLimit(default);
    return clampLimit(n);
}

pub fn parseOffset(params: std.StringHashMapUnmanaged([]const u8)) usize {
    const s = params.get("offset") orelse return 0;
    const n = std.fmt.parseInt(usize, s, 10) catch return 0;
    return clampOffset(n);
}

/// Apply limit/offset to a JSON array-bearing result by wrapping metadata.
/// For pipe results we leave JSON as-is when no limit; when limit is set and
/// body has `events`, trim it.
pub fn applyPagination(allocator: Allocator, json: []const u8, limit: ?usize, offset: usize) ![]u8 {
    const lim = limit orelse return try allocator.dupe(u8, json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return try allocator.dupe(u8, json),
    };
    const key = blk: {
        if (obj.get("events") != null) break :blk "events";
        if (obj.get("groups") != null) break :blk "groups";
        if (obj.get("nodes") != null) break :blk "nodes";
        if (obj.get("data") != null) break :blk "data";
        return try allocator.dupe(u8, json);
    };
    const arr = obj.get(key).?.array.items;
    const start = @min(offset, arr.len);
    const end = @min(start + lim, arr.len);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    // Re-emit object with trimmed array + pagination meta.
    try aw.writer.writeAll("{");
    var first = true;
    var it = obj.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, key)) continue;
        if (!first) try aw.writer.writeAll(",");
        first = false;
        try aw.writer.print("{f}:", .{std.json.fmt(e.key_ptr.*, .{})});
        try std.json.Stringify.value(e.value_ptr.*, .{}, &aw.writer);
    }
    if (!first) try aw.writer.writeAll(",");
    try aw.writer.print("\"{s}\":[", .{key});
    for (arr[start..end], 0..) |item, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try std.json.Stringify.value(item, .{}, &aw.writer);
    }
    try aw.writer.writeAll("],\"pagination\":{");
    try aw.writer.print("\"offset\":{d},\"limit\":{d},\"total\":{d}", .{ offset, lim, arr.len });
    try aw.writer.writeAll("}}");
    return try aw.toOwnedSlice();
}

test "clampLimit bounds" {
    try std.testing.expectEqual(@as(usize, 100), clampLimit(0));
    try std.testing.expectEqual(@as(usize, 50), clampLimit(50));
    try std.testing.expectEqual(max_limit, clampLimit(max_limit + 1));
    _ = event_mod.EventType;
}
