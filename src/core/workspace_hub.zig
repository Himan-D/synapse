/// WorkspaceHub: lazy-load workspace instances from {data_root}/workspaces/{id}/.
/// Holds a PlatformStore reference for token resolution.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const workspace_mod = @import("workspace.zig");
const platform_mod = @import("platform.zig");
const usage_mod = @import("usage.zig");
const audit_mod = @import("audit.zig");
const auth_mod = @import("auth.zig");

/// Result of an authorization check.
pub const AuthResult = enum {
    ok,
    /// No token presented, or the token is unknown to the platform store.
    unauthorized,
    /// Token is valid but bound to a different workspace or has insufficient scope.
    forbidden,
};

pub const WorkspaceHub = struct {
    allocator: Allocator,
    io: Io,
    data_root: []const u8,
    platform: platform_mod.PlatformStore,
    usage: usage_mod.UsageStore,
    audit: audit_mod.AuditStore,
    /// Lazily loaded workspaces, keyed by workspace id.
    loaded: std.StringHashMapUnmanaged(*workspace_mod.Workspace) = .empty,

    pub fn init(allocator: Allocator, io: Io, data_root: []const u8) !WorkspaceHub {
        var platform = try platform_mod.PlatformStore.init(allocator, io, data_root);
        errdefer platform.deinit();
        const usage = try usage_mod.UsageStore.init(allocator, io, data_root);
        const audit = try audit_mod.AuditStore.init(allocator, io, data_root);
        return .{
            .allocator = allocator,
            .io = io,
            .data_root = try allocator.dupe(u8, data_root),
            .platform = platform,
            .usage = usage,
            .audit = audit,
        };
    }

    pub fn deinit(self: *WorkspaceHub) void {
        var it = self.loaded.valueIterator();
        while (it.next()) |ws_ptr| {
            ws_ptr.*.deinit();
            self.allocator.destroy(ws_ptr.*);
        }
        var kit = self.loaded.keyIterator();
        while (kit.next()) |k| self.allocator.free(k.*);
        self.loaded.deinit(self.allocator);
        self.usage.deinit();
        self.audit.deinit();
        self.platform.deinit();
        self.allocator.free(self.data_root);
        self.* = undefined;
    }

    // ── Workspace resolution ─────────────────────────────────────────────────

    /// Get or lazily load a workspace by id.
    /// Returns null if the workspace is not registered in the platform store.
    pub fn get(self: *WorkspaceHub, workspace_id: []const u8) !?*workspace_mod.Workspace {
        if (self.loaded.get(workspace_id)) |ws| return ws;

        // Check platform store knows this workspace.
        if (self.platform.findWorkspace(workspace_id) == null) return null;

        // Load from {data_root}/workspaces/{id}/.
        const ws_root = try std.fmt.allocPrint(self.allocator, "{s}/workspaces/{s}", .{
            self.data_root,
            workspace_id,
        });
        defer self.allocator.free(ws_root);

        const ws_ptr = try self.allocator.create(workspace_mod.Workspace);
        ws_ptr.* = workspace_mod.Workspace.load(self.allocator, self.io, ws_root) catch |err| {
            self.allocator.destroy(ws_ptr);
            return err;
        };

        const id_owned = try self.allocator.dupe(u8, workspace_id);
        try self.loaded.put(self.allocator, id_owned, ws_ptr);
        return ws_ptr;
    }

    /// Scaffold a workspace directory and register in platform store.
    /// Cloud scaffolding skips writing a local token; auth is handled by the platform store.
    pub fn scaffoldWorkspace(
        self: *WorkspaceHub,
        workspace_id: []const u8,
        name: []const u8,
    ) !void {
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const ws_root = try std.fmt.bufPrint(&path_buf, "{s}/workspaces/{s}", .{
            self.data_root,
            workspace_id,
        });
        try workspace_mod.initWorkspace(self.allocator, self.io, ws_root, name, .{ .write_local_token = false });
    }

    // ── Auth helpers ─────────────────────────────────────────────────────────

    /// Authorize a request for a specific workspace using the platform token store only.
    ///
    /// Returns:
    ///   .ok         — token is valid and authorized for this workspace+scope
    ///   .unauthorized — no token, or token is unknown to the platform
    ///   .forbidden  — token is known but bound to a different workspace or wrong scope
    ///
    /// The workspace's own `.synapse/token` file is intentionally NOT checked here;
    /// cloud routing must go through the platform store exclusively.
    pub fn authorizeForWorkspace(
        self: *WorkspaceHub,
        workspace_id: []const u8,
        head_buffer: []const u8,
        method: std.http.Method,
        path: []const u8,
    ) AuthResult {
        const need = auth_mod.Auth.requiredScope(method, path) orelse return .ok;
        const presented = auth_mod.Auth.extractPresentedToken(head_buffer) orelse return .unauthorized;

        if (self.platform.isAdminToken(presented)) return .ok;

        // Resolve which workspace this token is bound to.
        const token_ws = self.platform.resolveWorkspaceId(presented);
        if (token_ws == null) return .unauthorized; // unknown token

        // Token is valid but bound to the wrong workspace.
        if (!std.mem.eql(u8, token_ws.?, workspace_id)) return .forbidden;

        // Right workspace — check scope.
        return if (self.platform.authorizeWorkspaceToken(presented, workspace_id, need)) .ok else .forbidden;
    }

    /// Authorize an admin-only control-plane request.
    pub fn adminAuth(self: *WorkspaceHub, head_buffer: []const u8) AuthResult {
        const tok = auth_mod.Auth.extractPresentedToken(head_buffer) orelse return .unauthorized;
        return if (self.platform.isAdminToken(tok)) .ok else .forbidden;
    }

    // ── Workflow tick ─────────────────────────────────────────────────────────

    /// Tick durable workflows across all currently-loaded workspaces.
    pub fn tickAll(self: *WorkspaceHub) void {
        var it = self.loaded.valueIterator();
        while (it.next()) |ws_ptr| {
            const ticked = ws_ptr.*.workflowTick() catch continue;
            self.allocator.free(ticked);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "hub get unknown workspace" {
    const gpa = std.testing.allocator;
    const tmp_dir = "/tmp/synapse_hub_test";
    // We can't easily create a full platform in a test, so just verify hub
    // returns null for an unregistered workspace id.
    var hub: WorkspaceHub = .{
        .allocator = gpa,
        .io = undefined,
        .data_root = try gpa.dupe(u8, tmp_dir),
        .platform = .{
            .allocator = gpa,
            .io = undefined,
            .data_root = try gpa.dupe(u8, tmp_dir),
        },
        .usage = .{
            .allocator = gpa,
            .io = undefined,
            .data_root = try gpa.dupe(u8, tmp_dir),
        },
        .audit = .{
            .allocator = gpa,
            .io = undefined,
            .data_root = try gpa.dupe(u8, tmp_dir),
        },
    };
    defer hub.deinit();

    const ws = try hub.get("nonexistent_ws");
    try std.testing.expect(ws == null);
}

test "authorizeForWorkspace: 401 vs 403 distinction" {
    const gpa = std.testing.allocator;
    var hub: WorkspaceHub = .{
        .allocator = gpa,
        .io = undefined,
        .data_root = try gpa.dupe(u8, "/tmp/hub_auth_test"),
        .platform = .{
            .allocator = gpa,
            .io = undefined,
            .data_root = try gpa.dupe(u8, "/tmp/hub_auth_test"),
        },
        .usage = .{
            .allocator = gpa,
            .io = undefined,
            .data_root = try gpa.dupe(u8, "/tmp/hub_auth_test"),
        },
        .audit = .{
            .allocator = gpa,
            .io = undefined,
            .data_root = try gpa.dupe(u8, "/tmp/hub_auth_test"),
        },
    };
    defer hub.deinit();

    const admin_hash = platform_mod.hashTokenHex("sk.admintoken");
    hub.platform.admin_token_hash = try gpa.dupe(u8, &admin_hash);

    const scopes = try gpa.dupe(auth_mod.Scope, &[_]auth_mod.Scope{.admin});
    const token_hash = platform_mod.hashTokenHex("p.tokenA");
    try hub.platform.tokens.append(gpa, .{
        .id = try gpa.dupe(u8, "tok_a"),
        .name = try gpa.dupe(u8, "tok_a"),
        .token_hash = try gpa.dupe(u8, &token_hash),
        .org_id = try gpa.dupe(u8, "org_1"),
        .workspace_id = try gpa.dupe(u8, "ws_alpha"),
        .scopes = scopes,
    });

    const head_no_token = "GET /v1/workspace HTTP/1.1\r\n\r\n";
    const head_token_a = "GET /v1/workspace HTTP/1.1\r\nAuthorization: Bearer p.tokenA\r\n\r\n";
    const head_unknown = "GET /v1/workspace HTTP/1.1\r\nAuthorization: Bearer p.unknown\r\n\r\n";
    const head_admin = "GET /v1/workspace HTTP/1.1\r\nAuthorization: Bearer sk.admintoken\r\n\r\n";

    // No token → 401
    try std.testing.expectEqual(AuthResult.unauthorized, hub.authorizeForWorkspace("ws_alpha", head_no_token, .GET, "/v1/workspace"));
    // Unknown token → 401
    try std.testing.expectEqual(AuthResult.unauthorized, hub.authorizeForWorkspace("ws_alpha", head_unknown, .GET, "/v1/workspace"));
    // Token for ws_alpha on ws_alpha → ok
    try std.testing.expectEqual(AuthResult.ok, hub.authorizeForWorkspace("ws_alpha", head_token_a, .GET, "/v1/workspace"));
    // Token for ws_alpha on ws_beta → 403
    try std.testing.expectEqual(AuthResult.forbidden, hub.authorizeForWorkspace("ws_beta", head_token_a, .GET, "/v1/workspace"));
    // Admin token on any workspace → ok
    try std.testing.expectEqual(AuthResult.ok, hub.authorizeForWorkspace("ws_beta", head_admin, .GET, "/v1/workspace"));
}
