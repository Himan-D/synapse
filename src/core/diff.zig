const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const event_mod = @import("event.zig");
const store_mod = @import("store.zig");
const safe_name = @import("safe_name.zig");

fn eventKey(ev: event_mod.Event) []const u8 {
    return ev.raw_json;
}

/// Diff current datasource events against a checkpoint file of NDJSON lines.
/// Returns owned JSON: { added, removed, updated, checkpoint, datasource }.
pub fn diffAgainstCheckpoint(
    allocator: Allocator,
    io: Io,
    store: *store_mod.Store,
    datasource: []const u8,
    checkpoint_path: []const u8,
) ![]u8 {
    var old_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer {
        var it = old_set.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        old_set.deinit(allocator);
    }

    if (Io.Dir.cwd().readFileAlloc(io, checkpoint_path, allocator, .unlimited)) |bytes| {
        defer allocator.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            const dup = try allocator.dupe(u8, t);
            const gop = try old_set.getOrPut(allocator, dup);
            if (gop.found_existing) allocator.free(dup);
        }
    } else |_| {}

    var new_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer new_set.deinit(allocator);
    for (store.events(datasource)) |ev| {
        try new_set.put(allocator, eventKey(ev), {});
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print(
        \\{{"datasource":{f},"checkpoint":{f},"added":[
    ,
        .{ std.json.fmt(datasource, .{}), std.json.fmt(checkpoint_path, .{}) },
    );
    var first = true;
    var nit = new_set.iterator();
    while (nit.next()) |e| {
        if (old_set.contains(e.key_ptr.*)) continue;
        if (!first) try aw.writer.writeAll(",");
        first = false;
        try aw.writer.writeAll(e.key_ptr.*);
    }
    try aw.writer.writeAll("],\"removed\":[");
    first = true;
    var oit = old_set.iterator();
    while (oit.next()) |e| {
        if (new_set.contains(e.key_ptr.*)) continue;
        if (!first) try aw.writer.writeAll(",");
        first = false;
        try aw.writer.writeAll(e.key_ptr.*);
    }
    try aw.writer.writeAll("],\"unchanged\":");
    var unchanged: usize = 0;
    var uit = new_set.iterator();
    while (uit.next()) |e| {
        if (old_set.contains(e.key_ptr.*)) unchanged += 1;
    }
    try aw.writer.print("{d}}}", .{unchanged});
    return try aw.toOwnedSlice();
}

/// Write current datasource snapshot as a checkpoint. Returns owned JSON.
pub fn saveCheckpoint(
    allocator: Allocator,
    io: Io,
    store: *store_mod.Store,
    root: []const u8,
    datasource: []const u8,
    name: []const u8,
) ![]u8 {
    if (!safe_name.isSafeName(name)) return error.InvalidCheckpointName;
    if (!safe_name.isSafeName(datasource)) return error.InvalidDatasourceName;
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, "{s}/.synapse/checkpoints", .{root});
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/.synapse/checkpoints/{s}.ndjson", .{ root, name });
    defer allocator.free(path);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (store.events(datasource)) |ev| {
        try aw.writer.writeAll(ev.raw_json);
        try aw.writer.writeAll("\n");
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
    return try std.fmt.allocPrint(allocator, "{{\"checkpoint\":{f},\"events\":{d}}}", .{
        std.json.fmt(path, .{}),
        store.events(datasource).len,
    });
}

/// Diff two runs by run_id within a datasource.
pub fn diffRuns(
    allocator: Allocator,
    store: *store_mod.Store,
    datasource: []const u8,
    run_a: []const u8,
    run_b: []const u8,
) ![]u8 {
    var where_a: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer where_a.deinit(allocator);
    try where_a.put(allocator, "run_id", run_a);
    var where_b: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer where_b.deinit(allocator);
    try where_b.put(allocator, "run_id", run_b);

    const a = try store.filterEvents(allocator, datasource, where_a);
    defer allocator.free(a);
    const b = try store.filterEvents(allocator, datasource, where_b);
    defer allocator.free(b);

    var set_a: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer set_a.deinit(allocator);
    for (a) |ev| try set_a.put(allocator, ev.raw_json, {});
    var set_b: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer set_b.deinit(allocator);
    for (b) |ev| try set_b.put(allocator, ev.raw_json, {});

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print(
        \\{{"run_a":{f},"run_b":{f},"only_a":[
    ,
        .{ std.json.fmt(run_a, .{}), std.json.fmt(run_b, .{}) },
    );
    var first = true;
    var ita = set_a.iterator();
    while (ita.next()) |e| {
        if (set_b.contains(e.key_ptr.*)) continue;
        if (!first) try aw.writer.writeAll(",");
        first = false;
        try aw.writer.writeAll(e.key_ptr.*);
    }
    try aw.writer.writeAll("],\"only_b\":[");
    first = true;
    var itb = set_b.iterator();
    while (itb.next()) |e| {
        if (set_a.contains(e.key_ptr.*)) continue;
        if (!first) try aw.writer.writeAll(",");
        first = false;
        try aw.writer.writeAll(e.key_ptr.*);
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

test "checkpoint name grammar" {
    try std.testing.expect(safe_name.isSafeName("baseline"));
    try std.testing.expect(!safe_name.isSafeName("../x"));
}
