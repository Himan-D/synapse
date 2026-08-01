const std = @import("std");
const Allocator = std.mem.Allocator;
const event_mod = @import("event.zig");
const store_mod = @import("store.zig");
const graph_mod = @import("graph.zig");
const context_pack = @import("context_pack.zig");
const plan_mod = @import("plan.zig");
const route_mod = @import("route.zig");
const belief_mod = @import("belief.zig");

pub const PipeNodeType = enum {
    filter,
    aggregate,
    materialize_graph,
    project,
};

pub const AggregateOp = enum { count, rate };
pub const ProjectOp = enum {
    context_pack,
    blast_radius,
    passthrough,
    plan,
    route,
    contradict,
};

pub const PipeNode = struct {
    type: PipeNodeType,
    datasource: ?[]const u8 = null,
    where: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    layers: std.ArrayList(graph_mod.Layer) = .empty,
    group_by: ?[]const u8 = null,
    aggregate_op: AggregateOp = .count,
    success_field: ?[]const u8 = null,
    project_op: ProjectOp = .passthrough,
    budget_tokens: usize = 4000,
};

pub const Pipe = struct {
    allocator: Allocator,
    name: []const u8,
    nodes: std.ArrayList(PipeNode) = .empty,
    endpoint_path: ?[]const u8 = null,
    endpoint_params: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Pipe) void {
        self.allocator.free(self.name);
        for (self.nodes.items) |*n| {
            if (n.datasource) |ds| self.allocator.free(ds);
            var wit = n.where.iterator();
            while (wit.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                self.allocator.free(e.value_ptr.*);
            }
            n.where.deinit(self.allocator);
            n.layers.deinit(self.allocator);
            if (n.group_by) |g| self.allocator.free(g);
            if (n.success_field) |sf| self.allocator.free(sf);
        }
        self.nodes.deinit(self.allocator);
        if (self.endpoint_path) |p| self.allocator.free(p);
        for (self.endpoint_params.items) |p| self.allocator.free(p);
        self.endpoint_params.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const PipeResult = struct {
    allocator: Allocator,
    json: []u8,

    pub fn deinit(self: *PipeResult) void {
        self.allocator.free(self.json);
        self.* = undefined;
    }
};

pub fn loadPipeFile(allocator: Allocator, io: std.Io, path: []const u8) !Pipe {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    return parsePipe(allocator, bytes);
}

pub fn parsePipe(allocator: Allocator, bytes: []const u8) !Pipe {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const name_v = obj.get("name") orelse return error.MissingField;
    var pipe: Pipe = .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name_v.string),
    };
    errdefer pipe.deinit();

    if (obj.get("endpoint")) |ep_v| {
        const ep = ep_v.object;
        if (ep.get("path")) |p| pipe.endpoint_path = try allocator.dupe(u8, p.string);
        if (ep.get("params")) |params| {
            for (params.array.items) |p| {
                try pipe.endpoint_params.append(allocator, try allocator.dupe(u8, p.string));
            }
        }
    }

    const nodes_v = obj.get("nodes") orelse return error.MissingField;
    for (nodes_v.array.items) |nv| {
        const nobj = nv.object;
        const type_s = nobj.get("type").?.string;
        var node: PipeNode = .{
            .type = std.meta.stringToEnum(PipeNodeType, type_s) orelse return error.InvalidPipeNode,
        };

        if (nobj.get("datasource")) |ds| node.datasource = try allocator.dupe(u8, ds.string);
        if (nobj.get("where")) |where_v| {
            var wit = where_v.object.iterator();
            while (wit.next()) |e| {
                try node.where.put(allocator, try allocator.dupe(u8, e.key_ptr.*), try allocator.dupe(u8, e.value_ptr.string));
            }
        }
        if (nobj.get("layers")) |layers_v| {
            for (layers_v.array.items) |lv| {
                const layer = graph_mod.Layer.fromString(lv.string) orelse return error.InvalidLayer;
                try node.layers.append(allocator, layer);
            }
        }
        if (nobj.get("group_by")) |g| node.group_by = try allocator.dupe(u8, g.string);
        if (nobj.get("op")) |op| {
            if (node.type == .aggregate) {
                node.aggregate_op = std.meta.stringToEnum(AggregateOp, op.string) orelse .count;
            } else if (node.type == .project) {
                node.project_op = std.meta.stringToEnum(ProjectOp, op.string) orelse .passthrough;
            }
        }
        if (nobj.get("success_field")) |sf| node.success_field = try allocator.dupe(u8, sf.string);
        if (nobj.get("budget_tokens")) |bt| node.budget_tokens = @intCast(bt.integer);

        try pipe.nodes.append(allocator, node);
    }
    return pipe;
}

fn substitute(allocator: Allocator, template: []const u8, params: std.StringHashMapUnmanaged([]const u8)) ![]u8 {
    if (std.mem.indexOf(u8, template, "{{") == null) return allocator.dupe(u8, template);
    // {{key}}
    if (std.mem.startsWith(u8, template, "{{") and std.mem.endsWith(u8, template, "}}")) {
        const key = template[2 .. template.len - 2];
        if (params.get(key)) |v| return allocator.dupe(u8, v);
        return allocator.dupe(u8, "");
    }
    return allocator.dupe(u8, template);
}

pub fn execute(
    allocator: Allocator,
    store: *store_mod.Store,
    pipe: *const Pipe,
    params: std.StringHashMapUnmanaged([]const u8),
) !PipeResult {
    var current: ?[]event_mod.Event = null;
    defer if (current) |c| allocator.free(c);

    var graph: ?graph_mod.Graph = null;
    defer if (graph) |*g| g.deinit();

    var last_json: ?[]u8 = null;
    defer if (last_json) |j| allocator.free(j);

    for (pipe.nodes.items) |node| {
        switch (node.type) {
            .filter => {
                var where: std.StringHashMapUnmanaged([]const u8) = .empty;
                defer {
                    var it = where.iterator();
                    while (it.next()) |e| {
                        allocator.free(e.key_ptr.*);
                        allocator.free(e.value_ptr.*);
                    }
                    where.deinit(allocator);
                }
                var wit = node.where.iterator();
                while (wit.next()) |e| {
                    const val = try substitute(allocator, e.value_ptr.*, params);
                    // Skip empty template substitutions so omitted params mean "no filter".
                    if (val.len == 0 and std.mem.indexOf(u8, e.value_ptr.*, "{{") != null) {
                        allocator.free(val);
                        continue;
                    }
                    try where.put(allocator, try allocator.dupe(u8, e.key_ptr.*), val);
                }
                if (current) |c| allocator.free(c);
                current = try store.filterEvents(allocator, node.datasource, where);
            },
            .materialize_graph => {
                const evs = current orelse &.{};
                if (graph) |*g| g.deinit();
                graph = try graph_mod.materialize(allocator, evs, node.layers.items);
            },
            .aggregate => {
                const evs = current orelse &.{};
                const json = try runAggregate(allocator, evs, node);
                if (last_json) |j| allocator.free(j);
                last_json = json;
            },
            .project => {
                switch (node.project_op) {
                    .context_pack => {
                        const g = &(graph orelse return error.GraphRequired);
                        const query = params.get("query") orelse "";
                        const pack = try context_pack.buildPack(allocator, g, query, node.budget_tokens);
                        if (last_json) |j| allocator.free(j);
                        last_json = pack.json; // ownership transferred
                    },
                    .blast_radius => {
                        const g = &(graph orelse return error.GraphRequired);
                        const json = try runBlastRadius(allocator, g, params.get("node_id"));
                        if (last_json) |j| allocator.free(j);
                        last_json = json;
                    },
                    .plan => {
                        const goal = params.get("goal") orelse params.get("query") orelse "investigate";
                        const gptr: ?*const graph_mod.Graph = if (graph) |*g| g else null;
                        const json = try plan_mod.planGoal(allocator, goal, gptr);
                        if (last_json) |j| allocator.free(j);
                        last_json = json;
                    },
                    .route => {
                        const query = params.get("query") orelse params.get("goal") orelse "";
                        const gptr: ?*const graph_mod.Graph = if (graph) |*g| g else null;
                        const json = try route_mod.routeQuery(allocator, query, gptr);
                        if (last_json) |j| allocator.free(j);
                        last_json = json;
                    },
                    .contradict => {
                        const g = &(graph orelse return error.GraphRequired);
                        const json = try belief_mod.findContradictions(allocator, g);
                        if (last_json) |j| allocator.free(j);
                        last_json = json;
                    },
                    .passthrough => {
                        const evs = current orelse &.{};
                        const json = try eventsToJson(allocator, evs);
                        if (last_json) |j| allocator.free(j);
                        last_json = json;
                    },
                }
            },
        }
    }

    const out = last_json orelse try eventsToJson(allocator, current orelse &.{});
    last_json = null;
    return .{ .allocator = allocator, .json = out };
}

fn runAggregate(allocator: Allocator, events: []const event_mod.Event, node: PipeNode) ![]u8 {
    const key_field = node.group_by orelse "type";
    var groups: std.StringArrayHashMapUnmanaged(struct { total: usize, success: usize }) = .empty;
    defer {
        var it = groups.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        groups.deinit(allocator);
    }

    for (events) |ev| {
        const key_owned = blk: {
            if (std.mem.eql(u8, key_field, "type")) break :blk try allocator.dupe(u8, ev.type_raw);
            if (std.mem.eql(u8, key_field, "run_id")) break :blk try allocator.dupe(u8, ev.run_id);
            if (std.mem.eql(u8, key_field, "agent_id")) break :blk try allocator.dupe(u8, ev.agent_id);
            if (std.mem.eql(u8, key_field, "name")) {
                const name = (try event_mod.payloadString(allocator, ev.payload_json, "name")) orelse
                    try allocator.dupe(u8, "unknown");
                break :blk name;
            }
            break :blk try allocator.dupe(u8, "all");
        };
        const gop = try groups.getOrPut(allocator, key_owned);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .total = 0, .success = 0 };
        } else {
            allocator.free(key_owned);
        }
        gop.value_ptr.total += 1;
        const success_field = node.success_field orelse "ok";
        if (event_mod.payloadBool(allocator, ev.payload_json, success_field)) {
            gop.value_ptr.success += 1;
        }
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"groups\":[");
    var first = true;
    var it = groups.iterator();
    while (it.next()) |e| {
        if (!first) try aw.writer.writeAll(",");
        first = false;
        const total = e.value_ptr.total;
        const success = e.value_ptr.success;
        const fail = total - success;
        const rate: f64 = if (total == 0) 0 else @as(f64, @floatFromInt(fail)) / @as(f64, @floatFromInt(total));
        try aw.writer.print(
            \\{{"key":{f},"total":{d},"success":{d},"failure":{d},"failure_rate":{d:.4}}}
        ,
            .{ std.json.fmt(e.key_ptr.*, .{}), total, success, fail, rate },
        );
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

fn runBlastRadius(allocator: Allocator, graph: *const graph_mod.Graph, node_id: ?[]const u8) ![]u8 {
    const seed = node_id orelse blk: {
        // default: first error or first tool_op
        const values = graph.nodes.values();
        for (values) |n| {
            if (std.mem.eql(u8, n.kind, "error")) break :blk n.id;
        }
        for (values) |n| {
            if (std.mem.eql(u8, n.kind, "tool_op")) break :blk n.id;
        }
        break :blk if (values.len > 0) values[0].id else "";
    };

    var impacted: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer impacted.deinit(allocator);
    if (seed.len > 0) try impacted.put(allocator, seed, {});

    // one-hop neighbors
    for (graph.edges.items) |e| {
        if (impacted.contains(e.src)) try impacted.put(allocator, e.dst, {});
        if (impacted.contains(e.dst)) try impacted.put(allocator, e.src, {});
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print("{{\"seed\":{f},\"impacted\":[", .{std.json.fmt(seed, .{})});
    var first = true;
    var it = impacted.iterator();
    while (it.next()) |e| {
        if (!first) try aw.writer.writeAll(",");
        first = false;
        try aw.writer.print("{f}", .{std.json.fmt(e.key_ptr.*, .{})});
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

fn eventsToJson(allocator: Allocator, events: []const event_mod.Event) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"events\":[");
    for (events, 0..) |ev, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.writeAll(ev.raw_json);
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

test "aggregate failure rate" {
    const lines = [_][]const u8{
        \\{"ts":"t","run_id":"r1","agent_id":"a","type":"tool_call","payload":{"name":"grep","ok":true}}
        ,
        \\{"ts":"t","run_id":"r1","agent_id":"a","type":"tool_call","payload":{"name":"grep","ok":false}}
        ,
        \\{"ts":"t","run_id":"r1","agent_id":"a","type":"tool_call","payload":{"name":"ls","ok":true}}
        ,
    };
    var events: [3]event_mod.Event = undefined;
    defer for (&events) |*e| e.deinit(std.testing.allocator);
    for (lines, 0..) |line, i| events[i] = try event_mod.parseEvent(std.testing.allocator, line);

    const node: PipeNode = .{
        .type = .aggregate,
        .group_by = try std.testing.allocator.dupe(u8, "name"),
        .aggregate_op = .rate,
    };
    defer std.testing.allocator.free(node.group_by.?);

    const json = try runAggregate(std.testing.allocator, &events, node);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "failure_rate") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "grep") != null);
}
