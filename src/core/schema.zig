const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const safe_name = @import("safe_name.zig");

pub const Schema = struct {
    required: []const []const u8,
    /// When true (default), unknown top-level keys are allowed.
    additional_properties: bool = true,

    pub fn deinit(self: *Schema, allocator: Allocator) void {
        for (self.required) |r| allocator.free(r);
        allocator.free(self.required);
        self.* = undefined;
    }
};

pub const SchemaError = error{
    SchemaViolation,
    InvalidJson,
    OutOfMemory,
};

/// Validate one NDJSON event line against an optional schema.
pub fn validateEvent(allocator: Allocator, schema: ?*const Schema, line: []const u8) SchemaError!void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidJson;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };
    const sch = schema orelse return;
    for (sch.required) |key| {
        if (obj.get(key) == null) return error.SchemaViolation;
    }
    if (!sch.additional_properties) {
        // Envelope keys we always allow even if not listed in properties.
        var it = obj.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            var ok = false;
            for (sch.required) |r| {
                if (std.mem.eql(u8, r, k)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) return error.SchemaViolation;
        }
    }
}

pub fn loadSchemas(
    allocator: Allocator,
    io: Io,
    root: []const u8,
    out: *std.StringArrayHashMapUnmanaged(Schema),
) !void {
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/datasources", .{root});
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch continue;
        defer allocator.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const name = if (obj.get("name")) |n| n.string else blk: {
            if (std.mem.endsWith(u8, entry.name, ".json"))
                break :blk entry.name[0 .. entry.name.len - ".json".len];
            break :blk entry.name;
        };
        if (!safe_name.isSafeName(name)) continue;
        const schema_v = obj.get("schema") orelse continue;
        if (schema_v != .object) continue;
        var reqs: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (reqs.items) |r| allocator.free(r);
            reqs.deinit(allocator);
        }
        if (schema_v.object.get("required")) |req| {
            if (req == .array) {
                for (req.array.items) |item| {
                    if (item != .string) continue;
                    try reqs.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
        }
        const addl = if (schema_v.object.get("additionalProperties")) |ap| switch (ap) {
            .bool => |b| b,
            else => true,
        } else true;
        const key = try allocator.dupe(u8, name);
        const sch: Schema = .{
            .required = try reqs.toOwnedSlice(allocator),
            .additional_properties = addl,
        };
        if (out.fetchSwapRemove(key)) |old| {
            allocator.free(old.key);
            var old_sch = old.value;
            old_sch.deinit(allocator);
        }
        try out.put(allocator, key, sch);
    }
}

test "validateEvent required" {
    const gpa = std.testing.allocator;
    const ts = try gpa.dupe(u8, "ts");
    const run_id = try gpa.dupe(u8, "run_id");
    const typ = try gpa.dupe(u8, "type");
    defer gpa.free(ts);
    defer gpa.free(run_id);
    defer gpa.free(typ);
    const reqs = [_][]const u8{ ts, run_id, typ };
    const sch: Schema = .{ .required = &reqs, .additional_properties = true };
    try validateEvent(gpa, &sch, "{\"ts\":\"t\",\"run_id\":\"r\",\"agent_id\":\"a\",\"type\":\"tool_call\",\"payload\":{}}");
    try std.testing.expectError(error.SchemaViolation, validateEvent(gpa, &sch, "{\"ts\":\"t\",\"type\":\"x\"}"));
}
