const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const workspace_mod = @import("../core/workspace.zig");
const http_mod = @import("../server/http.zig");

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
        \\synapse — Tinybird for AI harnesses (full product surface)
        \\
        \\Usage:
        \\  synapse init [dir] [name]
        \\  synapse dev --root <dir> --port <port>
        \\  synapse ingest <datasource> <file.ndjson> --root <dir> [--replace]
        \\  synapse remember "<text>" --root <dir> --run-id <id> [--confidence 0.9]
        \\  synapse pipe run <name> --root <dir> [--run-id <id>] [k=v...]
        \\  synapse test --root <dir>
        \\
        \\Env:
        \\  SYNAPSE_REQUIRE_AUTH=1   enforce Bearer token from .synapse/token
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn runWorkspaceTests(allocator: Allocator, io: Io, root: []const u8) !void {
    var ws = try workspace_mod.Workspace.load(allocator, io, root);
    defer ws.deinit();

    if (ws.store.events("harness_events").len == 0) {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const sample_path = try std.fmt.bufPrint(&buf, "{s}/sample_events.ndjson", .{root});
        if (Io.Dir.cwd().readFileAlloc(io, sample_path, allocator, .unlimited)) |body| {
            defer allocator.free(body);
            _ = try ws.store.ingestNdjson("harness_events", body);
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

    std.log.info("all workspace tests passed", .{});
}
