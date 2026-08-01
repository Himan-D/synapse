const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const workspace_mod = @import("../core/workspace.zig");
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
        std.debug.print("{s}\n", .{report.json});
        if (!report.ok) return error.BuildFailed;
        return;
    }
    if (std.mem.eql(u8, cmd, "workspace")) {
        const root = flagOr(args, "--root", ".");
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        const json = try ws.listPipesJson(allocator);
        defer allocator.free(json);
        std.debug.print("{s}\n", .{json});
        return;
    }
    if (std.mem.eql(u8, cmd, "endpoint") or std.mem.eql(u8, cmd, "endpoints")) {
        const root = flagOr(args, "--root", ".");
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        const json = try ws.listEndpointsJson(allocator);
        defer allocator.free(json);
        std.debug.print("{s}\n", .{json});
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
            std.debug.print("{s}\n", .{json});
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
        std.debug.print("{s}\n", .{json});
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
        std.debug.print("{s}\n", .{json});
        return;
    }
    if (std.mem.eql(u8, cmd, "deploy")) {
        // Local-first stub: validate + report (cloud promotion is roadmap).
        const root = flagOr(args, "--root", ".");
        var report = try validate_mod.buildWorkspace(allocator, io, root);
        defer report.deinit();
        std.debug.print("{{\"deploy\":\"local-validate\",\"report\":{s}}}\n", .{report.json});
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
        var ws = try workspace_mod.Workspace.load(allocator, io, root);
        defer ws.deinit();
        try http_mod.serve(allocator, io, &ws, port);
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
        std.debug.print("{s}\n", .{json});
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
        std.debug.print("{s}\n", .{result.json});
        return;
    }

    std.log.err("unknown command: {s}", .{cmd});
    try printHelp();
    return error.Usage;
}

fn runToken(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len < 3) return error.Usage;
    const sub = args[2];
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
        std.debug.print("{s}", .{aw.written()});
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

        // Load existing tokens array or start empty.
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

        // ensure .synapse exists
        const syn_dir = try std.fmt.bufPrint(&path_buf, "{s}/.synapse", .{root});
        try Io.Dir.cwd().createDirPath(io, syn_dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = tokens_path, .data = aw.written() });
        std.debug.print("{{\"created\":true,\"name\":{f},\"token\":{f},\"scopes\":[{f}]}}\n", .{
            std.json.fmt(name, .{}),
            std.json.fmt(token, .{}),
            std.json.fmt(scope, .{}),
        });
        return;
    }

    return error.Usage;
}

fn runMcpStdio(allocator: Allocator, io: Io, ws: *workspace_mod.Workspace) !void {
    // Line-delimited JSON-RPC over stdin/stdout for Cursor / Claude Desktop.
    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdout_buf: [64 * 1024]u8 = undefined;
    var in_reader = Io.File.stdin().reader(io, &stdin_buf);
    var out_writer = Io.File.stdout().writer(io, &stdout_buf);

    while (true) {
        const line = in_reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const resp = try mcp_mod.handle(allocator, ws, trimmed);
        defer allocator.free(resp);
        try out_writer.interface.writeAll(resp);
        try out_writer.interface.writeAll("\n");
        try out_writer.interface.flush();
    }
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

fn printHelp() !void {
    const help =
        \\synapse — Tinybird for AI harnesses
        \\
        \\Usage:
        \\  synapse init [dir] [name]
        \\  synapse build --root <dir>
        \\  synapse workspace --root <dir>
        \\  synapse endpoint --root <dir>
        \\  synapse token show|create [name] --root <dir> [--scope SCOPE]
        \\  synapse branch create <name> --root <dir>
        \\  synapse checkpoint --name <id> --root <dir>
        \\  synapse graph --root <dir> --run-id <id>
        \\  synapse deploy --root <dir>
        \\  synapse mcp --root <dir>
        \\  synapse dev --root <dir> --port <port>
        \\  synapse ingest <datasource> <file.ndjson> --root <dir> [--replace]
        \\  synapse remember "<text>" --root <dir> --run-id <id> [--confidence 0.9]
        \\  synapse pipe run <name> --root <dir> [--run-id <id>] [k=v...]
        \\  synapse test --root <dir>
        \\
        \\Env:
        \\  SYNAPSE_REQUIRE_AUTH=1   enforce scoped Bearer tokens
        \\
        \\Playground: open http://127.0.0.1:8787/ while `synapse dev` is running.
        \\See docs/tinybird-parity.md and PRODUCT.md.
        \\
    ;
    std.debug.print("{s}", .{help});
}

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
