/// UsageStore: per-workspace counters you can bill on later.
///
/// Persists to {data_root}/usage.json. Counters are monotonic within the life of
/// the file; nothing here prices anything or talks to a payment processor. The
/// export shape is deliberately boring so a billing job can diff two snapshots.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Counters = struct {
    workspace_id: []const u8,
    requests: u64 = 0,
    ingest_events: u64 = 0,
    ingest_bytes: u64 = 0,
    updated_at: i64 = 0,
};

pub const UsageStore = struct {
    allocator: Allocator,
    io: Io,
    data_root: []const u8,
    entries: std.ArrayList(Counters) = .empty,

    /// Load from {data_root}/usage.json; missing file → empty store (ok).
    pub fn init(allocator: Allocator, io: Io, data_root: []const u8) !UsageStore {
        var self: UsageStore = .{
            .allocator = allocator,
            .io = io,
            .data_root = try allocator.dupe(u8, data_root),
        };
        errdefer self.deinit();
        self.reload() catch {};
        return self;
    }

    pub fn deinit(self: *UsageStore) void {
        for (self.entries.items) |e| self.allocator.free(e.workspace_id);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.data_root);
        self.* = undefined;
    }

    fn usagePath(self: *const UsageStore, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/usage.json", .{self.data_root});
    }

    pub fn reload(self: *UsageStore) !void {
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try self.usagePath(&path_buf);
        const bytes = try Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        defer self.allocator.free(bytes);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidUsageFile;
        const workspaces = parsed.value.object.get("workspaces") orelse return;
        if (workspaces != .array) return;

        for (self.entries.items) |e| self.allocator.free(e.workspace_id);
        self.entries.clearRetainingCapacity();

        for (workspaces.array.items) |item| {
            if (item != .object) continue;
            const o = item.object;
            const id = switch (o.get("workspace_id") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            try self.entries.append(self.allocator, .{
                .workspace_id = try self.allocator.dupe(u8, id),
                .requests = readU64(o, "requests"),
                .ingest_events = readU64(o, "ingest_events"),
                .ingest_bytes = readU64(o, "ingest_bytes"),
                .updated_at = readI64(o, "updated_at"),
            });
        }
    }

    pub fn save(self: *UsageStore) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try self.writeJson(&aw.writer);

        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try self.usagePath(&path_buf);
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = aw.written() });
    }

    fn writeJson(self: *const UsageStore, w: *std.Io.Writer) !void {
        try w.writeAll("{\"version\":1,\"workspaces\":[");
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(
                "{{\"workspace_id\":{f},\"requests\":{d},\"ingest_events\":{d},\"ingest_bytes\":{d},\"updated_at\":{d}}}",
                .{ std.json.fmt(e.workspace_id, .{}), e.requests, e.ingest_events, e.ingest_bytes, e.updated_at },
            );
        }
        try w.writeAll("]}");
    }

    /// Billing-facing export. Same shape as the on-disk file.
    pub fn toJson(self: *const UsageStore, allocator: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try self.writeJson(&aw.writer);
        return try aw.toOwnedSlice();
    }

    pub fn get(self: *const UsageStore, workspace_id: []const u8) ?Counters {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.workspace_id, workspace_id)) return e;
        }
        return null;
    }

    fn entryFor(self: *UsageStore, workspace_id: []const u8) !*Counters {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.workspace_id, workspace_id)) return e;
        }
        try self.entries.append(self.allocator, .{
            .workspace_id = try self.allocator.dupe(u8, workspace_id),
        });
        return &self.entries.items[self.entries.items.len - 1];
    }

    /// Count one authenticated workspace request. Metering must never fail a
    /// request the customer already paid for with a round trip, so persistence
    /// errors are logged rather than propagated.
    pub fn recordRequest(self: *UsageStore, workspace_id: []const u8) void {
        self.bump(workspace_id, 1, 0, 0);
    }

    /// Count a successful ingest: event count plus raw request body size.
    pub fn recordIngest(self: *UsageStore, workspace_id: []const u8, events: u64, bytes: u64) void {
        self.bump(workspace_id, 0, events, bytes);
    }

    fn bump(self: *UsageStore, workspace_id: []const u8, requests: u64, events: u64, bytes: u64) void {
        if (workspace_id.len == 0) return;
        const e = self.entryFor(workspace_id) catch |err| {
            std.log.warn("usage: cannot track {s}: {s}", .{ workspace_id, @errorName(err) });
            return;
        };
        e.requests +|= requests;
        e.ingest_events +|= events;
        e.ingest_bytes +|= bytes;
        e.updated_at = @max(Io.Clock.real.now(self.io).toSeconds(), 0);
        self.save() catch |err| {
            std.log.warn("usage: cannot persist usage.json: {s}", .{@errorName(err)});
        };
    }
};

fn readU64(obj: std.json.ObjectMap, key: []const u8) u64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        else => 0,
    };
}

fn readI64(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        else => 0,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "counters accumulate per workspace and survive a reload" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tmp = "/tmp/synapse_usage_test";

    try Io.Dir.cwd().createDirPath(io, tmp);
    Io.Dir.cwd().deleteFile(io, tmp ++ "/usage.json") catch {};
    defer Io.Dir.cwd().deleteFile(io, tmp ++ "/usage.json") catch {};

    var store = try UsageStore.init(gpa, io, tmp);
    defer store.deinit();

    store.recordRequest("ws_a");
    store.recordRequest("ws_a");
    store.recordIngest("ws_a", 3, 512);
    store.recordRequest("ws_b");

    const a = store.get("ws_a").?;
    try std.testing.expectEqual(@as(u64, 2), a.requests);
    try std.testing.expectEqual(@as(u64, 3), a.ingest_events);
    try std.testing.expectEqual(@as(u64, 512), a.ingest_bytes);
    try std.testing.expectEqual(@as(u64, 1), store.get("ws_b").?.requests);
    try std.testing.expect(store.get("ws_missing") == null);

    var reopened = try UsageStore.init(gpa, io, tmp);
    defer reopened.deinit();
    const reloaded = reopened.get("ws_a").?;
    try std.testing.expectEqual(@as(u64, 2), reloaded.requests);
    try std.testing.expectEqual(@as(u64, 512), reloaded.ingest_bytes);

    const json = try reopened.toJson(gpa);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"workspace_id\":\"ws_a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ingest_events\":3") != null);
}

test "empty workspace id is not tracked" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tmp = "/tmp/synapse_usage_empty_test";

    try Io.Dir.cwd().createDirPath(io, tmp);
    Io.Dir.cwd().deleteFile(io, tmp ++ "/usage.json") catch {};
    defer Io.Dir.cwd().deleteFile(io, tmp ++ "/usage.json") catch {};

    var store = try UsageStore.init(gpa, io, tmp);
    defer store.deinit();
    store.recordRequest("");
    try std.testing.expectEqual(@as(usize, 0), store.entries.items.len);
}
