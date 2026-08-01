const std = @import("std");
const Allocator = std.mem.Allocator;
const event_mod = @import("event.zig");

pub const Layer = enum {
    world,
    work,
    mind,

    pub fn fromString(s: []const u8) ?Layer {
        if (std.mem.eql(u8, s, "world")) return .world;
        if (std.mem.eql(u8, s, "work")) return .work;
        if (std.mem.eql(u8, s, "mind")) return .mind;
        return null;
    }

    pub fn toString(self: Layer) []const u8 {
        return switch (self) {
            .world => "world",
            .work => "work",
            .mind => "mind",
        };
    }
};

pub const Node = struct {
    id: []const u8,
    layer: Layer,
    kind: []const u8,
    props_json: []const u8,
    valid_from: []const u8,
    valid_to: []const u8,
    score: f32 = 0,
};

pub const Edge = struct {
    id: []const u8,
    src: []const u8,
    dst: []const u8,
    kind: []const u8,
    confidence: f32,
    evidence_json: []const u8,
    props_json: []const u8,
};

pub const Graph = struct {
    allocator: Allocator,
    nodes: std.StringArrayHashMapUnmanaged(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    /// Owned strings created during materialization.
    owned: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: Allocator) Graph {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Graph) void {
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        for (self.owned.items) |s| self.allocator.free(s);
        self.owned.deinit(self.allocator);
        self.* = undefined;
    }

    fn retain(self: *Graph, s: []const u8) ![]const u8 {
        const dup = try self.allocator.dupe(u8, s);
        try self.owned.append(self.allocator, dup);
        return dup;
    }

    pub fn upsertNode(self: *Graph, node: Node) !void {
        const gop = try self.nodes.getOrPut(self.allocator, node.id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.retain(node.id);
            gop.value_ptr.* = .{
                .id = gop.key_ptr.*,
                .layer = node.layer,
                .kind = try self.retain(node.kind),
                .props_json = try self.retain(node.props_json),
                .valid_from = try self.retain(node.valid_from),
                .valid_to = try self.retain(node.valid_to),
                .score = node.score,
            };
        } else {
            gop.value_ptr.score = @max(gop.value_ptr.score, node.score);
        }
    }

    pub fn addEdge(self: *Graph, edge: Edge) !void {
        try self.edges.append(self.allocator, .{
            .id = try self.retain(edge.id),
            .src = try self.retain(edge.src),
            .dst = try self.retain(edge.dst),
            .kind = try self.retain(edge.kind),
            .confidence = edge.confidence,
            .evidence_json = try self.retain(edge.evidence_json),
            .props_json = try self.retain(edge.props_json),
        });
    }

    pub fn filterLayers(self: *Graph, layers: []const Layer) !Graph {
        var out = Graph.init(self.allocator);
        errdefer out.deinit();
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            if (layerAllowed(entry.value_ptr.layer, layers)) {
                try out.upsertNode(entry.value_ptr.*);
            }
        }
        for (self.edges.items) |e| {
            if (out.nodes.contains(e.src) and out.nodes.contains(e.dst)) {
                try out.addEdge(e);
            }
        }
        return out;
    }

    fn layerAllowed(layer: Layer, layers: []const Layer) bool {
        if (layers.len == 0) return true;
        for (layers) |l| if (l == layer) return true;
        return false;
    }
};

/// Materialize World/Work/Mind nodes from events.
pub fn materialize(allocator: Allocator, events: []const event_mod.Event, layers: []const Layer) !Graph {
    var g = Graph.init(allocator);
    errdefer g.deinit();

    for (events, 0..) |ev, idx| {
        switch (ev.type) {
            .tool_call => try materializeToolCall(&g, ev, idx),
            .memory_write => try materializeMemory(&g, ev, idx),
            .plan_step => try materializePlan(&g, ev, idx),
            .error_event => try materializeError(&g, ev, idx),
            .llm_span => try materializeLlm(&g, ev, idx),
            .unknown => {},
        }
    }

    if (layers.len == 0) return g;
    const filtered = try g.filterLayers(layers);
    g.deinit();
    return filtered;
}

fn materializeToolCall(g: *Graph, ev: event_mod.Event, idx: usize) !void {
    const name = (try event_mod.payloadString(g.allocator, ev.payload_json, "name")) orelse
        try g.allocator.dupe(u8, "unknown");
    defer g.allocator.free(name);

    var tool_id_buf: [128]u8 = undefined;
    const tool_id = try std.fmt.bufPrint(&tool_id_buf, "tool:{s}", .{name});
    var op_id_buf: [160]u8 = undefined;
    const op_id = try std.fmt.bufPrint(&op_id_buf, "tool_op:{s}:{d}", .{ name, idx });

    try g.upsertNode(.{
        .id = tool_id,
        .layer = .world,
        .kind = "tool",
        .props_json = ev.payload_json,
        .valid_from = ev.ts,
        .valid_to = "",
        .score = 1.0,
    });
    try g.upsertNode(.{
        .id = op_id,
        .layer = .work,
        .kind = "tool_op",
        .props_json = ev.payload_json,
        .valid_from = ev.ts,
        .valid_to = "",
        .score = 1.2,
    });

    var edge_id_buf: [180]u8 = undefined;
    const edge_id = try std.fmt.bufPrint(&edge_id_buf, "edge:calls:{d}", .{idx});
    try g.addEdge(.{
        .id = edge_id,
        .src = op_id,
        .dst = tool_id,
        .kind = "calls",
        .confidence = 1.0,
        .evidence_json = ev.raw_json,
        .props_json = "{}",
    });

    var run_id_buf: [128]u8 = undefined;
    const run_node = try std.fmt.bufPrint(&run_id_buf, "run:{s}", .{ev.run_id});
    try g.upsertNode(.{
        .id = run_node,
        .layer = .work,
        .kind = "run",
        .props_json = "{}",
        .valid_from = ev.ts,
        .valid_to = "",
        .score = 0.5,
    });
    var run_edge_buf: [180]u8 = undefined;
    const run_edge = try std.fmt.bufPrint(&run_edge_buf, "edge:spawns:{d}", .{idx});
    try g.addEdge(.{
        .id = run_edge,
        .src = run_node,
        .dst = op_id,
        .kind = "spawns",
        .confidence = 1.0,
        .evidence_json = ev.raw_json,
        .props_json = "{}",
    });
}

fn materializeMemory(g: *Graph, ev: event_mod.Event, idx: usize) !void {
    const text = (try event_mod.payloadString(g.allocator, ev.payload_json, "text")) orelse
        (try event_mod.payloadString(g.allocator, ev.payload_json, "content")) orelse
        try g.allocator.dupe(u8, ev.payload_json);
    defer g.allocator.free(text);

    var hash: u64 = 14695981039346656037;
    for (text) |c| {
        hash ^= c;
        hash *%= 1099511628211;
    }
    var claim_buf: [64]u8 = undefined;
    const claim_id = try std.fmt.bufPrint(&claim_buf, "claim:{x}", .{hash});

    try g.upsertNode(.{
        .id = claim_id,
        .layer = .mind,
        .kind = "claim",
        .props_json = ev.payload_json,
        .valid_from = ev.ts,
        .valid_to = "",
        .score = 2.0,
    });

    var run_buf: [128]u8 = undefined;
    const run_node = try std.fmt.bufPrint(&run_buf, "run:{s}", .{ev.run_id});
    try g.upsertNode(.{
        .id = run_node,
        .layer = .work,
        .kind = "run",
        .props_json = "{}",
        .valid_from = ev.ts,
        .valid_to = "",
        .score = 0.5,
    });
    var edge_buf: [96]u8 = undefined;
    const edge_id = try std.fmt.bufPrint(&edge_buf, "edge:derived:{d}", .{idx});
    try g.addEdge(.{
        .id = edge_id,
        .src = claim_id,
        .dst = run_node,
        .kind = "derived_from",
        .confidence = 0.9,
        .evidence_json = ev.raw_json,
        .props_json = "{}",
    });
}

fn materializePlan(g: *Graph, ev: event_mod.Event, idx: usize) !void {
    const task = (try event_mod.payloadString(g.allocator, ev.payload_json, "task_id")) orelse
        (try event_mod.payloadString(g.allocator, ev.payload_json, "name")) orelse
        try g.allocator.dupe(u8, "step");
    defer g.allocator.free(task);

    var id_buf: [160]u8 = undefined;
    const task_id = try std.fmt.bufPrint(&id_buf, "task:{s}", .{task});
    try g.upsertNode(.{
        .id = task_id,
        .layer = .work,
        .kind = "task",
        .props_json = ev.payload_json,
        .valid_from = ev.ts,
        .valid_to = "",
        .score = 1.5,
    });
    _ = idx;
}

fn materializeError(g: *Graph, ev: event_mod.Event, idx: usize) !void {
    var id_buf: [64]u8 = undefined;
    const err_id = try std.fmt.bufPrint(&id_buf, "error:{d}", .{idx});
    try g.upsertNode(.{
        .id = err_id,
        .layer = .work,
        .kind = "error",
        .props_json = ev.payload_json,
        .valid_from = ev.ts,
        .valid_to = "",
        .score = 1.8,
    });
    const tool = try event_mod.payloadString(g.allocator, ev.payload_json, "tool");
    defer if (tool) |t| g.allocator.free(t);
    if (tool) |name| {
        var tool_buf: [128]u8 = undefined;
        const tool_id = try std.fmt.bufPrint(&tool_buf, "tool:{s}", .{name});
        try g.upsertNode(.{
            .id = tool_id,
            .layer = .world,
            .kind = "tool",
            .props_json = "{}",
            .valid_from = ev.ts,
            .valid_to = "",
            .score = 1.0,
        });
        var edge_buf: [96]u8 = undefined;
        const edge_id = try std.fmt.bufPrint(&edge_buf, "edge:caused:{d}", .{idx});
        try g.addEdge(.{
            .id = edge_id,
            .src = err_id,
            .dst = tool_id,
            .kind = "caused_by",
            .confidence = 1.0,
            .evidence_json = ev.raw_json,
            .props_json = "{}",
        });
    }
}

fn materializeLlm(g: *Graph, ev: event_mod.Event, idx: usize) !void {
    var id_buf: [64]u8 = undefined;
    const llm_id = try std.fmt.bufPrint(&id_buf, "llm:{d}", .{idx});
    try g.upsertNode(.{
        .id = llm_id,
        .layer = .work,
        .kind = "llm_span",
        .props_json = ev.payload_json,
        .valid_from = ev.ts,
        .valid_to = "",
        .score = 0.8,
    });
    if (try event_mod.payloadString(g.allocator, ev.payload_json, "model")) |model| {
        defer g.allocator.free(model);
        var model_buf: [128]u8 = undefined;
        const model_id = try std.fmt.bufPrint(&model_buf, "model:{s}", .{model});
        try g.upsertNode(.{
            .id = model_id,
            .layer = .world,
            .kind = "model",
            .props_json = "{}",
            .valid_from = ev.ts,
            .valid_to = "",
            .score = 0.6,
        });
    }
}

test "materialize tool_call creates world+work" {
    const line =
        \\{"ts":"2026-07-31T14:00:00Z","run_id":"run_1","agent_id":"a1","type":"tool_call","payload":{"name":"grep","ok":true}}
    ;
    var ev = try event_mod.parseEvent(std.testing.allocator, line);
    defer ev.deinit(std.testing.allocator);
    const layers = [_]Layer{ .world, .work };
    var g = try materialize(std.testing.allocator, &.{ev}, &layers);
    defer g.deinit();
    try std.testing.expect(g.nodes.contains("tool:grep"));
    try std.testing.expect(g.nodes.count() >= 2);
}
