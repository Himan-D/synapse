const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const event_mod = @import("event.zig");

pub const builtin_datasources = [_][]const u8{
    "harness_events",
    "tool_calls",
    "llm_spans",
    "memory_writes",
};

pub const Store = struct {
    allocator: Allocator,
    io: Io,
    root_dir: []const u8,
    /// datasource -> owned events
    tables: std.StringArrayHashMapUnmanaged(std.ArrayList(event_mod.Event)) = .empty,

    pub fn init(allocator: Allocator, io: Io, root_dir: []const u8) !Store {
        var self: Store = .{
            .allocator = allocator,
            .io = io,
            .root_dir = try allocator.dupe(u8, root_dir),
        };
        errdefer self.deinit();

        for (builtin_datasources) |ds| {
            try self.ensureDatasource(ds);
        }
        try self.loadAll();
        return self;
    }

    pub fn deinit(self: *Store) void {
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |*ev| ev.deinit(self.allocator);
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.tables.deinit(self.allocator);
        self.allocator.free(self.root_dir);
        self.* = undefined;
    }

    pub fn ensureDatasource(self: *Store, name: []const u8) !void {
        const gop = try self.tables.getOrPut(self.allocator, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
            gop.value_ptr.* = .empty;
        }
    }

    fn dataDir(self: *Store, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/.synapse/data", .{self.root_dir});
    }

    fn dataPath(self: *Store, buf: []u8, ds: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/.synapse/data/{s}.ndjson", .{ self.root_dir, ds });
    }

    pub fn loadAll(self: *Store) !void {
        var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const dir_path = try self.dataDir(&dir_buf);
        Io.Dir.cwd().createDirPath(self.io, dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {}, // may not exist yet on fresh init; createDirPath handles parents
        };

        var it = self.tables.iterator();
        while (it.next()) |entry| {
            try self.loadDatasource(entry.key_ptr.*);
        }
    }

    fn loadDatasource(self: *Store, ds: []const u8) !void {
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try self.dataPath(&path_buf, ds);
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer self.allocator.free(bytes);

        var list = self.tables.getPtr(ds).?;
        for (list.items) |*ev| ev.deinit(self.allocator);
        list.clearRetainingCapacity();

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            const ev = try event_mod.parseEvent(self.allocator, line);
            try list.append(self.allocator, ev);
        }
    }

    pub fn ingestLine(self: *Store, ds: []const u8, line: []const u8) !void {
        try self.ensureDatasource(ds);
        const ev = try event_mod.parseEvent(self.allocator, line);
        errdefer {
            var tmp = ev;
            tmp.deinit(self.allocator);
        }
        const list = self.tables.getPtr(ds).?;
        try list.append(self.allocator, ev);
    }

    pub fn clearDatasource(self: *Store, ds: []const u8) !void {
        try self.ensureDatasource(ds);
        const list = self.tables.getPtr(ds).?;
        for (list.items) |*ev| ev.deinit(self.allocator);
        list.clearRetainingCapacity();
        try self.persistDatasource(ds);
    }

    pub fn ingestNdjson(self: *Store, ds: []const u8, body: []const u8) !usize {
        return self.ingestNdjsonOpts(ds, body, false);
    }

    pub fn ingestNdjsonOpts(self: *Store, ds: []const u8, body: []const u8, replace: bool) !usize {
        if (replace) try self.clearDatasource(ds);
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            try self.ingestLine(ds, line);
            n += 1;
        }
        try self.persistDatasource(ds);
        return n;
    }

    pub fn persistDatasource(self: *Store, ds: []const u8) !void {
        var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const dir_path = try self.dataDir(&dir_buf);
        try Io.Dir.cwd().createDirPath(self.io, dir_path);

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const list = self.tables.getPtr(ds) orelse return;
        for (list.items) |ev| {
            try aw.writer.writeAll(ev.raw_json);
            try aw.writer.writeAll("\n");
        }

        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = try self.dataPath(&path_buf, ds);
        try Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = aw.written(),
            .flags = .{ .truncate = true },
        });
    }

    pub fn persistAll(self: *Store) !void {
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            try self.persistDatasource(entry.key_ptr.*);
        }
    }

    pub fn events(self: *Store, ds: []const u8) []const event_mod.Event {
        const list = self.tables.getPtr(ds) orelse return &.{};
        return list.items;
    }

    pub fn allEvents(self: *Store, allocator: Allocator) ![]event_mod.Event {
        var out: std.ArrayList(event_mod.Event) = .empty;
        errdefer out.deinit(allocator);
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            try out.appendSlice(allocator, entry.value_ptr.items);
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn filterEvents(
        self: *Store,
        allocator: Allocator,
        ds: ?[]const u8,
        where: std.StringHashMapUnmanaged([]const u8),
    ) ![]event_mod.Event {
        var out: std.ArrayList(event_mod.Event) = .empty;
        errdefer out.deinit(allocator);

        if (ds) |name| {
            try appendMatching(&out, allocator, self.events(name), where);
        } else {
            var it = self.tables.iterator();
            while (it.next()) |entry| {
                try appendMatching(&out, allocator, entry.value_ptr.items, where);
            }
        }
        return try out.toOwnedSlice(allocator);
    }
};

fn appendMatching(
    out: *std.ArrayList(event_mod.Event),
    allocator: Allocator,
    items: []const event_mod.Event,
    where: std.StringHashMapUnmanaged([]const u8),
) !void {
    for (items) |ev| {
        if (matches(ev, where)) try out.append(allocator, ev);
    }
}

fn matches(ev: event_mod.Event, where: std.StringHashMapUnmanaged([]const u8)) bool {
    var it = where.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const want = entry.value_ptr.*;
        const got: []const u8 = if (std.mem.eql(u8, key, "run_id"))
            ev.run_id
        else if (std.mem.eql(u8, key, "agent_id"))
            ev.agent_id
        else if (std.mem.eql(u8, key, "type"))
            ev.type_raw
        else if (std.mem.eql(u8, key, "ts"))
            ev.ts
        else
            return false;
        if (!std.mem.eql(u8, got, want)) return false;
    }
    return true;
}

test "ingest and filter by run_id" {
    const io = std.testing.io;
    const tmp = "zig-cache/synapse-store-test";
    Io.Dir.cwd().createDirPath(io, tmp) catch {};
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};

    var store = try Store.init(std.testing.allocator, io, tmp);
    defer store.deinit();

    const body =
        \\{"ts":"2026-07-31T14:00:00Z","run_id":"run_1","agent_id":"a1","type":"tool_call","payload":{"name":"grep","ok":true}}
        \\{"ts":"2026-07-31T14:00:01Z","run_id":"run_2","agent_id":"a1","type":"tool_call","payload":{"name":"ls","ok":false}}
        \\
    ;
    const n = try store.ingestNdjson("harness_events", body);
    try std.testing.expectEqual(@as(usize, 2), n);

    var where: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer where.deinit(std.testing.allocator);
    try where.put(std.testing.allocator, "run_id", "run_1");
    const filtered = try store.filterEvents(std.testing.allocator, "harness_events", where);
    defer std.testing.allocator.free(filtered);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);
}
