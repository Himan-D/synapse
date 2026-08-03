/// Platform audit log — append-only control-plane events for operators.
/// Persists to {data_root}/audit.json. Not a compliance-grade ledger; enough
/// to answer "who minted/revoked what, when" in the admin console.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Entry = struct {
    ts: i64,
    action: []const u8,
    actor: []const u8,
    detail: []const u8,
};

pub const AuditStore = struct {
    allocator: Allocator,
    io: Io,
    data_root: []const u8,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: Allocator, io: Io, data_root: []const u8) !AuditStore {
        var self: AuditStore = .{
            .allocator = allocator,
            .io = io,
            .data_root = try allocator.dupe(u8, data_root),
        };
        errdefer self.deinit();
        self.reload() catch {};
        return self;
    }

    pub fn deinit(self: *AuditStore) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.action);
            self.allocator.free(e.actor);
            self.allocator.free(e.detail);
        }
        self.entries.deinit(self.allocator);
        self.allocator.free(self.data_root);
        self.* = undefined;
    }

    fn auditPath(self: *const AuditStore, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/audit.json", .{self.data_root});
    }

    pub fn reload(self: *AuditStore) !void {
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try self.auditPath(&path_buf);
        const bytes = try Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        defer self.allocator.free(bytes);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidAuditFile;
        const arr = parsed.value.object.get("entries") orelse return;
        if (arr != .array) return;

        for (self.entries.items) |e| {
            self.allocator.free(e.action);
            self.allocator.free(e.actor);
            self.allocator.free(e.detail);
        }
        self.entries.clearRetainingCapacity();

        for (arr.array.items) |item| {
            if (item != .object) continue;
            const o = item.object;
            const action = jsonString(o, "action") orelse continue;
            const actor = jsonString(o, "actor") orelse "system";
            const detail = jsonString(o, "detail") orelse "{}";
            try self.entries.append(self.allocator, .{
                .ts = jsonInt(o, "ts") orelse 0,
                .action = try self.allocator.dupe(u8, action),
                .actor = try self.allocator.dupe(u8, actor),
                .detail = try self.allocator.dupe(u8, detail),
            });
        }
    }

    pub fn save(self: *AuditStore) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try self.writeJson(&aw.writer);

        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try self.auditPath(&path_buf);
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = aw.written() });
    }

    fn writeJson(self: *const AuditStore, w: *std.Io.Writer) !void {
        try w.writeAll("{\"version\":1,\"entries\":[");
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(
                "{{\"ts\":{d},\"action\":{f},\"actor\":{f},\"detail\":{s}}}",
                .{ e.ts, std.json.fmt(e.action, .{}), std.json.fmt(e.actor, .{}), e.detail },
            );
        }
        try w.writeAll("]}");
    }

    /// Append an audit entry. Persistence errors are logged, not propagated.
    pub fn record(self: *AuditStore, action: []const u8, actor: []const u8, detail: []const u8) void {
        const ts = @max(Io.Clock.real.now(self.io).toSeconds(), 0);
        const entry = Entry{
            .ts = ts,
            .action = self.allocator.dupe(u8, action) catch return,
            .actor = self.allocator.dupe(u8, actor) catch return,
            .detail = self.allocator.dupe(u8, detail) catch return,
        };
        self.entries.append(self.allocator, entry) catch {
            self.allocator.free(entry.action);
            self.allocator.free(entry.actor);
            self.allocator.free(entry.detail);
            return;
        };
        // Keep the file bounded — drop oldest beyond 500 entries.
        while (self.entries.items.len > 500) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old.action);
            self.allocator.free(old.actor);
            self.allocator.free(old.detail);
        }
        self.save() catch |err| {
            std.log.warn("audit: cannot persist audit.json: {s}", .{@errorName(err)});
        };
    }

    pub fn toJson(self: *const AuditStore, allocator: Allocator, limit: usize) ![]u8 {
        const lim = @min(if (limit == 0) 100 else limit, 500);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try aw.writer.writeAll("{\"entries\":[");
        var shown: usize = 0;
        var i: isize = @intCast(self.entries.items.len);
        var first = true;
        while (i > 0 and shown < lim) : (i -= 1) {
            const e = self.entries.items[@intCast(i - 1)];
            if (!first) try aw.writer.writeAll(",");
            first = false;
            try aw.writer.print(
                "{{\"ts\":{d},\"action\":{f},\"actor\":{f},\"detail\":{s}}}",
                .{ e.ts, std.json.fmt(e.action, .{}), std.json.fmt(e.actor, .{}), e.detail },
            );
            shown += 1;
        }
        try aw.writer.writeAll("]}");
        return try aw.toOwnedSlice();
    }
};

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

test "audit round-trip" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tmp = "/tmp/synapse_audit_test";

    try Io.Dir.cwd().createDirPath(io, tmp);
    Io.Dir.cwd().deleteFile(io, tmp ++ "/audit.json") catch {};
    defer Io.Dir.cwd().deleteFile(io, tmp ++ "/audit.json") catch {};

    var store = try AuditStore.init(gpa, io, tmp);
    defer store.deinit();

    store.record("token_mint", "admin", "{\"token_id\":\"tok_1\"}");
    store.record("token_revoke", "admin", "{\"token_id\":\"tok_1\"}");

    var reopened = try AuditStore.init(gpa, io, tmp);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.entries.items.len);

    const json = try reopened.toJson(gpa, 10);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "token_mint") != null);
}
