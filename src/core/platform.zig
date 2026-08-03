/// PlatformStore: org → workspace → scoped token multi-tenancy layer.
/// Persists to {data_root}/platform.json.
/// Schema-versioned; safe to extend additive fields.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const auth_mod = @import("auth.zig");
const safe_name = @import("safe_name.zig");

// ── Data model ───────────────────────────────────────────────────────────────

pub const Org = struct {
    id: []const u8,
    name: []const u8,
};

pub const WorkspaceMeta = struct {
    id: []const u8,
    name: []const u8,
    org_id: []const u8,
};

pub const PlatformToken = struct {
    name: []const u8,
    token: []const u8,
    org_id: []const u8,
    workspace_id: []const u8,
    scopes: []const auth_mod.Scope,
};

// ── PlatformStore ─────────────────────────────────────────────────────────────

pub const PlatformStore = struct {
    allocator: Allocator,
    io: Io,
    data_root: []const u8,
    admin_token: ?[]const u8 = null,
    orgs: std.ArrayList(Org) = .empty,
    workspaces: std.ArrayList(WorkspaceMeta) = .empty,
    tokens: std.ArrayList(PlatformToken) = .empty,

    /// Load from {data_root}/platform.json; missing file → empty store (ok).
    pub fn init(allocator: Allocator, io: Io, data_root: []const u8) !PlatformStore {
        var self: PlatformStore = .{
            .allocator = allocator,
            .io = io,
            .data_root = try allocator.dupe(u8, data_root),
        };
        errdefer self.deinit();
        self.reload() catch {}; // ok if file doesn't exist yet
        return self;
    }

    pub fn deinit(self: *PlatformStore) void {
        self.clearAll();
        self.orgs.deinit(self.allocator);
        self.workspaces.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
        self.allocator.free(self.data_root);
        self.* = undefined;
    }

    /// Free every catalog entry, leaving the (still usable) lists empty.
    fn clearAll(self: *PlatformStore) void {
        if (self.admin_token) |t| {
            self.allocator.free(t);
            self.admin_token = null;
        }
        for (self.orgs.items) |o| {
            self.allocator.free(o.id);
            self.allocator.free(o.name);
        }
        self.orgs.clearRetainingCapacity();
        for (self.workspaces.items) |w| {
            self.allocator.free(w.id);
            self.allocator.free(w.name);
            self.allocator.free(w.org_id);
        }
        self.workspaces.clearRetainingCapacity();
        for (self.tokens.items) |t| {
            self.allocator.free(t.name);
            self.allocator.free(t.token);
            self.allocator.free(t.org_id);
            self.allocator.free(t.workspace_id);
            self.allocator.free(t.scopes);
        }
        self.tokens.clearRetainingCapacity();
    }

    fn platformPath(self: *const PlatformStore, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/platform.json", .{self.data_root});
    }

    /// Replace the in-memory catalog with the contents of {data_root}/platform.json.
    ///
    /// The file is read and parsed in full before any live state is dropped, so a
    /// truncated or malformed file (for example a concurrent CLI write) returns an
    /// error and leaves the current catalog serving requests untouched.
    /// Entries missing required fields are skipped rather than aborting the load.
    pub fn reload(self: *PlatformStore) !void {
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try self.platformPath(&path_buf);
        const bytes = try Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        defer self.allocator.free(bytes);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPlatformFile;
        const root = parsed.value.object;

        self.clearAll();

        if (jsonString(root, "admin_token")) |at| {
            self.admin_token = try self.allocator.dupe(u8, at);
        }

        if (jsonArray(root, "orgs")) |orgs_val| {
            for (orgs_val) |item| {
                if (item != .object) continue;
                const o = item.object;
                const id = jsonString(o, "id") orelse continue;
                const name = jsonString(o, "name") orelse continue;
                try self.orgs.append(self.allocator, .{
                    .id = try self.allocator.dupe(u8, id),
                    .name = try self.allocator.dupe(u8, name),
                });
            }
        }

        if (jsonArray(root, "workspaces")) |wss| {
            for (wss) |item| {
                if (item != .object) continue;
                const w = item.object;
                const id = jsonString(w, "id") orelse continue;
                const name = jsonString(w, "name") orelse continue;
                const org_id = jsonString(w, "org_id") orelse continue;
                try self.workspaces.append(self.allocator, .{
                    .id = try self.allocator.dupe(u8, id),
                    .name = try self.allocator.dupe(u8, name),
                    .org_id = try self.allocator.dupe(u8, org_id),
                });
            }
        }

        if (jsonArray(root, "tokens")) |toks| {
            for (toks) |item| {
                if (item != .object) continue;
                const t = item.object;
                const name = jsonString(t, "name") orelse continue;
                const token = jsonString(t, "token") orelse continue;
                var scopes: std.ArrayList(auth_mod.Scope) = .empty;
                errdefer scopes.deinit(self.allocator);
                if (jsonArray(t, "scopes")) |sc| {
                    for (sc) |s| {
                        if (s != .string) continue;
                        if (auth_mod.Scope.fromString(s.string)) |scope|
                            try scopes.append(self.allocator, scope);
                    }
                }
                try self.tokens.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, name),
                    .token = try self.allocator.dupe(u8, token),
                    .org_id = try self.allocator.dupe(u8, jsonString(t, "org_id") orelse ""),
                    .workspace_id = try self.allocator.dupe(u8, jsonString(t, "workspace_id") orelse ""),
                    .scopes = try scopes.toOwnedSlice(self.allocator),
                });
            }
        }
    }

    pub fn save(self: *PlatformStore) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        try aw.writer.writeAll("{\"version\":1,");

        if (self.admin_token) |at| {
            try aw.writer.print("\"admin_token\":{f},", .{std.json.fmt(at, .{})});
        } else {
            try aw.writer.writeAll("\"admin_token\":null,");
        }

        try aw.writer.writeAll("\"orgs\":[");
        for (self.orgs.items, 0..) |o, i| {
            if (i > 0) try aw.writer.writeAll(",");
            try aw.writer.print("{{\"id\":{f},\"name\":{f}}}", .{
                std.json.fmt(o.id, .{}),
                std.json.fmt(o.name, .{}),
            });
        }
        try aw.writer.writeAll("],\"workspaces\":[");
        for (self.workspaces.items, 0..) |w, i| {
            if (i > 0) try aw.writer.writeAll(",");
            try aw.writer.print("{{\"id\":{f},\"name\":{f},\"org_id\":{f}}}", .{
                std.json.fmt(w.id, .{}),
                std.json.fmt(w.name, .{}),
                std.json.fmt(w.org_id, .{}),
            });
        }
        try aw.writer.writeAll("],\"tokens\":[");
        for (self.tokens.items, 0..) |t, i| {
            if (i > 0) try aw.writer.writeAll(",");
            try aw.writer.print("{{\"name\":{f},\"token\":{f},\"org_id\":{f},\"workspace_id\":{f},\"scopes\":[", .{
                std.json.fmt(t.name, .{}),
                std.json.fmt(t.token, .{}),
                std.json.fmt(t.org_id, .{}),
                std.json.fmt(t.workspace_id, .{}),
            });
            for (t.scopes, 0..) |s, si| {
                if (si > 0) try aw.writer.writeAll(",");
                try aw.writer.print("{f}", .{std.json.fmt(s.toWire(), .{})});
            }
            try aw.writer.writeAll("]}");
        }
        try aw.writer.writeAll("]}");

        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try self.platformPath(&path_buf);
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = aw.written() });
    }

    // ── Initialization ──────────────────────────────────────────────────────

    /// Bootstrap a fresh platform in data_root. Idempotent if already exists.
    pub fn bootstrap(allocator: Allocator, io: Io, data_root: []const u8) ![]u8 {
        try Io.Dir.cwd().createDirPath(io, data_root);
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const ws_dir = try std.fmt.bufPrint(&path_buf, "{s}/workspaces", .{data_root});
        try Io.Dir.cwd().createDirPath(io, ws_dir);

        var store: PlatformStore = .{
            .allocator = allocator,
            .io = io,
            .data_root = try allocator.dupe(u8, data_root),
        };
        defer store.deinit();

        // Load existing if present.
        store.reload() catch {};

        // Generate admin token if not present.
        var admin_tok_buf: [40]u8 = undefined;
        var is_new = false;
        if (store.admin_token == null) {
            const tok = generateToken(io, "sk", &admin_tok_buf);
            store.admin_token = try allocator.dupe(u8, tok);
            is_new = true;
        }
        try store.save();

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.print(
            \\{{"platform_initialized":true,"data_root":{f},"admin_token":{f},"new":{s}}}
        , .{
            std.json.fmt(data_root, .{}),
            std.json.fmt(store.admin_token.?, .{}),
            if (is_new) "true" else "false",
        });
        return try aw.toOwnedSlice();
    }

    // ── Org operations ──────────────────────────────────────────────────────

    pub fn createOrg(self: *PlatformStore, name: []const u8) ![]u8 {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "org_{s}", .{shortId(self.io)});
        if (self.findOrg(id) != null) return error.OrgAlreadyExists;
        try self.orgs.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .name = try self.allocator.dupe(u8, name),
        });
        try self.save();
        return try std.fmt.allocPrint(self.allocator,
            \\{{"created":true,"org_id":{f},"name":{f}}}
        , .{ std.json.fmt(id, .{}), std.json.fmt(name, .{}) });
    }

    pub fn findOrg(self: *const PlatformStore, id: []const u8) ?Org {
        for (self.orgs.items) |o| {
            if (std.mem.eql(u8, o.id, id)) return o;
        }
        return null;
    }

    pub fn listOrgsJson(self: *const PlatformStore, allocator: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try aw.writer.writeAll("{\"orgs\":[");
        for (self.orgs.items, 0..) |o, i| {
            if (i > 0) try aw.writer.writeAll(",");
            try aw.writer.print("{{\"id\":{f},\"name\":{f}}}", .{
                std.json.fmt(o.id, .{}),
                std.json.fmt(o.name, .{}),
            });
        }
        try aw.writer.writeAll("]}");
        return try aw.toOwnedSlice();
    }

    // ── Workspace operations ────────────────────────────────────────────────

    pub fn createWorkspace(self: *PlatformStore, org_id: []const u8, name: []const u8) ![]u8 {
        if (self.findOrg(org_id) == null) return error.OrgNotFound;
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "ws_{s}", .{shortId(self.io)});
        if (self.findWorkspace(id) != null) return error.WorkspaceAlreadyExists;
        try self.workspaces.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .name = try self.allocator.dupe(u8, name),
            .org_id = try self.allocator.dupe(u8, org_id),
        });
        try self.save();
        return try std.fmt.allocPrint(self.allocator,
            \\{{"created":true,"workspace_id":{f},"name":{f},"org_id":{f}}}
        , .{
            std.json.fmt(id, .{}),
            std.json.fmt(name, .{}),
            std.json.fmt(org_id, .{}),
        });
    }

    pub fn findWorkspace(self: *const PlatformStore, id: []const u8) ?WorkspaceMeta {
        for (self.workspaces.items) |w| {
            if (std.mem.eql(u8, w.id, id)) return w;
        }
        return null;
    }

    pub fn listWorkspacesJson(self: *const PlatformStore, allocator: Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try aw.writer.writeAll("{\"workspaces\":[");
        for (self.workspaces.items, 0..) |w, i| {
            if (i > 0) try aw.writer.writeAll(",");
            try aw.writer.print("{{\"id\":{f},\"name\":{f},\"org_id\":{f}}}", .{
                std.json.fmt(w.id, .{}),
                std.json.fmt(w.name, .{}),
                std.json.fmt(w.org_id, .{}),
            });
        }
        try aw.writer.writeAll("]}");
        return try aw.toOwnedSlice();
    }

    /// List workspaces belonging to a specific org.
    /// Returns error.OrgNotFound if the org does not exist.
    pub fn listWorkspacesForOrgJson(self: *const PlatformStore, allocator: Allocator, org_id: []const u8) ![]u8 {
        if (self.findOrg(org_id) == null) return error.OrgNotFound;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try aw.writer.writeAll("{\"workspaces\":[");
        var first = true;
        for (self.workspaces.items) |w| {
            if (!std.mem.eql(u8, w.org_id, org_id)) continue;
            if (!first) try aw.writer.writeAll(",");
            first = false;
            try aw.writer.print("{{\"id\":{f},\"name\":{f},\"org_id\":{f}}}", .{
                std.json.fmt(w.id, .{}),
                std.json.fmt(w.name, .{}),
                std.json.fmt(w.org_id, .{}),
            });
        }
        try aw.writer.writeAll("]}");
        return try aw.toOwnedSlice();
    }

    /// Returns true if workspace_id is registered and belongs to org_id.
    pub fn orgOwnsWorkspace(self: *const PlatformStore, org_id: []const u8, workspace_id: []const u8) bool {
        for (self.workspaces.items) |w| {
            if (std.mem.eql(u8, w.id, workspace_id) and std.mem.eql(u8, w.org_id, org_id)) return true;
        }
        return false;
    }

    // ── Token operations ────────────────────────────────────────────────────

    pub fn mintToken(self: *PlatformStore, workspace_id: []const u8, name: []const u8, scope_str: []const u8) ![]u8 {
        if (self.findWorkspace(workspace_id) == null) return error.WorkspaceNotFound;
        const scope = auth_mod.Scope.fromString(scope_str) orelse return error.UnknownScope;
        var tok_buf: [40]u8 = undefined;
        const tok = generateToken(self.io, "p", &tok_buf);

        const org_id_owned: []const u8 = blk: {
            for (self.workspaces.items) |w| {
                if (std.mem.eql(u8, w.id, workspace_id)) break :blk try self.allocator.dupe(u8, w.org_id);
            }
            break :blk try self.allocator.dupe(u8, "");
        };
        const scopes = try self.allocator.dupe(auth_mod.Scope, &[_]auth_mod.Scope{scope});
        try self.tokens.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .token = try self.allocator.dupe(u8, tok),
            .org_id = org_id_owned,
            .workspace_id = try self.allocator.dupe(u8, workspace_id),
            .scopes = scopes,
        });
        try self.save();
        return try std.fmt.allocPrint(self.allocator,
            \\{{"created":true,"name":{f},"token":{f},"workspace_id":{f},"scopes":[{f}]}}
        , .{
            std.json.fmt(name, .{}),
            std.json.fmt(tok, .{}),
            std.json.fmt(workspace_id, .{}),
            std.json.fmt(scope.toWire(), .{}),
        });
    }

    // ── Auth helpers ────────────────────────────────────────────────────────

    /// Return the workspace_id that `token` is scoped to, or null.
    pub fn resolveWorkspaceId(self: *const PlatformStore, token: []const u8) ?[]const u8 {
        for (self.tokens.items) |t| {
            if (std.mem.eql(u8, t.token, token)) return t.workspace_id;
        }
        return null;
    }

    /// Returns true if `token` is the platform admin token.
    pub fn isAdminToken(self: *const PlatformStore, token: []const u8) bool {
        if (self.admin_token) |at| {
            if (std.mem.eql(u8, at, token)) return true;
        }
        return false;
    }

    /// Returns true if `token` is authorized to access `workspace_id` with `need` scope.
    pub fn authorizeWorkspaceToken(
        self: *const PlatformStore,
        token: []const u8,
        workspace_id: []const u8,
        need: auth_mod.Scope,
    ) bool {
        if (self.isAdminToken(token)) return true;
        for (self.tokens.items) |t| {
            if (!std.mem.eql(u8, t.token, token)) continue;
            if (!std.mem.eql(u8, t.workspace_id, workspace_id)) return false; // wrong workspace
            return tokenHasScope(t.scopes, need);
        }
        return false;
    }

    fn tokenHasScope(scopes: []const auth_mod.Scope, need: auth_mod.Scope) bool {
        for (scopes) |s| {
            if (s == .admin) return true;
            if (s == need) return true;
            if (need == .query_read and s == .pipes_read) return true;
        }
        return false;
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Read `key` from `obj` as a string, or null if absent/non-string/JSON null.
fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Read `key` from `obj` as an array, or null if absent/non-array.
fn jsonArray(obj: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

/// 8-byte CSPRNG identifier → 16 lowercase hex chars.
fn shortId(io: Io) [16]u8 {
    var rand_buf: [8]u8 = undefined;
    io.randomSecure(&rand_buf) catch io.random(&rand_buf);
    return std.fmt.bytesToHex(rand_buf, .lower);
}

/// CSPRNG token with a prefix: "prefix.{32 hex chars}".
/// buf must be at least prefix.len + 1 + 32 bytes.
fn generateToken(io: Io, prefix: []const u8, buf: []u8) []const u8 {
    var rand_buf: [16]u8 = undefined;
    io.randomSecure(&rand_buf) catch io.random(&rand_buf);
    const hex = std.fmt.bytesToHex(rand_buf, .lower);
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ prefix, &hex }) catch buf[0..0];
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "resolveWorkspaceId" {
    const gpa = std.testing.allocator;
    var store: PlatformStore = .{
        .allocator = gpa,
        .io = undefined,
        .data_root = try gpa.dupe(u8, "/tmp/test"),
    };
    defer store.deinit();

    const scopes = try gpa.dupe(auth_mod.Scope, &[_]auth_mod.Scope{.pipes_read});
    try store.tokens.append(gpa, .{
        .name = try gpa.dupe(u8, "reader"),
        .token = try gpa.dupe(u8, "p.abc"),
        .org_id = try gpa.dupe(u8, "org_1"),
        .workspace_id = try gpa.dupe(u8, "ws_1"),
        .scopes = scopes,
    });

    try std.testing.expectEqualStrings("ws_1", store.resolveWorkspaceId("p.abc").?);
    try std.testing.expect(store.resolveWorkspaceId("p.other") == null);
}

test "authorizeWorkspaceToken isolation" {
    const gpa = std.testing.allocator;
    var store: PlatformStore = .{
        .allocator = gpa,
        .io = undefined,
        .data_root = try gpa.dupe(u8, "/tmp/test"),
    };
    defer store.deinit();
    store.admin_token = try gpa.dupe(u8, "sk.admin");

    const scopes = try gpa.dupe(auth_mod.Scope, &[_]auth_mod.Scope{.pipes_read});
    try store.tokens.append(gpa, .{
        .name = try gpa.dupe(u8, "reader"),
        .token = try gpa.dupe(u8, "p.tok1"),
        .org_id = try gpa.dupe(u8, "org_1"),
        .workspace_id = try gpa.dupe(u8, "ws_a"),
        .scopes = scopes,
    });

    // Token for ws_a can access ws_a.
    try std.testing.expect(store.authorizeWorkspaceToken("p.tok1", "ws_a", .pipes_read));
    // Token for ws_a cannot access ws_b.
    try std.testing.expect(!store.authorizeWorkspaceToken("p.tok1", "ws_b", .pipes_read));
    // Admin token can access any workspace.
    try std.testing.expect(store.authorizeWorkspaceToken("sk.admin", "ws_a", .pipes_read));
    try std.testing.expect(store.authorizeWorkspaceToken("sk.admin", "ws_b", .admin));
}

test "mintToken rejects unknown scope" {
    const gpa = std.testing.allocator;
    var store: PlatformStore = .{
        .allocator = gpa,
        .io = undefined,
        .data_root = try gpa.dupe(u8, "/tmp/test"),
    };
    defer store.deinit();
    try store.workspaces.append(gpa, .{
        .id = try gpa.dupe(u8, "ws_1"),
        .name = try gpa.dupe(u8, "test"),
        .org_id = try gpa.dupe(u8, "org_1"),
    });

    try std.testing.expectError(error.UnknownScope, store.mintToken("ws_1", "t", "INVALID_SCOPE"));
    try std.testing.expectError(error.UnknownScope, store.mintToken("ws_1", "t", "MIND:READ"));
}

test "generateToken: 1000 tokens are all distinct" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var set: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = set.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        set.deinit(gpa);
    }
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var buf: [40]u8 = undefined;
        const tok = generateToken(io, "p", &buf);
        const owned = try gpa.dupe(u8, tok);
        const result = try set.getOrPut(gpa, owned);
        if (result.found_existing) {
            gpa.free(owned);
            return error.TokenCollision;
        }
    }
    try std.testing.expectEqual(@as(usize, 1000), set.count());
}

test "shortId: 1000 ids are all distinct" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var set: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = set.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        set.deinit(gpa);
    }
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const id = shortId(io);
        const owned = try gpa.dupe(u8, &id);
        const result = try set.getOrPut(gpa, owned);
        if (result.found_existing) {
            gpa.free(owned);
            return error.ShortIdCollision;
        }
    }
    try std.testing.expectEqual(@as(usize, 1000), set.count());
}

test "scope toWire round-trips through save/reload" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tmp = "/tmp/synapse_platform_roundtrip_test";

    try Io.Dir.cwd().createDirPath(io, tmp);

    var store: PlatformStore = .{
        .allocator = gpa,
        .io = io,
        .data_root = try gpa.dupe(u8, tmp),
    };

    store.admin_token = try gpa.dupe(u8, "sk.testadmin");
    try store.orgs.append(gpa, .{
        .id = try gpa.dupe(u8, "org_rt"),
        .name = try gpa.dupe(u8, "roundtrip"),
    });
    try store.workspaces.append(gpa, .{
        .id = try gpa.dupe(u8, "ws_rt"),
        .name = try gpa.dupe(u8, "rt"),
        .org_id = try gpa.dupe(u8, "org_rt"),
    });

    const all_scopes = try gpa.dupe(auth_mod.Scope, &[_]auth_mod.Scope{
        .admin, .pipes_read, .events_write, .remember_write, .query_read,
    });
    try store.tokens.append(gpa, .{
        .name = try gpa.dupe(u8, "all_scopes"),
        .token = try gpa.dupe(u8, "p.roundtrip"),
        .org_id = try gpa.dupe(u8, "org_rt"),
        .workspace_id = try gpa.dupe(u8, "ws_rt"),
        .scopes = all_scopes,
    });

    try store.save();
    try store.reload();

    try std.testing.expectEqual(@as(usize, 1), store.tokens.items.len);
    const loaded = store.tokens.items[0];
    try std.testing.expectEqual(@as(usize, 5), loaded.scopes.len);
    try std.testing.expectEqual(auth_mod.Scope.admin, loaded.scopes[0]);
    try std.testing.expectEqual(auth_mod.Scope.pipes_read, loaded.scopes[1]);
    try std.testing.expectEqual(auth_mod.Scope.events_write, loaded.scopes[2]);
    try std.testing.expectEqual(auth_mod.Scope.remember_write, loaded.scopes[3]);
    try std.testing.expectEqual(auth_mod.Scope.query_read, loaded.scopes[4]);

    store.deinit();
    Io.Dir.cwd().deleteFile(io, tmp ++ "/platform.json") catch {};
}

test "reload keeps the live catalog when platform.json is malformed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tmp = "/tmp/synapse_platform_torn_write_test";

    try Io.Dir.cwd().createDirPath(io, tmp);

    var store: PlatformStore = .{
        .allocator = gpa,
        .io = io,
        .data_root = try gpa.dupe(u8, tmp),
    };
    defer {
        store.deinit();
        Io.Dir.cwd().deleteFile(io, tmp ++ "/platform.json") catch {};
    }

    store.admin_token = try gpa.dupe(u8, "sk.keepme");
    try store.orgs.append(gpa, .{
        .id = try gpa.dupe(u8, "org_keep"),
        .name = try gpa.dupe(u8, "keep"),
    });
    try store.save();
    try store.reload();
    try std.testing.expectEqual(@as(usize, 1), store.orgs.items.len);

    // Simulate a torn write from a concurrent CLI process.
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp ++ "/platform.json",
        .data = "{\"version\":1,\"orgs\":[{\"id\":\"org_k",
    });
    if (store.reload()) |_| return error.ExpectedReloadFailure else |_| {}

    // Previous catalog must still be intact and serving.
    try std.testing.expectEqual(@as(usize, 1), store.orgs.items.len);
    try std.testing.expectEqualStrings("org_keep", store.orgs.items[0].id);
    try std.testing.expectEqualStrings("sk.keepme", store.admin_token.?);

    // A non-object document is rejected without clobbering state either.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp ++ "/platform.json", .data = "[]" });
    try std.testing.expectError(error.InvalidPlatformFile, store.reload());
    try std.testing.expectEqual(@as(usize, 1), store.orgs.items.len);
}
