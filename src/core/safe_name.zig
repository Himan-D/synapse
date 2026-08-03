const std = @import("std");

/// Safe identifier for datasources, checkpoints, pipes used in filesystem paths.
/// Rejects path traversal and empty/oversized names.
pub fn isSafeName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.';
        if (!ok) return false;
    }
    if (std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    if (std.mem.indexOf(u8, s, "..") != null) return false;
    return true;
}

test "safe names" {
    try std.testing.expect(isSafeName("harness_events"));
    try std.testing.expect(isSafeName("ckpt-1"));
    try std.testing.expect(isSafeName("a.b"));
    try std.testing.expect(!isSafeName(""));
    try std.testing.expect(!isSafeName("../etc"));
    try std.testing.expect(!isSafeName("a/b"));
    try std.testing.expect(!isSafeName(".."));
    try std.testing.expect(!isSafeName("has space"));
}
