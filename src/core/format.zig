const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Format = enum {
    json,
    ndjson,
    csv,

    pub fn fromString(s: []const u8) ?Format {
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "ndjson")) return .ndjson;
        if (std.mem.eql(u8, s, "csv")) return .csv;
        return null;
    }

    pub fn contentType(self: Format) []const u8 {
        return switch (self) {
            .json => "application/json",
            .ndjson => "application/x-ndjson",
            .csv => "text/csv",
        };
    }
};

/// Split path like `/v1/pipes/foo.json` → name=`foo`, format=json.
/// Also handles `/v1/pipes/foo` → name=`foo`, format=null.
pub fn splitNameFormat(path_tail: []const u8) struct { name: []const u8, format: ?Format } {
    if (std.mem.lastIndexOfScalar(u8, path_tail, '.')) |dot| {
        const ext = path_tail[dot + 1 ..];
        if (Format.fromString(ext)) |fmt| {
            return .{ .name = path_tail[0..dot], .format = fmt };
        }
    }
    return .{ .name = path_tail, .format = null };
}

/// Convert Synapse JSON pipe result to another format. Owns returned buffer.
pub fn convert(allocator: Allocator, json: []const u8, format: Format) ![]u8 {
    return switch (format) {
        .json => try allocator.dupe(u8, json),
        .ndjson => try toNdjson(allocator, json),
        .csv => try toCsv(allocator, json),
    };
}

fn toNdjson(allocator: Allocator, json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    switch (parsed.value) {
        .object => |obj| {
            if (obj.get("events")) |evs| {
                for (evs.array.items) |item| {
                    try std.json.Stringify.value(item, .{}, &aw.writer);
                    try aw.writer.writeAll("\n");
                }
                return try aw.toOwnedSlice();
            }
            if (obj.get("groups")) |groups| {
                for (groups.array.items) |item| {
                    try std.json.Stringify.value(item, .{}, &aw.writer);
                    try aw.writer.writeAll("\n");
                }
                return try aw.toOwnedSlice();
            }
            if (obj.get("nodes")) |nodes| {
                for (nodes.array.items) |item| {
                    try std.json.Stringify.value(item, .{}, &aw.writer);
                    try aw.writer.writeAll("\n");
                }
                return try aw.toOwnedSlice();
            }
            if (obj.get("disputes")) |dis| {
                for (dis.array.items) |item| {
                    try std.json.Stringify.value(item, .{}, &aw.writer);
                    try aw.writer.writeAll("\n");
                }
                return try aw.toOwnedSlice();
            }
            if (obj.get("steps")) |steps| {
                for (steps.array.items) |item| {
                    try std.json.Stringify.value(item, .{}, &aw.writer);
                    try aw.writer.writeAll("\n");
                }
                return try aw.toOwnedSlice();
            }
        },
        else => {},
    }
    try aw.writer.writeAll(json);
    if (json.len == 0 or json[json.len - 1] != '\n') try aw.writer.writeAll("\n");
    return try aw.toOwnedSlice();
}

fn toCsv(allocator: Allocator, json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const arr: ?[]const std.json.Value = blk: {
        switch (parsed.value) {
            .object => |obj| {
                if (obj.get("events")) |v| break :blk v.array.items;
                if (obj.get("groups")) |v| break :blk v.array.items;
                if (obj.get("nodes")) |v| break :blk v.array.items;
                if (obj.get("disputes")) |v| break :blk v.array.items;
                if (obj.get("steps")) |v| break :blk v.array.items;
                if (obj.get("impacted")) |v| {
                    try aw.writer.writeAll("id\n");
                    for (v.array.items) |item| {
                        switch (item) {
                            .string => |s| try aw.writer.print("{s}\n", .{s}),
                            else => {},
                        }
                    }
                    return try aw.toOwnedSlice();
                }
            },
            .array => |a| break :blk a.items,
            else => {},
        }
        break :blk null;
    };

    if (arr == null or arr.?.len == 0) {
        try aw.writer.writeAll("value\n");
        try aw.writer.print("{s}\n", .{json});
        return try aw.toOwnedSlice();
    }

    // Collect union of keys from object rows (stable order from first row + extras).
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (arr.?) |item| {
        switch (item) {
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |e| {
                    const gop = try seen.getOrPut(allocator, e.key_ptr.*);
                    if (!gop.found_existing) try keys.append(allocator, e.key_ptr.*);
                }
            },
            else => {},
        }
    }

    if (keys.items.len == 0) {
        try aw.writer.writeAll("value\n");
        for (arr.?) |item| {
            try std.json.Stringify.value(item, .{}, &aw.writer);
            try aw.writer.writeAll("\n");
        }
        return try aw.toOwnedSlice();
    }

    for (keys.items, 0..) |k, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try writeCsvCell(&aw.writer, k);
    }
    try aw.writer.writeAll("\n");

    for (arr.?) |item| {
        switch (item) {
            .object => |obj| {
                for (keys.items, 0..) |k, i| {
                    if (i > 0) try aw.writer.writeAll(",");
                    if (obj.get(k)) |v| {
                        switch (v) {
                            .string => |s| try writeCsvCell(&aw.writer, s),
                            .integer => |n| try aw.writer.print("{d}", .{n}),
                            .float => |f| try aw.writer.print("{d}", .{f}),
                            .bool => |b| try aw.writer.writeAll(if (b) "true" else "false"),
                            .null => {},
                            else => {
                                var tmp: std.Io.Writer.Allocating = .init(allocator);
                                defer tmp.deinit();
                                try std.json.Stringify.value(v, .{}, &tmp.writer);
                                try writeCsvCell(&aw.writer, tmp.written());
                            },
                        }
                    }
                }
                try aw.writer.writeAll("\n");
            },
            else => {
                try std.json.Stringify.value(item, .{}, &aw.writer);
                try aw.writer.writeAll("\n");
            },
        }
    }
    return try aw.toOwnedSlice();
}

fn writeCsvCell(w: *std.Io.Writer, s: []const u8) !void {
    const need_quote = std.mem.indexOfAny(u8, s, ",\"\n\r") != null;
    if (!need_quote) {
        try w.writeAll(s);
        return;
    }
    try w.writeAll("\"");
    for (s) |c| {
        if (c == '"') try w.writeAll("\"\"") else try w.writeByte(c);
    }
    try w.writeAll("\"");
}

test "splitNameFormat" {
    const a = splitNameFormat("tool_failure_rate.csv");
    try std.testing.expectEqualStrings("tool_failure_rate", a.name);
    try std.testing.expect(a.format == .csv);
    const b = splitNameFormat("recall_context");
    try std.testing.expectEqualStrings("recall_context", b.name);
    try std.testing.expect(b.format == null);
}
