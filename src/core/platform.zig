/// PlatformStore: org → workspace → scoped token multi-tenancy layer.
/// Persists to {data_root}/platform.json.
/// Schema-versioned; safe to extend additive fields.
///
/// Tokens are stored as SHA-256 hex digests only. The raw secret is returned
/// exactly once, in the mint response; it is never written to disk and cannot
/// be recovered afterwards. Files written by an older build (plaintext `token`
/// / `admin_token`) are migrated to digests on first load.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const auth_mod = @import("auth.zig");
const safe_name = @import("safe_name.zig");

/// SHA-256 rendered as lowercase hex.
pub const hash_hex_len = 64;

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
    id: []const u8,
    name: []const u8,
    /// SHA-256 hex of the raw token. The raw token is never persisted.
    token_hash: []const u8,
    org_id: []const u8,
    workspace_id: []const u8,
    scopes: []const auth_mod.Scope,
    created_at: i64 = 0,
    /// Unix seconds; null = no expiry.
    expires_at: ?i64 = null,
    revoked: bool = false,
};

// ── PlatformStore ─────────────────────────────────────────────────────────────

pub const PlatformStore = struct {
    allocator: Allocator,
    io: Io,
    data_root: []const u8,
    /// SHA-256 hex of the platform admin token.
    admin_token_hash: ?[]const u8 = null,
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
        if (self.admin_token_hash) |t| {
            self.allocator.free(t);
            self.admin_token_hash = null;
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
            self.allocator.free(t.id);
            self.allocator.free(t.name);
            self.allocator.free(t.token_hash);
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
    ///
    /// A file still carrying plaintext secrets is upgraded to digests in memory
    /// and rewritten immediately, so the plaintext survives at most one load.
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

        // Plaintext secrets from a pre-hash build are hashed here and the file is
        // rewritten below, so they exist on disk for at most one more instant.
        var migrated = false;

        if (jsonString(root, "admin_token_hash")) |h| {
            self.admin_token_hash = try self.allocator.dupe(u8, h);
        } else if (jsonString(root, "admin_token")) |plain| {
            const h = hashTokenHex(plain);
            self.admin_token_hash = try self.allocator.dupe(u8, &h);
            migrated = true;
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

                var hash_buf: [hash_hex_len]u8 = undefined;
                const hash: []const u8 = blk: {
                    if (jsonString(t, "token_hash")) |h| break :blk h;
                    if (jsonString(t, "token")) |plain| {
                        hash_buf = hashTokenHex(plain);
                        migrated = true;
                        break :blk hash_buf[0..];
                    }
                    break :blk "";
                };
                if (hash.len == 0) continue;

                var id_buf: [32]u8 = undefined;
                const id: []const u8 = blk: {
                    if (jsonString(t, "id")) |i| break :blk i;
                    migrated = true;
                    break :blk std.fmt.bufPrint(&id_buf, "tok_{s}", .{shortId(self.io)}) catch continue;
                };

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
                    .id = try self.allocator.dupe(u8, id),
                    .name = try self.allocator.dupe(u8, name),
                    .token_hash = try self.allocator.dupe(u8, hash),
                    .org_id = try self.allocator.dupe(u8, jsonString(t, "org_id") orelse ""),
                    .workspace_id = try self.allocator.dupe(u8, jsonString(t, "workspace_id") orelse ""),
                    .scopes = try scopes.toOwnedSlice(self.allocator),
                    .created_at = jsonInt(t, "created_at") orelse 0,
                    .expires_at = jsonInt(t, "expires_at"),
                    .revoked = jsonBool(t, "revoked") orelse false,
                });
            }
        }

        if (migrated) {
            self.save() catch |err| {
                std.log.warn("platform.json secret migration could not be persisted: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn save(self: *PlatformStore) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        try aw.writer.writeAll("{\"version\":2,");

        if (self.admin_token_hash) |h| {
            try aw.writer.print("\"admin_token_hash\":{f},", .{std.json.fmt(h, .{})});
        } else {
            try aw.writer.writeAll("\"admin_token_hash\":null,");
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
            try aw.writer.print(
                "{{\"id\":{f},\"name\":{f},\"token_hash\":{f},\"org_id\":{f},\"workspace_id\":{f}," ++
                    "\"created_at\":{d},\"expires_at\":",
                .{
                    std.json.fmt(t.id, .{}),
                    std.json.fmt(t.name, .{}),
                    std.json.fmt(t.token_hash, .{}),
                    std.json.fmt(t.org_id, .{}),
                    std.json.fmt(t.workspace_id, .{}),
                    t.created_at,
                },
            );
            if (t.expires_at) |exp| {
                try aw.writer.print("{d},\"revoked\":{s},\"scopes\":[", .{ exp, if (t.revoked) "true" else "false" });
            } else {
                try aw.writer.print("null,\"revoked\":{s},\"scopes\":[", .{if (t.revoked) "true" else "false"});
            }
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
    ///
    /// The admin token is printed only on the run that creates it; re-running
    /// reports `"admin_token":null` because only the digest survives on disk.
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

        var admin_tok_buf: [40]u8 = undefined;
        var minted: ?[]const u8 = null;
        if (store.admin_token_hash == null) {
            const tok = generateToken(io, "sk", &admin_tok_buf);
            const h = hashTokenHex(tok);
            store.admin_token_hash = try allocator.dupe(u8, &h);
            minted = tok;
        }
        try store.save();

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        if (minted) |tok| {
            try aw.writer.print(
                \\{{"platform_initialized":true,"data_root":{f},"admin_token":{f},"new":true}}
            , .{ std.json.fmt(data_root, .{}), std.json.fmt(tok, .{}) });
        } else {
            try aw.writer.print(
                \\{{"platform_initialized":true,"data_root":{f},"admin_token":null,"new":false,"hint":"admin token is stored hashed; it is shown only when first created"}}
            , .{std.json.fmt(data_root, .{})});
        }
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

    /// Mint a workspace token. The returned JSON carries the raw secret; this is
    /// the only time it exists outside the caller's memory.
    /// Pass ttl_seconds > 0 to set expires_at = now + ttl.
    pub fn mintToken(self: *PlatformStore, workspace_id: []const u8, name: []const u8, scope_str: []const u8, ttl_seconds: ?i64) ![]u8 {
        if (self.findWorkspace(workspace_id) == null) return error.WorkspaceNotFound;
        const scope = auth_mod.Scope.fromString(scope_str) orelse return error.UnknownScope;
        var tok_buf: [40]u8 = undefined;
        const tok = generateToken(self.io, "p", &tok_buf);
        const hash = hashTokenHex(tok);

        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "tok_{s}", .{shortId(self.io)});
        const created_at = nowSeconds(self.io);
        const expires_at: ?i64 = if (ttl_seconds) |ttl| blk: {
            if (ttl <= 0) break :blk null;
            break :blk created_at + ttl;
        } else null;

        const org_id_owned: []const u8 = blk: {
            for (self.workspaces.items) |w| {
                if (std.mem.eql(u8, w.id, workspace_id)) break :blk try self.allocator.dupe(u8, w.org_id);
            }
            break :blk try self.allocator.dupe(u8, "");
        };
        const scopes = try self.allocator.dupe(auth_mod.Scope, &[_]auth_mod.Scope{scope});
        try self.tokens.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .name = try self.allocator.dupe(u8, name),
            .token_hash = try self.allocator.dupe(u8, &hash),
            .org_id = org_id_owned,
            .workspace_id = try self.allocator.dupe(u8, workspace_id),
            .scopes = scopes,
            .created_at = created_at,
            .expires_at = expires_at,
            .revoked = false,
        });
        try self.save();
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        try aw.writer.print(
            \\{{"created":true,"id":{f},"name":{f},"token":{f},"workspace_id":{f},"scopes":[{f}],"created_at":{d},"expires_at":
        , .{
            std.json.fmt(id, .{}),
            std.json.fmt(name, .{}),
            std.json.fmt(tok, .{}),
            std.json.fmt(workspace_id, .{}),
            std.json.fmt(scope.toWire(), .{}),
            created_at,
        });
        if (expires_at) |exp| {
            try aw.writer.print("{d}", .{exp});
        } else {
            try aw.writer.writeAll("null");
        }
        try aw.writer.writeAll(",\"hint\":\"store this token now; only its SHA-256 digest is kept\"}");
        return try aw.toOwnedSlice();
    }

    pub fn findTokenById(self: *const PlatformStore, id: []const u8) ?PlatformToken {
        for (self.tokens.items) |t| {
            if (std.mem.eql(u8, t.id, id)) return t;
        }
        return null;
    }

    /// Mark a token revoked. Idempotent: revoking an already-revoked token succeeds.
    pub fn revokeToken(self: *PlatformStore, id: []const u8) ![]u8 {
        for (self.tokens.items) |*t| {
            if (!std.mem.eql(u8, t.id, id)) continue;
            const already = t.revoked;
            t.revoked = true;
            if (!already) try self.save();
            return try std.fmt.allocPrint(self.allocator,
                \\{{"revoked":true,"id":{f},"workspace_id":{f},"already_revoked":{s}}}
            , .{
                std.json.fmt(t.id, .{}),
                std.json.fmt(t.workspace_id, .{}),
                if (already) "true" else "false",
            });
        }
        return error.TokenNotFound;
    }

    /// Token metadata for admin surfaces. Never includes a secret or a digest.
    /// Pass an empty workspace_id to list every workspace.
    pub fn listTokensJson(self: *const PlatformStore, allocator: Allocator, workspace_id: []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try aw.writer.writeAll("{\"tokens\":[");
        var first = true;
        for (self.tokens.items) |t| {
            if (workspace_id.len > 0 and !std.mem.eql(u8, t.workspace_id, workspace_id)) continue;
            if (!first) try aw.writer.writeAll(",");
            first = false;
            try aw.writer.print(
                "{{\"id\":{f},\"name\":{f},\"org_id\":{f},\"workspace_id\":{f},\"created_at\":{d},\"expires_at\":",
                .{
                    std.json.fmt(t.id, .{}),
                    std.json.fmt(t.name, .{}),
                    std.json.fmt(t.org_id, .{}),
                    std.json.fmt(t.workspace_id, .{}),
                    t.created_at,
                },
            );
            if (t.expires_at) |exp| {
                try aw.writer.print("{d},\"revoked\":{s},\"scopes\":[", .{ exp, if (t.revoked) "true" else "false" });
            } else {
                try aw.writer.print("null,\"revoked\":{s},\"scopes\":[", .{if (t.revoked) "true" else "false"});
            }
            for (t.scopes, 0..) |s, si| {
                if (si > 0) try aw.writer.writeAll(",");
                try aw.writer.print("{f}", .{std.json.fmt(s.toWire(), .{})});
            }
            try aw.writer.writeAll("]}");
        }
        try aw.writer.writeAll("]}");
        return try aw.toOwnedSlice();
    }

    // ── Auth helpers ────────────────────────────────────────────────────────

    /// Return the workspace_id that `token` is scoped to, or null.
    /// Revoked or expired tokens resolve to null.
    pub fn resolveWorkspaceId(self: *const PlatformStore, token: []const u8) ?[]const u8 {
        const presented = hashTokenHex(token);
        const now = nowSeconds(self.io);
        for (self.tokens.items) |t| {
            if (t.revoked) continue;
            if (tokenExpired(t, now)) continue;
            if (hashEql(t.token_hash, &presented)) return t.workspace_id;
        }
        return null;
    }

    /// Returns true if `token` is the platform admin token.
    pub fn isAdminToken(self: *const PlatformStore, token: []const u8) bool {
        const stored = self.admin_token_hash orelse return false;
        const presented = hashTokenHex(token);
        return hashEql(stored, &presented);
    }

    /// Returns true if `token` is authorized to access `workspace_id` with `need` scope.
    pub fn authorizeWorkspaceToken(
        self: *const PlatformStore,
        token: []const u8,
        workspace_id: []const u8,
        need: auth_mod.Scope,
    ) bool {
        if (self.isAdminToken(token)) return true;
        const presented = hashTokenHex(token);
        const now = nowSeconds(self.io);
        for (self.tokens.items) |t| {
            if (t.revoked) continue;
            if (tokenExpired(t, now)) continue;
            if (!hashEql(t.token_hash, &presented)) continue;
            if (!std.mem.eql(u8, t.workspace_id, workspace_id)) return false; // wrong workspace
            return tokenHasScope(t.scopes, need);
        }
        return false;
    }

    fn tokenExpired(t: PlatformToken, now: i64) bool {
        if (t.expires_at) |exp| return now >= exp;
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

/// SHA-256 of `token`, lowercase hex.
pub fn hashTokenHex(token: []const u8) [hash_hex_len]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Constant-time digest comparison. A malformed stored digest never matches.
fn hashEql(stored: []const u8, presented: *const [hash_hex_len]u8) bool {
    if (stored.len != hash_hex_len) return false;
    return std.crypto.timing_safe.eql([hash_hex_len]u8, stored[0..hash_hex_len].*, presented.*);
}

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

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn nowSeconds(io: Io) i64 {
    return @max(Io.Clock.real.now(io).toSeconds(), 0);
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

/// Append a token whose raw secret is `raw`, storing only its digest.
fn appendTestToken(
    store: *PlatformStore,
    gpa: Allocator,
    id: []const u8,
    name: []const u8,
    raw: []const u8,
    org_id: []const u8,
    workspace_id: []const u8,
    scopes: []const auth_mod.Scope,
) !void {
    const hash = hashTokenHex(raw);
    try store.tokens.append(gpa, .{
        .id = try gpa.dupe(u8, id),
        .name = try gpa.dupe(u8, name),
        .token_hash = try gpa.dupe(u8, &hash),
        .org_id = try gpa.dupe(u8, org_id),
        .workspace_id = try gpa.dupe(u8, workspace_id),
        .scopes = try gpa.dupe(auth_mod.Scope, scopes),
    });
}

test "resolveWorkspaceId" {
    const gpa = std.testing.allocator;
    var store: PlatformStore = .{
        .allocator = gpa,
        .io = undefined,
        .data_root = try gpa.dupe(u8, "/tmp/test"),
    };
    defer store.deinit();

    try appendTestToken(&store, gpa, "tok_1", "reader", "p.abc", "org_1", "ws_1", &.{.pipes_read});

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
    const admin_hash = hashTokenHex("sk.admin");
    store.admin_token_hash = try gpa.dupe(u8, &admin_hash);

    try appendTestToken(&store, gpa, "tok_1", "reader", "p.tok1", "org_1", "ws_a", &.{.pipes_read});

    // Token for ws_a can access ws_a.
    try std.testing.expect(store.authorizeWorkspaceToken("p.tok1", "ws_a", .pipes_read));
    // Token for ws_a cannot access ws_b.
    try std.testing.expect(!store.authorizeWorkspaceToken("p.tok1", "ws_b", .pipes_read));
    // Admin token can access any workspace.
    try std.testing.expect(store.authorizeWorkspaceToken("sk.admin", "ws_a", .pipes_read));
    try std.testing.expect(store.authorizeWorkspaceToken("sk.admin", "ws_b", .admin));
}

test "revoked token stops authorizing" {
    const gpa = std.testing.allocator;
    var store: PlatformStore = .{
        .allocator = gpa,
        .io = undefined,
        .data_root = try gpa.dupe(u8, "/tmp/test"),
    };
    defer store.deinit();

    try appendTestToken(&store, gpa, "tok_rev", "reader", "p.rev", "org_1", "ws_a", &.{.pipes_read});
    try std.testing.expect(store.authorizeWorkspaceToken("p.rev", "ws_a", .pipes_read));

    store.tokens.items[0].revoked = true;

    try std.testing.expect(!store.authorizeWorkspaceToken("p.rev", "ws_a", .pipes_read));
    try std.testing.expect(store.resolveWorkspaceId("p.rev") == null);
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

    try std.testing.expectError(error.UnknownScope, store.mintToken("ws_1", "t", "INVALID_SCOPE", null));
    try std.testing.expectError(error.UnknownScope, store.mintToken("ws_1", "t", "MIND:READ", null));
}

test "mint → authorize → revoke → reject, with no raw secret on disk" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tmp = "/tmp/synapse_platform_token_lifecycle_test";

    try Io.Dir.cwd().createDirPath(io, tmp);
    defer Io.Dir.cwd().deleteFile(io, tmp ++ "/platform.json") catch {};

    const boot = try PlatformStore.bootstrap(gpa, io, tmp);
    defer gpa.free(boot);
    var boot_parsed = try std.json.parseFromSlice(std.json.Value, gpa, boot, .{});
    defer boot_parsed.deinit();
    const admin_raw = try gpa.dupe(u8, boot_parsed.value.object.get("admin_token").?.string);
    defer gpa.free(admin_raw);

    var store = try PlatformStore.init(gpa, io, tmp);
    defer store.deinit();

    const org_json = try store.createOrg("acme");
    defer gpa.free(org_json);
    var org_parsed = try std.json.parseFromSlice(std.json.Value, gpa, org_json, .{});
    defer org_parsed.deinit();
    const org_id = org_parsed.value.object.get("org_id").?.string;

    const ws_json = try store.createWorkspace(org_id, "alpha");
    defer gpa.free(ws_json);
    var ws_parsed = try std.json.parseFromSlice(std.json.Value, gpa, ws_json, .{});
    defer ws_parsed.deinit();
    const ws_id = try gpa.dupe(u8, ws_parsed.value.object.get("workspace_id").?.string);
    defer gpa.free(ws_id);

    const mint_json = try store.mintToken(ws_id, "writer", "ADMIN", null);
    defer gpa.free(mint_json);
    var mint_parsed = try std.json.parseFromSlice(std.json.Value, gpa, mint_json, .{});
    defer mint_parsed.deinit();
    const raw = try gpa.dupe(u8, mint_parsed.value.object.get("token").?.string);
    defer gpa.free(raw);
    const tok_id = try gpa.dupe(u8, mint_parsed.value.object.get("id").?.string);
    defer gpa.free(tok_id);

    try std.testing.expect(store.authorizeWorkspaceToken(raw, ws_id, .admin));
    try std.testing.expect(store.isAdminToken(admin_raw));

    // Neither the workspace token nor the admin token is recoverable from disk.
    const on_disk = try Io.Dir.cwd().readFileAlloc(io, tmp ++ "/platform.json", gpa, .unlimited);
    defer gpa.free(on_disk);
    try std.testing.expect(std.mem.indexOf(u8, on_disk, raw) == null);
    try std.testing.expect(std.mem.indexOf(u8, on_disk, admin_raw) == null);
    try std.testing.expect(std.mem.indexOf(u8, on_disk, "p.") == null);
    try std.testing.expect(std.mem.indexOf(u8, on_disk, "sk.") == null);

    // Listings expose metadata only.
    const listing = try store.listTokensJson(gpa, ws_id);
    defer gpa.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, raw) == null);
    try std.testing.expect(std.mem.indexOf(u8, listing, tok_id) != null);

    const revoke_json = try store.revokeToken(tok_id);
    defer gpa.free(revoke_json);
    try std.testing.expect(!store.authorizeWorkspaceToken(raw, ws_id, .admin));

    // Revocation survives a reload.
    try store.reload();
    try std.testing.expect(!store.authorizeWorkspaceToken(raw, ws_id, .admin));
    try std.testing.expectError(error.TokenNotFound, store.revokeToken("tok_nonexistent"));
}

test "legacy plaintext platform.json is migrated to digests on load" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const tmp = "/tmp/synapse_platform_migration_test";

    try Io.Dir.cwd().createDirPath(io, tmp);
    defer Io.Dir.cwd().deleteFile(io, tmp ++ "/platform.json") catch {};

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp ++ "/platform.json",
        .data =
        \\{"version":1,"admin_token":"sk.legacyadmin","orgs":[{"id":"org_l","name":"legacy"}],
        \\"workspaces":[{"id":"ws_l","name":"legacy","org_id":"org_l"}],
        \\"tokens":[{"name":"legacy_writer","token":"p.legacytoken","org_id":"org_l","workspace_id":"ws_l","scopes":["ADMIN"]}]}
        ,
    });

    var store = try PlatformStore.init(gpa, io, tmp);
    defer store.deinit();

    // Migrated tokens keep working and gain an id.
    try std.testing.expect(store.isAdminToken("sk.legacyadmin"));
    try std.testing.expect(store.authorizeWorkspaceToken("p.legacytoken", "ws_l", .admin));
    try std.testing.expectEqual(@as(usize, 1), store.tokens.items.len);
    try std.testing.expect(std.mem.startsWith(u8, store.tokens.items[0].id, "tok_"));

    // The rewritten file no longer carries the plaintext.
    const on_disk = try Io.Dir.cwd().readFileAlloc(io, tmp ++ "/platform.json", gpa, .unlimited);
    defer gpa.free(on_disk);
    try std.testing.expect(std.mem.indexOf(u8, on_disk, "sk.legacyadmin") == null);
    try std.testing.expect(std.mem.indexOf(u8, on_disk, "p.legacytoken") == null);
    try std.testing.expect(std.mem.indexOf(u8, on_disk, "\"token\":") == null);
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

    const admin_hash = hashTokenHex("sk.testadmin");
    store.admin_token_hash = try gpa.dupe(u8, &admin_hash);
    try store.orgs.append(gpa, .{
        .id = try gpa.dupe(u8, "org_rt"),
        .name = try gpa.dupe(u8, "roundtrip"),
    });
    try store.workspaces.append(gpa, .{
        .id = try gpa.dupe(u8, "ws_rt"),
        .name = try gpa.dupe(u8, "rt"),
        .org_id = try gpa.dupe(u8, "org_rt"),
    });

    try appendTestToken(&store, gpa, "tok_rt", "all_scopes", "p.roundtrip", "org_rt", "ws_rt", &.{
        .admin, .pipes_read, .events_write, .remember_write, .query_read,
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
    try std.testing.expectEqualStrings("tok_rt", loaded.id);
    try std.testing.expect(store.authorizeWorkspaceToken("p.roundtrip", "ws_rt", .admin));

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

    const admin_hash = hashTokenHex("sk.keepme");
    store.admin_token_hash = try gpa.dupe(u8, &admin_hash);
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
        .data = "{\"version\":2,\"orgs\":[{\"id\":\"org_k",
    });
    if (store.reload()) |_| return error.ExpectedReloadFailure else |_| {}

    // Previous catalog must still be intact and serving.
    try std.testing.expectEqual(@as(usize, 1), store.orgs.items.len);
    try std.testing.expectEqualStrings("org_keep", store.orgs.items[0].id);
    try std.testing.expect(store.isAdminToken("sk.keepme"));

    // A non-object document is rejected without clobbering state either.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp ++ "/platform.json", .data = "[]" });
    try std.testing.expectError(error.InvalidPlatformFile, store.reload());
    try std.testing.expectEqual(@as(usize, 1), store.orgs.items.len);
}
