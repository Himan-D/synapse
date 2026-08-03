const std = @import("std");
const Allocator = std.mem.Allocator;
const workspace_mod = @import("../core/workspace.zig");
const version_mod = @import("../core/version.zig");

/// Handle a thin MCP JSON-RPC body. Returns owned JSON response bytes.
pub fn handle(allocator: Allocator, ws: *workspace_mod.Workspace, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return try rpcError(allocator, null, -32700, "parse error");
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return try rpcError(allocator, null, -32600, "invalid request"),
    };

    const id_v = obj.get("id");
    const method = if (obj.get("method")) |m| m.string else {
        return try rpcError(allocator, id_v, -32600, "missing method");
    };

    if (std.mem.eql(u8, method, "initialize")) {
        var info_buf: [256]u8 = undefined;
        const info = try std.fmt.bufPrint(&info_buf,
            \\{{"protocolVersion":"2024-11-05","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"{s}","version":"{s}"}}}}
        , .{ version_mod.product, version_mod.version });
        return try rpcResult(allocator, id_v, info);
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return try rpcResult(allocator, id_v,
            \\{"tools":[{"name":"synapse.ingest","description":"Ingest NDJSON events into a datasource","inputSchema":{"type":"object","properties":{"datasource":{"type":"string"},"events":{"type":"array"}},"required":["datasource","events"]}},{"name":"synapse.remember","description":"Store a Mind claim with confidence","inputSchema":{"type":"object","properties":{"run_id":{"type":"string"},"agent_id":{"type":"string"},"text":{"type":"string"},"confidence":{"type":"number"}},"required":["run_id","text"]}},{"name":"synapse.recall","description":"Token-budgeted context pack for a run","inputSchema":{"type":"object","properties":{"run_id":{"type":"string"},"query":{"type":"string"}},"required":["run_id"]}},{"name":"synapse.plan","description":"Plan a goal into a tool/task DAG","inputSchema":{"type":"object","properties":{"goal":{"type":"string"},"run_id":{"type":"string"}},"required":["goal"]}},{"name":"synapse.route","description":"Route a query to the best tool/skill","inputSchema":{"type":"object","properties":{"query":{"type":"string"},"run_id":{"type":"string"}},"required":["query"]}},{"name":"synapse.impact","description":"Blast radius from errors/tools","inputSchema":{"type":"object","properties":{"run_id":{"type":"string"},"node_id":{"type":"string"}},"required":["run_id"]}},{"name":"synapse.metrics","description":"Tool failure rate metrics","inputSchema":{"type":"object","properties":{"run_id":{"type":"string"}}}},{"name":"synapse.dispute","description":"Find contradictory Mind claims","inputSchema":{"type":"object","properties":{"run_id":{"type":"string"}}}},{"name":"synapse.embed","description":"Hybrid embed recall over Mind claims","inputSchema":{"type":"object","properties":{"run_id":{"type":"string"},"query":{"type":"string"}},"required":["run_id","query"]}},{"name":"synapse.graph","description":"Inspect World/Work/Mind graph","inputSchema":{"type":"object","properties":{"run_id":{"type":"string"}}}}]}
        );
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const params = obj.get("params") orelse return try rpcError(allocator, id_v, -32602, "missing params");
        const name = params.object.get("name").?.string;
        const args = params.object.get("arguments") orelse {
            return try rpcError(allocator, id_v, -32602, "missing arguments");
        };
        const result_json = callTool(allocator, ws, name, args) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "tool error: {s}", .{@errorName(err)});
            return try rpcError(allocator, id_v, -32000, msg);
        };
        defer allocator.free(result_json);

        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try aw.writer.print(
            \\{{"content":[{{"type":"text","text":{f}}}],"isError":false}}
        ,
            .{std.json.fmt(result_json, .{})},
        );
        const wrapped = try aw.toOwnedSlice();
        defer allocator.free(wrapped);
        return try rpcResult(allocator, id_v, wrapped);
    }

    return try rpcError(allocator, id_v, -32601, "method not found");
}

fn callTool(allocator: Allocator, ws: *workspace_mod.Workspace, name: []const u8, args: std.json.Value) ![]u8 {
    if (std.mem.eql(u8, name, "synapse.ingest")) {
        const ds = args.object.get("datasource").?.string;
        const events = args.object.get("events").?.array;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        for (events.items) |ev| {
            try std.json.Stringify.value(ev, .{}, &aw.writer);
            try aw.writer.writeAll("\n");
        }
        const n = try ws.store.ingestNdjson(ds, aw.written());
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.print("{{\"ingested\":{d}}}", .{n});
        return try out.toOwnedSlice();
    }

    if (std.mem.eql(u8, name, "synapse.remember")) {
        const run_id = args.object.get("run_id").?.string;
        const agent_id = if (args.object.get("agent_id")) |a| a.string else "agent";
        const text = args.object.get("text").?.string;
        const confidence: f32 = if (args.object.get("confidence")) |c| switch (c) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => 0.8,
        } else 0.8;
        return try ws.remember(run_id, agent_id, text, confidence);
    }

    if (std.mem.eql(u8, name, "synapse.recall")) {
        return try runNamed(allocator, ws, "recall_context", args, &.{ "run_id", "query" });
    }
    if (std.mem.eql(u8, name, "synapse.plan")) {
        return try runNamed(allocator, ws, "plan_goal", args, &.{ "goal", "run_id", "query" });
    }
    if (std.mem.eql(u8, name, "synapse.route")) {
        return try runNamed(allocator, ws, "route_query", args, &.{ "query", "run_id" });
    }
    if (std.mem.eql(u8, name, "synapse.impact")) {
        return try runNamed(allocator, ws, "blast_radius", args, &.{ "run_id", "node_id" });
    }
    if (std.mem.eql(u8, name, "synapse.metrics")) {
        return try runNamed(allocator, ws, "tool_failure_rate", args, &.{"run_id"});
    }
    if (std.mem.eql(u8, name, "synapse.dispute")) {
        return try runNamed(allocator, ws, "find_contradictions", args, &.{"run_id"});
    }
    if (std.mem.eql(u8, name, "synapse.embed")) {
        return try runNamed(allocator, ws, "embed_recall", args, &.{ "run_id", "query", "limit" });
    }
    if (std.mem.eql(u8, name, "synapse.graph")) {
        const run_id = if (args.object.get("run_id")) |r| r.string else "";
        return try ws.graphJson(allocator, run_id);
    }

    return error.UnknownTool;
}

fn runNamed(
    allocator: Allocator,
    ws: *workspace_mod.Workspace,
    pipe_name: []const u8,
    args: std.json.Value,
    keys: []const []const u8,
) ![]u8 {
    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(allocator);
    for (keys) |k| {
        if (args.object.get(k)) |v| {
            try params.put(allocator, k, v.string);
        }
    }
    const result = try ws.runPipe(pipe_name, params);
    return result.json;
}

fn rpcResult(allocator: Allocator, id_v: ?std.json.Value, result_json: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"result\":");
    try aw.writer.writeAll(result_json);
    try aw.writer.writeAll(",\"id\":");
    try writeId(&aw.writer, id_v);
    try aw.writer.writeAll("}");
    return try aw.toOwnedSlice();
}

fn rpcError(allocator: Allocator, id_v: ?std.json.Value, code: i64, message: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print(
        \\{{"jsonrpc":"2.0","error":{{"code":{d},"message":{f}}},"id":
    ,
        .{ code, std.json.fmt(message, .{}) },
    );
    try writeId(&aw.writer, id_v);
    try aw.writer.writeAll("}");
    return try aw.toOwnedSlice();
}

fn writeId(w: *std.Io.Writer, id_v: ?std.json.Value) !void {
    if (id_v) |v| {
        try std.json.Stringify.value(v, .{}, w);
    } else {
        try w.writeAll("null");
    }
}
