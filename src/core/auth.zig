const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Scope = enum {
    admin,
    pipes_read,
    events_write,
    remember_write,
    query_read,

    pub fn fromString(s: []const u8) ?Scope {
        // Accept uppercase human-readable strings (CLI input) AND Zig @tagName() output.
        if (std.mem.eql(u8, s, "ADMIN") or std.mem.eql(u8, s, "WORKSPACE:ADMIN") or std.mem.eql(u8, s, "admin")) return .admin;
        if (std.mem.eql(u8, s, "PIPES:READ") or std.mem.eql(u8, s, "pipes_read")) return .pipes_read;
        if (std.mem.eql(u8, s, "DATASOURCES:WRITE") or std.mem.eql(u8, s, "EVENTS:WRITE") or std.mem.eql(u8, s, "events_write")) return .events_write;
        if (std.mem.eql(u8, s, "REMEMBER:WRITE") or std.mem.eql(u8, s, "remember_write")) return .remember_write;
        if (std.mem.eql(u8, s, "QUERY:READ") or std.mem.eql(u8, s, "query_read")) return .query_read;
        return null;
    }
};

pub const TokenEntry = struct {
    name: []const u8,
    token: []const u8,
    scopes: []const Scope,
};

pub const Auth = struct {
    allocator: Allocator,
    admin: ?[]const u8 = null,
    entries: std.ArrayList(TokenEntry) = .empty,

    pub fn load(allocator: Allocator, io: Io, root: []const u8) !Auth {
        var self: Auth = .{ .allocator = allocator };
        errdefer self.deinit();

        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const token_path = try std.fmt.bufPrint(&path_buf, "{s}/.synapse/token", .{root});
        if (Io.Dir.cwd().readFileAlloc(io, token_path, allocator, .unlimited)) |tok| {
            defer allocator.free(tok);
            self.admin = try allocator.dupe(u8, std.mem.trim(u8, tok, " \t\r\n"));
        } else |_| {}

        const tokens_path = try std.fmt.bufPrint(&path_buf, "{s}/.synapse/tokens.json", .{root});
        if (Io.Dir.cwd().readFileAlloc(io, tokens_path, allocator, .unlimited)) |bytes| {
            defer allocator.free(bytes);
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
            defer parsed.deinit();
            if (parsed.value == .array) {
                for (parsed.value.array.items) |item| {
                    const obj = item.object;
                    const name = try allocator.dupe(u8, obj.get("name").?.string);
                    const token = try allocator.dupe(u8, obj.get("token").?.string);
                    var scopes: std.ArrayList(Scope) = .empty;
                    if (obj.get("scopes")) |sc| {
                        for (sc.array.items) |s| {
                            if (Scope.fromString(s.string)) |scope| try scopes.append(allocator, scope);
                        }
                    }
                    try self.entries.append(allocator, .{
                        .name = name,
                        .token = token,
                        .scopes = try scopes.toOwnedSlice(allocator),
                    });
                }
            }
        } else |_| {}

        return self;
    }

    pub fn deinit(self: *Auth) void {
        if (self.admin) |a| self.allocator.free(a);
        for (self.entries.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.token);
            self.allocator.free(e.scopes);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn extractBearer(head_buffer: []const u8) ?[]const u8 {
        const needles = [_][]const u8{ "Authorization: Bearer ", "authorization: Bearer ", "Authorization: bearer " };
        for (needles) |n| {
            if (std.mem.indexOf(u8, head_buffer, n)) |i| {
                const start = i + n.len;
                var end = start;
                while (end < head_buffer.len and head_buffer[end] != '\r' and head_buffer[end] != '\n') : (end += 1) {}
                return std.mem.trim(u8, head_buffer[start..end], " \t");
            }
        }
        return null;
    }

    /// Extract `token=` from the request-target query string on the first request line.
    fn extractQueryToken(head_buffer: []const u8) ?[]const u8 {
        const line_end = std.mem.indexOf(u8, head_buffer, "\r\n") orelse return null;
        const line = head_buffer[0..line_end];
        const q = std.mem.indexOfScalar(u8, line, '?') orelse return null;
        const query = line[q + 1 ..];
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "token=")) {
                var val = pair["token=".len..];
                // Strip trailing HTTP/version if somehow attached (shouldn't be after ?).
                if (std.mem.indexOfScalar(u8, val, ' ')) |sp| val = val[0..sp];
                if (val.len == 0) return null;
                return val;
            }
        }
        return null;
    }

    pub fn extractPresentedToken(head_buffer: []const u8) ?[]const u8 {
        if (extractBearer(head_buffer)) |t| return t;
        return extractQueryToken(head_buffer);
    }

    /// Required scope for an HTTP method+path. null means public (health/ui).
    pub fn requiredScope(method: std.http.Method, path: []const u8) ?Scope {
        if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/ready") or
            std.mem.eql(u8, path, "/") or std.mem.startsWith(u8, path, "/ui")) return null;
        if (method == .POST and std.mem.startsWith(u8, path, "/v1/events/")) return .events_write;
        if (method == .POST and std.mem.eql(u8, path, "/v1/remember")) return .remember_write;
        if (method == .POST and std.mem.eql(u8, path, "/v1/dispute")) return .remember_write;
        if (method == .POST and std.mem.eql(u8, path, "/v1/query")) return .query_read;
        if (method == .GET and std.mem.startsWith(u8, path, "/v1/datasources/")) return .query_read;
        if (method == .GET) return .pipes_read;
        if (method == .POST and std.mem.eql(u8, path, "/v1/mcp")) return .admin;
        if (method == .POST and std.mem.eql(u8, path, "/v1/checkpoint")) return .admin;
        if (method == .POST and std.mem.eql(u8, path, "/v1/reload")) return .admin;
        return .admin;
    }

    fn tokenHasScope(scopes: []const Scope, need: Scope) bool {
        for (scopes) |s| {
            if (s == .admin) return true;
            if (s == need) return true;
            if (need == .query_read and s == .pipes_read) return true;
        }
        return false;
    }

    pub fn authorize(self: *const Auth, head_buffer: []const u8, method: std.http.Method, path: []const u8) bool {
        const need = requiredScope(method, path) orelse return true;
        const presented = extractPresentedToken(head_buffer) orelse return false;

        if (self.admin) |admin| {
            if (std.mem.eql(u8, presented, admin)) return true;
        }
        for (self.entries.items) |e| {
            if (!std.mem.eql(u8, presented, e.token)) continue;
            return tokenHasScope(e.scopes, need);
        }
        return false;
    }
};

test "requiredScope matrix" {
    try std.testing.expect(Auth.requiredScope(.GET, "/health") == null);
    try std.testing.expect(Auth.requiredScope(.GET, "/ready") == null);
    try std.testing.expect(Auth.requiredScope(.GET, "/ui") == null);
    try std.testing.expect(Auth.requiredScope(.GET, "/v1/recall") == .pipes_read);
    try std.testing.expect(Auth.requiredScope(.GET, "/v1/embed") == .pipes_read);
    try std.testing.expect(Auth.requiredScope(.GET, "/v1/diff") == .pipes_read);
    try std.testing.expect(Auth.requiredScope(.GET, "/v1/consolidate") == .pipes_read);
    try std.testing.expect(Auth.requiredScope(.GET, "/v1/graph") == .pipes_read);
    try std.testing.expect(Auth.requiredScope(.POST, "/v1/events/harness_events") == .events_write);
    try std.testing.expect(Auth.requiredScope(.POST, "/v1/remember") == .remember_write);
    try std.testing.expect(Auth.requiredScope(.POST, "/v1/dispute") == .remember_write);
    try std.testing.expect(Auth.requiredScope(.POST, "/v1/query") == .query_read);
    try std.testing.expect(Auth.requiredScope(.GET, "/v1/datasources/x/data") == .query_read);
    try std.testing.expect(Auth.requiredScope(.POST, "/v1/checkpoint") == .admin);
    try std.testing.expect(Auth.requiredScope(.POST, "/v1/reload") == .admin);
    try std.testing.expect(Auth.requiredScope(.POST, "/v1/mcp") == .admin);
}

test "authorize bearer and query token" {
    const gpa = std.testing.allocator;
    var auth: Auth = .{ .allocator = gpa };
    defer auth.deinit();
    auth.admin = try gpa.dupe(u8, "admin-secret");
    const name = try gpa.dupe(u8, "reader");
    const token = try gpa.dupe(u8, "read-tok");
    const scopes = try gpa.dupe(Scope, &[_]Scope{.pipes_read});
    try auth.entries.append(gpa, .{ .name = name, .token = token, .scopes = scopes });

    const head_ok =
        "GET /v1/recall HTTP/1.1\r\n" ++
        "Authorization: Bearer read-tok\r\n" ++
        "\r\n";
    try std.testing.expect(auth.authorize(head_ok, .GET, "/v1/recall"));

    const head_query =
        "GET /v1/recall?run_id=x&token=read-tok HTTP/1.1\r\n" ++
        "\r\n";
    try std.testing.expect(auth.authorize(head_query, .GET, "/v1/recall"));

    const head_deny =
        "POST /v1/events/harness_events HTTP/1.1\r\n" ++
        "Authorization: Bearer read-tok\r\n" ++
        "\r\n";
    try std.testing.expect(!auth.authorize(head_deny, .POST, "/v1/events/harness_events"));

    const head_admin =
        "POST /v1/checkpoint HTTP/1.1\r\n" ++
        "Authorization: Bearer admin-secret\r\n" ++
        "\r\n";
    try std.testing.expect(auth.authorize(head_admin, .POST, "/v1/checkpoint"));
}
