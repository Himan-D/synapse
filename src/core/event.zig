const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EventType = enum {
    tool_call,
    llm_span,
    memory_write,
    plan_step,
    error_event,
    unknown,

    pub fn fromString(s: []const u8) EventType {
        if (std.mem.eql(u8, s, "tool_call")) return .tool_call;
        if (std.mem.eql(u8, s, "llm_span")) return .llm_span;
        if (std.mem.eql(u8, s, "memory_write")) return .memory_write;
        if (std.mem.eql(u8, s, "plan_step")) return .plan_step;
        if (std.mem.eql(u8, s, "error")) return .error_event;
        return .unknown;
    }

    pub fn toString(self: EventType) []const u8 {
        return switch (self) {
            .tool_call => "tool_call",
            .llm_span => "llm_span",
            .memory_write => "memory_write",
            .plan_step => "plan_step",
            .error_event => "error",
            .unknown => "unknown",
        };
    }
};

/// Owned event row. Caller owns all slices.
pub const Event = struct {
    ts: []const u8,
    run_id: []const u8,
    agent_id: []const u8,
    type: EventType,
    type_raw: []const u8,
    payload_json: []const u8,
    raw_json: []const u8,

    pub fn deinit(self: *Event, allocator: Allocator) void {
        allocator.free(self.ts);
        allocator.free(self.run_id);
        allocator.free(self.agent_id);
        allocator.free(self.type_raw);
        allocator.free(self.payload_json);
        allocator.free(self.raw_json);
        self.* = undefined;
    }
};

pub const ParseError = error{
    InvalidJson,
    MissingField,
    OutOfMemory,
};

/// Parse one NDJSON line into an owned Event.
pub fn parseEvent(allocator: Allocator, line: []const u8) ParseError!Event {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidJson;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.InvalidJson;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };

    const ts = try requireString(allocator, obj, "ts");
    errdefer allocator.free(ts);
    const run_id = try requireString(allocator, obj, "run_id");
    errdefer allocator.free(run_id);
    const agent_id = try requireString(allocator, obj, "agent_id");
    errdefer allocator.free(agent_id);
    const type_raw = try requireString(allocator, obj, "type");
    errdefer allocator.free(type_raw);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    if (obj.get("payload")) |payload| {
        std.json.Stringify.value(payload, .{}, &aw.writer) catch return error.OutOfMemory;
    } else {
        aw.writer.writeAll("{}") catch return error.OutOfMemory;
    }

    const raw = try allocator.dupe(u8, trimmed);
    errdefer allocator.free(raw);

    return .{
        .ts = ts,
        .run_id = run_id,
        .agent_id = agent_id,
        .type = EventType.fromString(type_raw),
        .type_raw = type_raw,
        .payload_json = try aw.toOwnedSlice(),
        .raw_json = raw,
    };
}

fn requireString(allocator: Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError![]u8 {
    const v = obj.get(key) orelse return error.MissingField;
    return switch (v) {
        .string => |s| allocator.dupe(u8, s) catch return error.OutOfMemory,
        else => error.MissingField,
    };
}

/// Extract a string field from payload JSON object, or null.
pub fn payloadString(allocator: Allocator, payload_json: []const u8, key: []const u8) Allocator.Error!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    };
}

/// Extract a bool field from payload JSON, default false.
pub fn payloadBool(allocator: Allocator, payload_json: []const u8, key: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch return false;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

test "parseEvent happy path" {
    const line =
        \\{"ts":"2026-07-31T14:00:00Z","run_id":"run_1","agent_id":"a1","type":"tool_call","payload":{"name":"grep","ok":true}}
    ;
    var ev = try parseEvent(std.testing.allocator, line);
    defer ev.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("run_1", ev.run_id);
    try std.testing.expect(ev.type == .tool_call);
    try std.testing.expect(std.mem.indexOf(u8, ev.payload_json, "grep") != null);
}

test "parseEvent missing field" {
    const line =
        \\{"ts":"t","run_id":"r","type":"tool_call"}
    ;
    try std.testing.expectError(error.MissingField, parseEvent(std.testing.allocator, line));
}
