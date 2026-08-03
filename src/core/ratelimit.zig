const std = @import("std");

/// Token-bucket rate limiter keyed by opaque token string (or "anon").
/// Single-threaded accept loop — no mutex required.
pub const Limiter = struct {
    rate_per_sec: f64,
    burst: f64,
    buckets: std.StringHashMapUnmanaged(Bucket) = .empty,
    allocator: std.mem.Allocator,

    const Bucket = struct {
        tokens: f64,
        last_ns: i128,
    };

    pub fn init(allocator: std.mem.Allocator, rate_per_sec: f64, burst: f64) Limiter {
        return .{
            .allocator = allocator,
            .rate_per_sec = rate_per_sec,
            .burst = @max(burst, 1),
        };
    }

    pub fn deinit(self: *Limiter) void {
        var it = self.buckets.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.buckets.deinit(self.allocator);
        self.* = undefined;
    }

    /// Returns false when the request should be rejected (429).
    pub fn allow(self: *Limiter, key: []const u8, now_ns: i128) bool {
        if (self.rate_per_sec <= 0) return true;

        const gop = self.buckets.getOrPut(self.allocator, key) catch return true;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, key) catch return true;
            gop.value_ptr.* = .{ .tokens = self.burst, .last_ns = now_ns };
        }
        var b = gop.value_ptr;
        const elapsed = @as(f64, @floatFromInt(now_ns - b.last_ns)) / 1e9;
        if (elapsed > 0) {
            b.tokens = @min(self.burst, b.tokens + elapsed * self.rate_per_sec);
            b.last_ns = now_ns;
        }
        if (b.tokens < 1.0) return false;
        b.tokens -= 1.0;
        return true;
    }
};

test "token bucket allows then rejects" {
    var lim = Limiter.init(std.testing.allocator, 1.0, 1.0);
    defer lim.deinit();
    try std.testing.expect(lim.allow("t", 0));
    try std.testing.expect(!lim.allow("t", 1)); // same instant, burst spent
    try std.testing.expect(lim.allow("t", 1_000_000_000)); // +1s refill
}
