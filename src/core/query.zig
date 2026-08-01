const std = @import("std");
const Allocator = std.mem.Allocator;
const store_mod = @import("store.zig");
const event_mod = @import("event.zig");

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
    const all = try store.filterEvents(allocator, datasource, where);
    defer allocator.free(all);

    const start = @min(offset, all.len);
    const end = @min(start + limit, all.len);
    const slice = all[start..end];

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print(
        \\{{"meta":{{"datasource":{f},"total":{d},"offset":{d},"limit":{d},"returned":{d}}},"data":[
    ,
        .{ std.json.fmt(datasource, .{}), all.len, offset, limit, slice.len },
    );
    for (slice, 0..) |ev, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.writeAll(ev.raw_json);
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

pub fn parseLimit(params: std.StringHashMapUnmanaged([]const u8), default_limit: usize) usize {
    const s = params.get("limit") orelse return default_limit;
    return std.fmt.parseInt(usize, s, 10) catch default_limit;
}

pub fn parseOffset(params: std.StringHashMapUnmanaged([]const u8)) usize {
    const s = params.get("offset") orelse return 0;
    return std.fmt.parseInt(usize, s, 10) catch 0;
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

test "runQuery empty" {
    _ = event_mod.EventType;
}
