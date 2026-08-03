/// WorkspaceHub: lazy-load workspace instances from {data_root}/workspaces/{id}/.
/// Holds a PlatformStore reference for token resolution.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const workspace_mod = @import("workspace.zig");
const platform_mod = @import("platform.zig");
const auth_mod = @import("auth.zig");

pub const WorkspaceHub = struct {
    allocator: Allocator,
    io: Io,
    data_root: []const u8,
    platform: platform_mod.PlatformStore,
    /// Lazily loaded workspaces, keyed by workspace id.
    loaded: std.StringHashMapUnmanaged(*workspace_mod.Workspace) = .empty,

    pub fn init(allocator: Allocator, io: Io, data_root: []const u8) !WorkspaceHub {
        const platform = try platform_mod.PlatformStore.init(allocator, io, data_root);
        return .{
            .allocator = allocator,
            .io = io,
            .data_root = try allocator.dupe(u8, data_root),
            .platform = platform,
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
    /// Called from CLI `workspace create` after the platform entry is written.
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
        try workspace_mod.initWorkspace(self.allocator, self.io, ws_root, name);
    }

    // ── Auth helpers ─────────────────────────────────────────────────────────

    /// Authorize a request for a specific workspace.
    /// Checks the workspace's own token store first, then platform tokens.
    pub fn authorizeForWorkspace(
        self: *WorkspaceHub,
        ws: *workspace_mod.Workspace,
        workspace_id: []const u8,
        head_buffer: []const u8,
        method: std.http.Method,
        path: []const u8,
    ) bool {
        // Workspace-level auth (own tokens + admin token in .synapse/token).
        if (ws.authorize(head_buffer, method, path)) return true;

        // Platform-level token check.
        const need = auth_mod.Auth.requiredScope(method, path) orelse return true;
        const presented = auth_mod.Auth.extractPresentedToken(head_buffer) orelse return false;
        return self.platform.authorizeWorkspaceToken(presented, workspace_id, need);
    }

    /// Returns true if the presented token is the platform admin token.
    pub fn isAdminRequest(self: *WorkspaceHub, head_buffer: []const u8) bool {
        const tok = auth_mod.Auth.extractPresentedToken(head_buffer) orelse return false;
        return self.platform.isAdminToken(tok);
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
    };
    defer hub.deinit();

    const ws = try hub.get("nonexistent_ws");
    try std.testing.expect(ws == null);
}
