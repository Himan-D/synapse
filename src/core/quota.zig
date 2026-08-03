/// Soft per-workspace quotas derived from usage counters.
/// Limits come from env vars; 0 means unlimited for that dimension.
const std = @import("std");
const usage_mod = @import("usage.zig");

pub const Policy = struct {
    max_requests: u64 = 0,
    max_ingest_events: u64 = 0,

    pub fn fromEnv() Policy {
        return .{
            .max_requests = envU64("SYNAPSE_QUOTA_REQUESTS"),
            .max_ingest_events = envU64("SYNAPSE_QUOTA_INGEST_EVENTS"),
        };
    }

    pub fn checkRequest(self: Policy, store: *const usage_mod.UsageStore, workspace_id: []const u8) bool {
        if (self.max_requests == 0) return true;
        const c = store.get(workspace_id) orelse return true;
        return c.requests < self.max_requests;
    }

    pub fn checkIngest(self: Policy, store: *const usage_mod.UsageStore, workspace_id: []const u8) bool {
        if (self.max_ingest_events == 0) return true;
        const c = store.get(workspace_id) orelse return true;
        return c.ingest_events < self.max_ingest_events;
    }
};

fn envU64(comptime key: [:0]const u8) u64 {
    const v = std.c.getenv(key) orelse return 0;
    const s = std.mem.span(v);
    return std.fmt.parseInt(u64, s, 10) catch 0;
}

test "quota unlimited by default" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "/tmp/synapse_quota_test";

    try std.Io.Dir.cwd().createDirPath(io, tmp);
    defer std.Io.Dir.cwd().deleteFile(io, tmp ++ "/usage.json") catch {};

    var store = try usage_mod.UsageStore.init(gpa, io, tmp);
    defer store.deinit();
    store.recordRequest("ws_a");
    store.recordIngest("ws_a", 100, 1024);

    const policy = Policy{ .max_requests = 0, .max_ingest_events = 0 };
    try std.testing.expect(policy.checkRequest(&store, "ws_a"));
    try std.testing.expect(policy.checkIngest(&store, "ws_a"));
}

test "quota blocks when exceeded" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "/tmp/synapse_quota_exceed_test";

    try std.Io.Dir.cwd().createDirPath(io, tmp);
    defer std.Io.Dir.cwd().deleteFile(io, tmp ++ "/usage.json") catch {};

    var store = try usage_mod.UsageStore.init(gpa, io, tmp);
    defer store.deinit();
    store.recordIngest("ws_a", 50, 512);

    const policy = Policy{ .max_ingest_events = 50 };
    try std.testing.expect(!policy.checkIngest(&store, "ws_a"));
}
