const std = @import("std");
const Allocator = std.mem.Allocator;
const workspace_mod = @import("../core/workspace.zig");

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
        return try rpcResult(allocator, id_v,
            \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"synapse","version":"0.1.0"}}
        );
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return try rpcResult(allocator, id_v,
            \\{"tools":[{"name":"synapse.ingest","description":"Ingest NDJSON events into a datasource","inputSchema":{"type":"object","properties":{"datasource":{"type":"string"},"events":{"type":"array"}},"required":["datasource","events"]}},{"name":"synapse.recall","description":"Token-budgeted context pack for a run","inputSchema":{"type":"object","properties":{"run_id":{"type":"string"},"query":{"type":"string"},"budget_tokens":{"type":"number"}},"required":["run_id"]}},{"name":"synapse.metrics","description":"Tool failure rate metrics","inputSchema":{"type":"object","properties":{"run_id":{"type":"string"}}}}]}
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

    if (std.mem.eql(u8, name, "synapse.recall")) {
        var params: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer params.deinit(allocator);
        const run_id = args.object.get("run_id").?.string;
        try params.put(allocator, "run_id", run_id);
        if (args.object.get("query")) |q| try params.put(allocator, "query", q.string);
        const result = try ws.runPipe("recall_context", params);
        return result.json;
    }

    if (std.mem.eql(u8, name, "synapse.metrics")) {
        var params: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer params.deinit(allocator);
        if (args.object.get("run_id")) |r| try params.put(allocator, "run_id", r.string);
        const result = try ws.runPipe("tool_failure_rate", params);
        return result.json;
    }

    return error.UnknownTool;
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
