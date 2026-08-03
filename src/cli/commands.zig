const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const workspace_mod = @import("../core/workspace.zig");
const hub_mod = @import("../core/workspace_hub.zig");
const platform_mod = @import("../core/platform.zig");
const http_mod = @import("../server/http.zig");
const validate_mod = @import("../core/validate.zig");
const mcp_mod = @import("../server/mcp.zig");

pub fn run(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len < 2) {
        try printHelp();
        return;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printHelp();
        return;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        const root = if (args.len >= 3) args[2] else ".";
        const name = if (args.len >= 4) args[3] else "synapse-workspace";
        try workspace_mod.initWorkspace(allocator, io, root, name);
        std.log.info("initialized workspace at {s}", .{root});
        return;
    }
    if (std.mem.eql(u8, cmd, "build")) {
        const root = flagOr(args, "--root", ".");
        var report = try validate_mod.buildWorkspace(allocator, io, root);
        defer report.deinit();
        try printStdoutLine(io, report.json);
        if (!report.ok) return error.BuildFailed;
        return;
    }
    if (std.mem.eql(u8, cmd, "workspace")) {
        try runWorkspaceCmd(allocator, io, args);
        return;
    }
    if (std.mem.eql(u8, cmd, "endpoint") or std.mem.eql(u8, cmd, "endpoints")) {
        const root = flagOr(args, "--root", ".");
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        const json = try ws.listEndpointsJson(allocator);
        defer allocator.free(json);
        try printStdoutLine(io, json);
        return;
    }
    if (std.mem.eql(u8, cmd, "token")) {
        try runToken(allocator, io, args);
        return;
    }
    if (std.mem.eql(u8, cmd, "branch")) {
        if (args.len < 4) return error.Usage;
        const sub = args[2];
        const name = args[3];
        const root = flagOr(args, "--root", ".");
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        if (std.mem.eql(u8, sub, "create")) {
            const json = try ws.createBranch(name);
            defer allocator.free(json);
            try printStdoutLine(io, json);
            return;
        }
        return error.Usage;
    }
    if (std.mem.eql(u8, cmd, "graph")) {
        const root = flagOr(args, "--root", ".");
        const run_id = flagOr(args, "--run-id", "run_demo");
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        const json = try ws.graphJson(allocator, run_id);
        defer allocator.free(json);
        try printStdoutLine(io, json);
        return;
    }
    if (std.mem.eql(u8, cmd, "checkpoint")) {
        const root = flagOr(args, "--root", ".");
        const name = flagOr(args, "--name", "latest");
        const ds = flagOr(args, "--datasource", "harness_events");
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        const json = try ws.checkpoint(name, ds);
        defer allocator.free(json);
        try printStdoutLine(io, json);
        return;
    }
    if (std.mem.eql(u8, cmd, "workflow")) {
        if (args.len < 3) return error.Usage;
        const sub = args[2];
        const root = flagOr(args, "--root", ".");
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        if (std.mem.eql(u8, sub, "list")) {
            const json = try ws.workflowList();
            defer allocator.free(json);
            try printStdoutLine(io, json);
            return;
        }
        if (std.mem.eql(u8, sub, "show")) {
            if (args.len < 4) return error.Usage;
            const json = try ws.workflowShow(args[3]);
            defer allocator.free(json);
            try printStdoutLine(io, json);
            return;
        }
        if (std.mem.eql(u8, sub, "start")) {
            if (args.len < 4) return error.Usage;
            const input = flagOr(args, "--input", "{}");
            const rid = flagOr(args, "--run-id", "");
            const json = try ws.workflowStart(args[3], input, if (rid.len > 0) rid else null);
            defer allocator.free(json);
            try printStdoutLine(io, json);
            return;
        }
        if (std.mem.eql(u8, sub, "status")) {
            if (args.len < 4) return error.Usage;
            const json = try ws.workflowStatus(args[3]);
            defer allocator.free(json);
            try printStdoutLine(io, json);
            return;
        }
        if (std.mem.eql(u8, sub, "runs")) {
            const json = try ws.workflowListRuns();
            defer allocator.free(json);
            try printStdoutLine(io, json);
            return;
        }
        if (std.mem.eql(u8, sub, "signal")) {
            if (args.len < 4) return error.Usage;
            const typ = flagOr(args, "--type", "");
            if (typ.len == 0) return error.Usage;
            const payload = flagOr(args, "--payload", "{}");
            const json = try ws.workflowSignal(args[3], typ, payload);
            defer allocator.free(json);
            try printStdoutLine(io, json);
            return;
        }
        if (std.mem.eql(u8, sub, "cancel")) {
            if (args.len < 4) return error.Usage;
            const json = try ws.workflowCancel(args[3]);
            defer allocator.free(json);
            try printStdoutLine(io, json);
            return;
        }
        if (std.mem.eql(u8, sub, "tick")) {
            const rid = flagOr(args, "--run-id", "");
            const json = if (rid.len > 0) try ws.workflowTickRun(rid) else try ws.workflowTick();
            defer allocator.free(json);
            try printStdoutLine(io, json);
            return;
        }
        return error.Usage;
    }
    if (std.mem.eql(u8, cmd, "deploy")) {
        const root = flagOr(args, "--root", ".");
        var report = try validate_mod.buildWorkspace(allocator, io, root);
        defer report.deinit();
        {
            var daw: std.Io.Writer.Allocating = .init(allocator);
            defer daw.deinit();
            try daw.writer.print("{{\"deploy\":\"local-validate\",\"report\":{s}}}", .{report.json});
            try printStdoutLine(io, daw.written());
        }
        if (!report.ok) return error.BuildFailed;
        return;
    }
    if (std.mem.eql(u8, cmd, "mcp")) {
        const root = flagOr(args, "--root", ".");
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        try runMcpStdio(allocator, io, &ws);
        return;
    }
    if (std.mem.eql(u8, cmd, "dev")) {
        const root = flagOr(args, "--root", ".");
        const port_s = flagOr(args, "--port", "8787");
        const port = try std.fmt.parseInt(u16, port_s, 10);
        const host_flag = flagOr(args, "--host", "");
        const host: []const u8 = blk: {
            if (host_flag.len > 0) break :blk host_flag;
            if (std.c.getenv("SYNAPSE_HOST")) |v| break :blk std.mem.span(v);
            break :blk "127.0.0.1";
        };
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        try http_mod.serve(allocator, io, &ws, .{ .host = host, .port = port });
        return;
    }
    // ── Multi-workspace cloud serve ───────────────────────────────────────────
    if (std.mem.eql(u8, cmd, "cloud")) {
        try runCloud(allocator, io, args);
        return;
    }
    // ── Platform management ───────────────────────────────────────────────────
    if (std.mem.eql(u8, cmd, "platform")) {
        try runPlatform(allocator, io, args);
        return;
    }
    if (std.mem.eql(u8, cmd, "org")) {
        try runOrg(allocator, io, args);
        return;
    }
    if (std.mem.eql(u8, cmd, "ingest")) {
        if (args.len < 4) return error.Usage;
        const ds = args[2];
        const file = args[3];
        const root = flagOr(args, "--root", ".");
        const replace = hasFlag(args, "--replace");
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        const body = try Io.Dir.cwd().readFileAlloc(io, file, allocator, .unlimited);
        defer allocator.free(body);
        const n = try ws.store.ingestNdjsonOpts(ds, body, replace);
        ws.runMaterializedPipes() catch {};
        ws.logOp("ingest", ds, "cli");
        std.log.info("ingested {d} events into {s} (replace={any})", .{ n, ds, replace });
        return;
    }
    if (std.mem.eql(u8, cmd, "remember")) {
        if (args.len < 3) return error.Usage;
        const text = args[2];
        const root = flagOr(args, "--root", ".");
        const run_id = flagOr(args, "--run-id", "run_demo");
        const agent_id = flagOr(args, "--agent", "agent");
        const conf_s = flagOr(args, "--confidence", "0.9");
        const confidence = try std.fmt.parseFloat(f32, conf_s);
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        const json = try ws.remember(run_id, agent_id, text, confidence);
        defer allocator.free(json);
        try printStdoutLine(io, json);
        return;
    }
    if (std.mem.eql(u8, cmd, "test")) {
        const root = flagOr(args, "--root", ".");
        try runWorkspaceTests(allocator, io, root);
        return;
    }
    if (std.mem.eql(u8, cmd, "pipe")) {
        if (args.len < 3) return error.Usage;
        const sub = args[2];
        if (!std.mem.eql(u8, sub, "run")) return error.Usage;
        if (args.len < 4) return error.Usage;
        const name = args[3];
        const root = flagOr(args, "--root", ".");
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        var params: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer params.deinit(allocator);
        for (args[4..]) |a| {
            if (std.mem.startsWith(u8, a, "--")) continue;
            const eq = std.mem.indexOfScalar(u8, a, '=') orelse continue;
            try params.put(allocator, a[0..eq], a[eq + 1 ..]);
        }
        if (flagOr(args, "--run-id", "").len > 0) {
            try params.put(allocator, "run_id", flagOr(args, "--run-id", ""));
        }
        var result = try ws.runPipe(name, params);
        defer result.deinit();
        try printStdoutLine(io, result.json);
        return;
    }

    std.log.err("unknown command: {s}", .{cmd});
    try printHelp();
    return error.Usage;
}

// ── Workspace command (show pipes or create multi-workspace) ──────────────────

fn runWorkspaceCmd(allocator: Allocator, io: Io, args: []const []const u8) !void {
    // Sub-commands for multi-workspace platform.
    if (args.len >= 3 and std.mem.eql(u8, args[2], "create")) {
        // synapse workspace create <name> --org <org_id> --data-root <dir>
        if (args.len < 4) return error.Usage;
        const name = args[3];
        const org_id = flagOr(args, "--org", "");
        if (org_id.len == 0) {
            std.log.err("--org <org_id> required for workspace create", .{});
            return error.Usage;
        }
        const data_root = dataRootFlag(args, io);
        var store = try platform_mod.PlatformStore.init(allocator, io, data_root);
        defer store.deinit();
        const json = store.createWorkspace(org_id, name) catch |err| switch (err) {
            error.OrgNotFound => {
                std.log.err("org '{s}' not found in platform store", .{org_id});
                return error.OrgNotFound;
            },
            error.WorkspaceAlreadyExists => {
                std.log.err("workspace already exists", .{});
                return error.WorkspaceAlreadyExists;
            },
            else => |e| return e,
        };
        defer allocator.free(json);

        // Scaffold the workspace directory.
        var ws_parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer ws_parsed.deinit();
        const ws_id = ws_parsed.value.object.get("workspace_id").?.string;
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const ws_root = try std.fmt.bufPrint(&path_buf, "{s}/workspaces/{s}", .{ data_root, ws_id });
        workspace_mod.initWorkspace(allocator, io, ws_root, name) catch |err| {
            std.log.warn("workspace scaffold failed: {s}", .{@errorName(err)});
        };

        try printStdoutLine(io, json);
        return;
    }

    // Default: list pipes for a single-workspace root.
    const root = flagOr(args, "--root", ".");
    var ws = try workspace_mod.Workspace.load(allocator, io, root);
    defer ws.deinit();
    const json = try ws.listPipesJson(allocator);
    defer allocator.free(json);
    try printStdoutLine(io, json);
}

// ── Token command ─────────────────────────────────────────────────────────────

fn runToken(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len < 3) return error.Usage;
    const sub = args[2];

    // If --workspace flag present → platform-level token.
    const ws_flag = flagOr(args, "--workspace", "");
    if (ws_flag.len > 0) {
        return runPlatformToken(allocator, io, args, sub, ws_flag);
    }

    // Legacy workspace-level token (in .synapse/tokens.json).
    const root = flagOr(args, "--root", ".");
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const token_path = try std.fmt.bufPrint(&path_buf, "{s}/.synapse/token", .{root});
    const tokens_path = try std.fmt.allocPrint(allocator, "{s}/.synapse/tokens.json", .{root});
    defer allocator.free(tokens_path);

    if (std.mem.eql(u8, sub, "show") or std.mem.eql(u8, sub, "list")) {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.writeAll("{");
        if (Io.Dir.cwd().readFileAlloc(io, token_path, allocator, .unlimited)) |tok| {
            defer allocator.free(tok);
            try aw.writer.print("\"admin_token\":{f}", .{std.json.fmt(std.mem.trim(u8, tok, " \t\r\n"), .{})});
        } else |_| {
            try aw.writer.writeAll("\"admin_token\":null");
        }
        try aw.writer.writeAll(",\"tokens\":");
        if (Io.Dir.cwd().readFileAlloc(io, tokens_path, allocator, .unlimited)) |bytes| {
            defer allocator.free(bytes);
            try aw.writer.writeAll(bytes);
        } else |_| {
            try aw.writer.writeAll("[]");
        }
        try aw.writer.writeAll("}\n");
        try printStdoutLine(io, std.mem.trimEnd(u8, aw.written(), "\n"));
        return;
    }

    if (std.mem.eql(u8, sub, "create")) {
        const name = if (args.len >= 4) args[3] else "api";
        const scope = flagOr(args, "--scope", "PIPES:READ");
        var rand_buf: [16]u8 = undefined;
        const seed: u64 = @intCast(@max(Io.Clock.real.now(io).toSeconds(), 0));
        var prng = std.Random.DefaultPrng.init(seed ^ @as(u64, @intCast(name.len * 2654435761)));
        prng.random().bytes(&rand_buf);
        const hex = std.fmt.bytesToHex(rand_buf, .lower);
        const token = try std.fmt.allocPrint(allocator, "p.{s}", .{&hex});
        defer allocator.free(token);

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.writeAll("[");
        var first = true;
        if (Io.Dir.cwd().readFileAlloc(io, tokens_path, allocator, .unlimited)) |bytes| {
            defer allocator.free(bytes);
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch null;
            if (parsed) |*p| {
                defer p.deinit();
                if (p.value == .array) {
                    for (p.value.array.items) |item| {
                        if (!first) try aw.writer.writeAll(",");
                        first = false;
                        try std.json.Stringify.value(item, .{}, &aw.writer);
                    }
                }
            }
        } else |_| {}
        if (!first) try aw.writer.writeAll(",");
        try aw.writer.print(
            \\{{"name":{f},"token":{f},"scopes":[{f}]}}
        ,
            .{ std.json.fmt(name, .{}), std.json.fmt(token, .{}), std.json.fmt(scope, .{}) },
        );
        try aw.writer.writeAll("]");

        const syn_dir = try std.fmt.bufPrint(&path_buf, "{s}/.synapse", .{root});
        try Io.Dir.cwd().createDirPath(io, syn_dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = tokens_path, .data = aw.written() });
        {
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            try out.writer.print("{{\"created\":true,\"name\":{f},\"token\":{f},\"scopes\":[{f}]}}", .{
                std.json.fmt(name, .{}),
                std.json.fmt(token, .{}),
                std.json.fmt(scope, .{}),
            });
            try printStdoutLine(io, out.written());
        }
        return;
    }

    return error.Usage;
}

fn runPlatformToken(allocator: Allocator, io: Io, args: []const []const u8, sub: []const u8, workspace_id: []const u8) !void {
    const data_root = dataRootFlag(args, io);
    var store = try platform_mod.PlatformStore.init(allocator, io, data_root);
    defer store.deinit();

    if (std.mem.eql(u8, sub, "create")) {
        const name = if (args.len >= 4) args[3] else "api";
        const scope = flagOr(args, "--scope", "ADMIN");
        const json = store.mintToken(workspace_id, name, scope) catch |err| switch (err) {
            error.WorkspaceNotFound => {
                std.log.err("workspace '{s}' not found in platform store", .{workspace_id});
                return error.WorkspaceNotFound;
            },
            else => |e| return e,
        };
        defer allocator.free(json);
        try printStdoutLine(io, json);
        return;
    }

    if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "show")) {
        // List platform tokens for this workspace.
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.writeAll("{\"tokens\":[");
        var first = true;
        for (store.tokens.items) |t| {
            if (!std.mem.eql(u8, t.workspace_id, workspace_id)) continue;
            if (!first) try aw.writer.writeAll(",");
            first = false;
            try aw.writer.print("{{\"name\":{f},\"token\":{f},\"workspace_id\":{f}}}", .{
                std.json.fmt(t.name, .{}),
                std.json.fmt(t.token, .{}),
                std.json.fmt(t.workspace_id, .{}),
            });
        }
        try aw.writer.writeAll("]}");
        try printStdoutLine(io, aw.written());
        return;
    }

    return error.Usage;
}

// ── Platform command ──────────────────────────────────────────────────────────

fn runPlatform(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print("Usage: synapse platform <init|orgs|workspaces>\n", .{});
        return error.Usage;
    }
    const sub = args[2];

    if (std.mem.eql(u8, sub, "init")) {
        const data_root = dataRootFlag(args, io);
        const json = try platform_mod.PlatformStore.bootstrap(allocator, io, data_root);
        defer allocator.free(json);
        try printStdoutLine(io, json);
        return;
    }

    if (std.mem.eql(u8, sub, "orgs")) {
        const data_root = dataRootFlag(args, io);
        var store = try platform_mod.PlatformStore.init(allocator, io, data_root);
        defer store.deinit();
        const json = try store.listOrgsJson(allocator);
        defer allocator.free(json);
        try printStdoutLine(io, json);
        return;
    }

    if (std.mem.eql(u8, sub, "workspaces")) {
        const data_root = dataRootFlag(args, io);
        var store = try platform_mod.PlatformStore.init(allocator, io, data_root);
        defer store.deinit();
        const json = try store.listWorkspacesJson(allocator);
        defer allocator.free(json);
        try printStdoutLine(io, json);
        return;
    }

    std.log.err("unknown platform sub-command: {s}", .{sub});
    return error.Usage;
}

// ── Org command ───────────────────────────────────────────────────────────────

fn runOrg(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print("Usage: synapse org create <name> --data-root <dir>\n", .{});
        return error.Usage;
    }
    const sub = args[2];

    if (std.mem.eql(u8, sub, "create")) {
        if (args.len < 4) return error.Usage;
        const name = args[3];
        const data_root = dataRootFlag(args, io);
        var store = try platform_mod.PlatformStore.init(allocator, io, data_root);
        defer store.deinit();
        const json = store.createOrg(name) catch |err| switch (err) {
            error.OrgAlreadyExists => {
                std.log.err("org already exists", .{});
                return error.OrgAlreadyExists;
            },
            else => |e| return e,
        };
        defer allocator.free(json);
        try printStdoutLine(io, json);
        return;
    }

    if (std.mem.eql(u8, sub, "list")) {
        const data_root = dataRootFlag(args, io);
        var store = try platform_mod.PlatformStore.init(allocator, io, data_root);
        defer store.deinit();
        const json = try store.listOrgsJson(allocator);
        defer allocator.free(json);
        try printStdoutLine(io, json);
        return;
    }

    std.log.err("unknown org sub-command: {s}", .{sub});
    return error.Usage;
}

// ── Cloud serve command ───────────────────────────────────────────────────────

fn runCloud(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len < 3) {
        std.debug.print("Usage: synapse cloud serve --data-root <dir> [--host 0.0.0.0] [--port 8787]\n", .{});
        return error.Usage;
    }
    const sub = args[2];
    if (!std.mem.eql(u8, sub, "serve")) {
        std.log.err("unknown cloud sub-command: {s}", .{sub});
        return error.Usage;
    }

    const data_root = dataRootFlag(args, io);
    const port_s = flagOr(args, "--port", portEnvOr("8787"));
    const port = try std.fmt.parseInt(u16, port_s, 10);
    const host_flag = flagOr(args, "--host", "");
    const host: []const u8 = blk: {
        if (host_flag.len > 0) break :blk host_flag;
        if (std.c.getenv("SYNAPSE_HOST")) |v| break :blk std.mem.span(v);
        break :blk "0.0.0.0";
    };

    var hub = try hub_mod.WorkspaceHub.init(allocator, io, data_root);
    defer hub.deinit();

    std.log.info("synapse cloud serve data_root={s} workspaces={d}", .{
        data_root,
        hub.platform.workspaces.items.len,
    });

    try http_mod.serveCloud(allocator, io, &hub, .{ .host = host, .port = port });
}

// ── MCP stdio ────────────────────────────────────────────────────────────────

fn runMcpStdio(allocator: Allocator, io: Io, ws: *workspace_mod.Workspace) !void {
    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdout_buf: [64 * 1024]u8 = undefined;
    var in_reader = Io.File.stdin().reader(io, &stdin_buf);
    var out_writer = Io.File.stdout().writer(io, &stdout_buf);
    const reader = &in_reader.interface;

    while (true) {
        const first = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (first == '{') {
            const rest = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try aw.writer.writeByte('{');
            try aw.writer.writeAll(std.mem.trimEnd(u8, rest, " \t\r"));
            const resp = try mcp_mod.handle(allocator, ws, aw.written());
            defer allocator.free(resp);
            try out_writer.interface.writeAll(resp);
            try out_writer.interface.writeAll("\n");
            try out_writer.interface.flush();
            continue;
        }

        var header_aw: std.Io.Writer.Allocating = .init(allocator);
        defer header_aw.deinit();
        try header_aw.writer.writeByte(first);
        while (true) {
            const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return e,
            };
            try header_aw.writer.writeAll(line);
            try header_aw.writer.writeAll("\n");
            if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;
        }
        const headers = header_aw.written();
        var content_len: ?usize = null;
        var hit = std.mem.splitScalar(u8, headers, '\n');
        while (hit.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
                const v = std.mem.trim(u8, line["Content-Length:".len..], " \t");
                content_len = std.fmt.parseInt(usize, v, 10) catch null;
            }
        }
        const n = content_len orelse continue;
        const body = try allocator.alloc(u8, n);
        defer allocator.free(body);
        try reader.readSliceAll(body);
        const resp = try mcp_mod.handle(allocator, ws, body);
        defer allocator.free(resp);
        try out_writer.interface.print("Content-Length: {d}\r\n\r\n", .{resp.len});
        try out_writer.interface.writeAll(resp);
        try out_writer.interface.flush();
    }
}

// ── Workspace tests ───────────────────────────────────────────────────────────

fn runWorkspaceTests(allocator: Allocator, io: Io, root: []const u8) !void {
    var report = try validate_mod.buildWorkspace(allocator, io, root);
    defer report.deinit();
    if (!report.ok) {
        std.log.err("build failed: {s}", .{report.json});
        return error.BuildFailed;
    }
    std.log.info("build OK", .{});

    var ws = try workspace_mod.Workspace.load(allocator, io, root);
    defer ws.deinit();

    if (ws.store.events("harness_events").len == 0) {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const sample_path = try std.fmt.bufPrint(&buf, "{s}/sample_events.ndjson", .{root});
        if (Io.Dir.cwd().readFileAlloc(io, sample_path, allocator, .unlimited)) |body| {
            defer allocator.free(body);
            _ = try ws.store.ingestNdjson("harness_events", body);
            ws.runMaterializedPipes() catch {};
        } else |_| {}
    }

    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(allocator);
    try params.put(allocator, "run_id", "run_demo");
    try params.put(allocator, "query", "risk");
    try params.put(allocator, "goal", "fix risk bug and run tests");

    var recall = try ws.runPipe("recall_context", params);
    defer recall.deinit();
    if (std.mem.indexOf(u8, recall.json, "citations") == null) return error.RecallFailed;
    std.log.info("recall_context OK ({d} bytes)", .{recall.json.len});

    var metrics = try ws.runPipe("tool_failure_rate", params);
    defer metrics.deinit();
    if (std.mem.indexOf(u8, metrics.json, "failure_rate") == null) return error.MetricsFailed;
    std.log.info("tool_failure_rate OK ({d} bytes)", .{metrics.json.len});

    var blast = try ws.runPipe("blast_radius", params);
    defer blast.deinit();
    if (std.mem.indexOf(u8, blast.json, "impacted") == null) return error.BlastFailed;
    std.log.info("blast_radius OK ({d} bytes)", .{blast.json.len});

    if (ws.getPipe("plan_goal")) |_| {
        var plan = try ws.runPipe("plan_goal", params);
        defer plan.deinit();
        if (std.mem.indexOf(u8, plan.json, "steps") == null) return error.PlanFailed;
        std.log.info("plan_goal OK ({d} bytes)", .{plan.json.len});
    }

    if (ws.getPipe("route_query")) |_| {
        var route = try ws.runPipe("route_query", params);
        defer route.deinit();
        if (std.mem.indexOf(u8, route.json, "choice") == null) return error.RouteFailed;
        std.log.info("route_query OK ({d} bytes)", .{route.json.len});
    }

    if (ws.getPipe("find_contradictions")) |_| {
        var dispute = try ws.runPipe("find_contradictions", params);
        defer dispute.deinit();
        if (std.mem.indexOf(u8, dispute.json, "disputes") == null) return error.DisputeFailed;
        std.log.info("find_contradictions OK ({d} bytes)", .{dispute.json.len});
    }

    if (ws.getPipe("copy_tool_calls")) |_| {
        var copy = try ws.runPipe("copy_tool_calls", params);
        defer copy.deinit();
        if (std.mem.indexOf(u8, copy.json, "copied") == null) return error.CopyFailed;
        std.log.info("copy_tool_calls OK ({d} bytes)", .{copy.json.len});
    }

    if (ws.getPipe("sink_metrics")) |_| {
        var sink = try ws.runPipe("sink_metrics", params);
        defer sink.deinit();
        if (std.mem.indexOf(u8, sink.json, "sunk") == null) return error.SinkFailed;
        std.log.info("sink_metrics OK ({d} bytes)", .{sink.json.len});
    }

    if (ws.getPipe("embed_recall")) |_| {
        var emb = try ws.runPipe("embed_recall", params);
        defer emb.deinit();
        if (std.mem.indexOf(u8, emb.json, "hits") == null) return error.EmbedFailed;
        std.log.info("embed_recall OK ({d} bytes)", .{emb.json.len});
    }

    if (ws.getPipe("consolidate_claims")) |_| {
        var cons = try ws.runPipe("consolidate_claims", params);
        defer cons.deinit();
        if (std.mem.indexOf(u8, cons.json, "clusters") == null) return error.ConsolidateFailed;
        std.log.info("consolidate_claims OK ({d} bytes)", .{cons.json.len});
    }

    if (ws.getPipe("llm_token_burn")) |_| {
        var llm = try ws.runPipe("llm_token_burn", params);
        defer llm.deinit();
        if (std.mem.indexOf(u8, llm.json, "sum") == null and std.mem.indexOf(u8, llm.json, "groups") == null)
            return error.LlmMetricsFailed;
        std.log.info("llm_token_burn OK ({d} bytes)", .{llm.json.len});
    }

    const gjson = try ws.graphJson(allocator, "run_demo");
    defer allocator.free(gjson);
    if (std.mem.indexOf(u8, gjson, "nodes") == null) return error.GraphFailed;
    std.log.info("graph OK ({d} bytes)", .{gjson.len});

    std.log.info("all workspace tests passed", .{});
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn printStdoutLine(io: Io, line: []const u8) !void {
    var buf: [64 * 1024]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(line);
    try w.interface.writeAll("\n");
    try w.interface.flush();
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

fn flagOr(args: []const []const u8, flag: []const u8, default: []const u8) []const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag) and i + 1 < args.len) return args[i + 1];
        if (args[i].len > flag.len + 1 and std.mem.startsWith(u8, args[i], flag) and args[i][flag.len] == '=') {
            return args[i][flag.len + 1 ..];
        }
    }
    return default;
}

/// Resolve --data-root flag, then SYNAPSE_DATA_ROOT env var, then ".".
fn dataRootFlag(args: []const []const u8, io: Io) []const u8 {
    _ = io;
    const flag = flagOr(args, "--data-root", "");
    if (flag.len > 0) return flag;
    if (std.c.getenv("SYNAPSE_DATA_ROOT")) |v| return std.mem.span(v);
    return ".";
}

fn portEnvOr(default: []const u8) []const u8 {
    if (std.c.getenv("PORT")) |v| return std.mem.span(v);
    return default;
}

fn printHelp() !void {
    const help =
        \\synapse — Tinybird for AI harnesses
        \\
        \\Single-workspace (dev):
        \\  synapse init [dir] [name]
        \\  synapse build --root <dir>
        \\  synapse workspace --root <dir>
        \\  synapse endpoint --root <dir>
        \\  synapse token show|create [name] --root <dir> [--scope SCOPE]
        \\  synapse branch create <name> --root <dir>
        \\  synapse checkpoint --name <id> --root <dir>
        \\  synapse workflow list|show|start|status|runs|signal|cancel|tick ...
        \\  synapse graph --root <dir> --run-id <id>
        \\  synapse deploy --root <dir>
        \\  synapse mcp --root <dir>
        \\  synapse dev --root <dir> --port <port> [--host 127.0.0.1]
        \\  synapse ingest <datasource> <file.ndjson> --root <dir> [--replace]
        \\  synapse remember "<text>" --root <dir> --run-id <id> [--confidence 0.9]
        \\  synapse pipe run <name> --root <dir> [--run-id <id>] [k=v...]
        \\  synapse test --root <dir>
        \\
        \\Multi-workspace (cloud):
        \\  synapse platform init --data-root <dir>
        \\  synapse org create <name> --data-root <dir>
        \\  synapse workspace create <name> --org <org_id> --data-root <dir>
        \\  synapse token create [name] --workspace <ws_id> --data-root <dir> [--scope SCOPE]
        \\  synapse cloud serve --data-root <dir> [--host 0.0.0.0] [--port 8787]
        \\
        \\Env:
        \\  SYNAPSE_REQUIRE_AUTH=1   enforce scoped Bearer tokens
        \\  SYNAPSE_HOST            bind address (default 127.0.0.1 / 0.0.0.0 in cloud)
        \\  SYNAPSE_RATE_LIMIT=N    token-bucket requests/sec (0=off)
        \\  SYNAPSE_DATA_ROOT       data root for cloud mode
        \\  PORT                    port for cloud mode (Render compatible)
        \\
        \\Playground: open http://127.0.0.1:8787/ while `synapse dev` is running.
        \\See docs/CLOUD.md, docs/PRODUCTION_PLAN.md, docs/openapi.yaml.
        \\
    ;
    std.debug.print("{s}", .{help});
}
