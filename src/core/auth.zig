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
        if (std.mem.eql(u8, s, "ADMIN") or std.mem.eql(u8, s, "WORKSPACE:ADMIN")) return .admin;
        if (std.mem.eql(u8, s, "PIPES:READ")) return .pipes_read;
        if (std.mem.eql(u8, s, "DATASOURCES:WRITE") or std.mem.eql(u8, s, "EVENTS:WRITE")) return .events_write;
        if (std.mem.eql(u8, s, "REMEMBER:WRITE")) return .remember_write;
        if (std.mem.eql(u8, s, "QUERY:READ")) return .query_read;
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

    /// Required scope for an HTTP method+path. null means public (health).
    pub fn requiredScope(method: std.http.Method, path: []const u8) ?Scope {
        if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/") or std.mem.startsWith(u8, path, "/ui")) return null;
        if (method == .POST and std.mem.startsWith(u8, path, "/v1/events/")) return .events_write;
        if (method == .POST and std.mem.eql(u8, path, "/v1/remember")) return .remember_write;
        if (method == .POST and std.mem.eql(u8, path, "/v1/query")) return .query_read;
        if (method == .GET and std.mem.startsWith(u8, path, "/v1/datasources/")) return .query_read;
        if (method == .GET) return .pipes_read;
        if (method == .POST and std.mem.eql(u8, path, "/v1/mcp")) return .admin;
        if (method == .POST and std.mem.eql(u8, path, "/v1/dispute")) return .remember_write;
        if (method == .POST and std.mem.eql(u8, path, "/v1/checkpoint")) return .admin;
        return .admin;
    }

    pub fn authorize(self: *const Auth, head_buffer: []const u8, method: std.http.Method, path: []const u8) bool {
        const need = requiredScope(method, path) orelse return true;
        const presented = extractBearer(head_buffer) orelse {
            // Also allow token query param style: token=...
            if (std.mem.indexOf(u8, head_buffer, "token=")) |_| {
                // fall through — checked via substring match below for admin only
            } else return false;
            return false;
        };

        if (self.admin) |admin| {
            if (std.mem.eql(u8, presented, admin)) return true;
        }
        for (self.entries.items) |e| {
            if (!std.mem.eql(u8, presented, e.token)) continue;
            for (e.scopes) |s| {
                if (s == .admin) return true;
                if (s == need) return true;
                // PIPES:READ covers query read
                if (need == .query_read and s == .pipes_read) return true;
            }
            return false;
        }
        return false;
    }
};
