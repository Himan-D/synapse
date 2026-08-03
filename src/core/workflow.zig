const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const safe_name = @import("safe_name.zig");

pub const RunStatus = enum {
    pending,
    running,
    waiting,
    completed,
    failed,
    cancelled,

    pub fn fromString(s: []const u8) ?RunStatus {
        inline for (@typeInfo(RunStatus).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const StepStatus = enum {
    pending,
    running,
    waiting,
    completed,
    failed,
    skipped,

    pub fn fromString(s: []const u8) ?StepStatus {
        inline for (@typeInfo(StepStatus).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const StepKind = enum {
    action,
    sleep,
    wait_event,
    fanout,
    noop,

    pub fn fromString(s: []const u8) ?StepKind {
        if (std.mem.eql(u8, s, "action")) return .action;
        if (std.mem.eql(u8, s, "sleep")) return .sleep;
        if (std.mem.eql(u8, s, "wait_event")) return .wait_event;
        if (std.mem.eql(u8, s, "fanout")) return .fanout;
        if (std.mem.eql(u8, s, "noop")) return .noop;
        return null;
    }
};

pub const RetryPolicy = struct {
    max_attempts: u32 = 3,
    backoff_ms: u64 = 1000,
    backoff_mult: f64 = 2.0,
};

pub const StepDef = struct {
    id: []const u8,
    kind: StepKind,
    /// action: pipe name
    pipe: ?[]const u8 = null,
    /// action http url
    url: ?[]const u8 = null,
    /// sleep duration
    ms: u64 = 0,
    /// wait_event type
    event_type: ?[]const u8 = null,
    timeout_ms: u64 = 0,
    /// fanout child workflow name
    child_workflow: ?[]const u8 = null,
    /// raw params object JSON (for pipe)
    params_json: []const u8 = "{}",
    retry: ?RetryPolicy = null,
};

pub const WorkflowDef = struct {
    allocator: Allocator,
    name: []const u8,
    version: u32,
    steps: []StepDef,
    retry: RetryPolicy,
    owned: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *WorkflowDef) void {
        for (self.owned.items) |s| self.allocator.free(s);
        self.owned.deinit(self.allocator);
        self.allocator.free(self.steps);
        self.* = undefined;
    }
};

/// Callback used by the engine to execute pipe actions without depending on Workspace.
pub const ActionExec = *const fn (
    ctx: *anyopaque,
    pipe_name: []const u8,
    params_json: []const u8,
) anyerror![]u8;

pub const ActionExecCtx = struct {
    ctx: *anyopaque,
    exec: ActionExec,
};

fn isoNow(allocator: Allocator, io: Io) ![]u8 {
    const secs = @max(Io.Clock.real.now(io).toSeconds(), 0);
    // Compact UTC-ish stamp for local durability (not full calendar format).
    return try std.fmt.allocPrint(allocator, "t{d}", .{secs});
}

fn runsDir(allocator: Allocator, root: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}/.synapse/workflows", .{root});
}

fn runPath(allocator: Allocator, root: []const u8, run_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}/.synapse/workflows/{s}.json", .{ root, run_id });
}

fn defsDir(allocator: Allocator, root: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}/workflows", .{root});
}

pub fn parseDef(allocator: Allocator, bytes: []const u8) !WorkflowDef {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var def: WorkflowDef = .{
        .allocator = allocator,
        .name = undefined,
        .version = 1,
        .steps = &.{},
        .retry = .{},
    };
    errdefer def.deinit();

    const name = try allocator.dupe(u8, obj.get("name").?.string);
    try def.owned.append(allocator, name);
    def.name = name;
    if (obj.get("version")) |v| def.version = @intCast(v.integer);

    if (obj.get("retry")) |r| {
        if (r.object.get("max_attempts")) |m| def.retry.max_attempts = @intCast(m.integer);
        if (r.object.get("backoff_ms")) |m| def.retry.backoff_ms = @intCast(m.integer);
        if (r.object.get("backoff_mult")) |m| switch (m) {
            .float => |f| def.retry.backoff_mult = f,
            .integer => |i| def.retry.backoff_mult = @floatFromInt(i),
            else => {},
        };
    }

    const steps_v = obj.get("steps").?.array;
    var steps: std.ArrayList(StepDef) = .empty;
    errdefer steps.deinit(allocator);
    for (steps_v.items) |sv| {
        const so = sv.object;
        const id = try allocator.dupe(u8, so.get("id").?.string);
        try def.owned.append(allocator, id);
        const kind_s = so.get("kind").?.string;
        const kind = StepKind.fromString(kind_s) orelse return error.InvalidStepKind;
        var step: StepDef = .{ .id = id, .kind = kind };
        if (so.get("pipe")) |p| {
            const s = try allocator.dupe(u8, p.string);
            try def.owned.append(allocator, s);
            step.pipe = s;
        }
        if (so.get("url")) |u| {
            const s = try allocator.dupe(u8, u.string);
            try def.owned.append(allocator, s);
            step.url = s;
        }
        if (so.get("type")) |t| {
            const s = try allocator.dupe(u8, t.string);
            try def.owned.append(allocator, s);
            step.event_type = s;
        }
        if (so.get("workflow")) |w| {
            const s = try allocator.dupe(u8, w.string);
            try def.owned.append(allocator, s);
            step.child_workflow = s;
        }
        if (so.get("ms")) |m| step.ms = @intCast(m.integer);
        if (so.get("timeout_ms")) |m| step.timeout_ms = @intCast(m.integer);
        if (so.get("params")) |p| {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try std.json.Stringify.value(p, .{}, &aw.writer);
            const pj = try allocator.dupe(u8, aw.written());
            try def.owned.append(allocator, pj);
            step.params_json = pj;
        }
        if (so.get("retry")) |r| {
            var pol = def.retry;
            if (r.object.get("max_attempts")) |m| pol.max_attempts = @intCast(m.integer);
            if (r.object.get("backoff_ms")) |m| pol.backoff_ms = @intCast(m.integer);
            step.retry = pol;
        }
        try steps.append(allocator, step);
    }
    def.steps = try steps.toOwnedSlice(allocator);
    return def;
}

pub fn loadDef(allocator: Allocator, io: Io, root: []const u8, name: []const u8) !WorkflowDef {
    if (!safe_name.isSafeName(name)) return error.InvalidWorkflowName;
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/workflows/{s}.workflow.json", .{ root, name });
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    return try parseDef(allocator, bytes);
}

pub fn listDefsJson(allocator: Allocator, io: Io, root: []const u8) ![]u8 {
    const dir_path = try defsDir(allocator, root);
    defer allocator.free(dir_path);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"workflows\":[");
    var first = true;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        try aw.writer.writeAll("]}");
        return try aw.toOwnedSlice();
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".workflow.json")) continue;
        const n = entry.name[0 .. entry.name.len - ".workflow.json".len];
        if (!first) try aw.writer.writeAll(",");
        first = false;
        try aw.writer.print("{f}", .{std.json.fmt(n, .{})});
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

fn genRunId(allocator: Allocator, io: Io) ![]u8 {
    var rand_buf: [8]u8 = undefined;
    const seed: u64 = @intCast(@max(Io.Clock.real.now(io).toNanoseconds(), 0));
    var prng = std.Random.DefaultPrng.init(seed ^ 0xc0ffee);
    prng.random().bytes(&rand_buf);
    const hex = std.fmt.bytesToHex(rand_buf, .lower);
    return try std.fmt.allocPrint(allocator, "wf_{s}", .{&hex});
}

pub fn startRun(
    allocator: Allocator,
    io: Io,
    root: []const u8,
    def: *const WorkflowDef,
    input_json: []const u8,
    run_id_opt: ?[]const u8,
) ![]u8 {
    const run_id = if (run_id_opt) |r| blk: {
        if (!safe_name.isSafeName(r)) return error.InvalidRunId;
        break :blk try allocator.dupe(u8, r);
    } else try genRunId(allocator, io);
    defer allocator.free(run_id);

    const dir = try runsDir(allocator, root);
    defer allocator.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);

    const now = try isoNow(allocator, io);
    defer allocator.free(now);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print(
        \\{{"run_id":{f},"workflow":{f},"version":{d},"status":"running","cursor":{f},"input":{s},"steps":{{
    ,
        .{
            std.json.fmt(run_id, .{}),
            std.json.fmt(def.name, .{}),
            def.version,
            std.json.fmt(if (def.steps.len > 0) def.steps[0].id else "", .{}),
            if (input_json.len > 0) input_json else "{}",
        },
    );
    for (def.steps, 0..) |st, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print(
            \\{f}:{{"status":"pending","attempts":0,"output":null,"wake_at_ms":null,"wait_type":null,"error":null}}
        ,
            .{std.json.fmt(st.id, .{})},
        );
    }
    try aw.writer.print(
        \\}},"created_at":{f},"updated_at":{f},"error":null}}
    ,
        .{ std.json.fmt(now, .{}), std.json.fmt(now, .{}) },
    );

    const path = try runPath(allocator, root, run_id);
    defer allocator.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });

    return try aw.toOwnedSlice();
}

pub fn loadRunBytes(allocator: Allocator, io: Io, root: []const u8, run_id: []const u8) ![]u8 {
    if (!safe_name.isSafeName(run_id)) return error.InvalidRunId;
    const path = try runPath(allocator, root, run_id);
    defer allocator.free(path);
    return try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

pub fn listRunsJson(allocator: Allocator, io: Io, root: []const u8) ![]u8 {
    const dir_path = try runsDir(allocator, root);
    defer allocator.free(dir_path);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"runs\":[");
    var first = true;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        try aw.writer.writeAll("]}");
        return try aw.toOwnedSlice();
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const rid = entry.name[0 .. entry.name.len - ".json".len];
        const bytes = loadRunBytes(allocator, io, root, rid) catch continue;
        defer allocator.free(bytes);
        if (!first) try aw.writer.writeAll(",");
        first = false;
        // Emit compact summary
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
            try aw.writer.print("{{\"run_id\":{f}}}", .{std.json.fmt(rid, .{})});
            continue;
        };
        defer parsed.deinit();
        const o = parsed.value.object;
        try aw.writer.print(
            \\{{"run_id":{f},"workflow":{f},"status":{f},"cursor":{f}}}
        ,
            .{
                std.json.fmt(o.get("run_id").?.string, .{}),
                std.json.fmt(o.get("workflow").?.string, .{}),
                std.json.fmt(o.get("status").?.string, .{}),
                std.json.fmt(if (o.get("cursor")) |c| c.string else "", .{}),
            },
        );
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

fn saveRunBytes(io: Io, root: []const u8, run_id: []const u8, bytes: []const u8) !void {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/.synapse/workflows/{s}.json", .{ root, run_id });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = bytes });
}

fn nowMs(io: Io) i64 {
    const ns = Io.Clock.real.now(io).toNanoseconds();
    const clamped: i96 = if (ns < 0) 0 else ns;
    return @intCast(@divTrunc(clamped, 1_000_000));
}

fn findStepIndex(def: *const WorkflowDef, id: []const u8) ?usize {
    for (def.steps, 0..) |s, i| {
        if (std.mem.eql(u8, s.id, id)) return i;
    }
    return null;
}

fn nextCursor(def: *const WorkflowDef, current_id: []const u8) ?[]const u8 {
    const idx = findStepIndex(def, current_id) orelse return null;
    if (idx + 1 >= def.steps.len) return null;
    return def.steps[idx + 1].id;
}

/// Rewrite run JSON after a mutation. Returns owned updated JSON.
fn rewriteRun(
    allocator: Allocator,
    io: Io,
    root: []const u8,
    run_id: []const u8,
    status: []const u8,
    cursor: []const u8,
    step_id: []const u8,
    step_status: []const u8,
    attempts: i64,
    output_json: ?[]const u8,
    wake_at_ms: ?i64,
    wait_type: ?[]const u8,
    err_msg: ?[]const u8,
    run_error: ?[]const u8,
) ![]u8 {
    const bytes = try loadRunBytes(allocator, io, root, run_id);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    var obj = parsed.value.object;

    // Mutate via re-serialize (ObjectMap values are owned by parsed arena — rebuild).
    const workflow = obj.get("workflow").?.string;
    const version = obj.get("version").?.integer;
    const input = obj.get("input").?;
    const created = obj.get("created_at").?.string;
    const steps_in = obj.get("steps").?.object;
    const now = try isoNow(allocator, io);
    defer allocator.free(now);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print(
        \\{{"run_id":{f},"workflow":{f},"version":{d},"status":{f},"cursor":{f},"input":
    ,
        .{
            std.json.fmt(run_id, .{}),
            std.json.fmt(workflow, .{}),
            version,
            std.json.fmt(status, .{}),
            std.json.fmt(cursor, .{}),
        },
    );
    try std.json.Stringify.value(input, .{}, &aw.writer);
    try aw.writer.writeAll(",\"steps\":{");

    var first = true;
    var it = steps_in.iterator();
    while (it.next()) |e| {
        if (!first) try aw.writer.writeAll(",");
        first = false;
        const sid = e.key_ptr.*;
        try aw.writer.print("{f}:", .{std.json.fmt(sid, .{})});
        if (std.mem.eql(u8, sid, step_id)) {
            try aw.writer.print("{{\"status\":{f},\"attempts\":{d},\"output\":", .{
                std.json.fmt(step_status, .{}),
                attempts,
            });
            if (output_json) |o| {
                try aw.writer.writeAll(o);
            } else {
                try aw.writer.writeAll("null");
            }
            try aw.writer.writeAll(",\"wake_at_ms\":");
            if (wake_at_ms) |w| try aw.writer.print("{d}", .{w}) else try aw.writer.writeAll("null");
            try aw.writer.writeAll(",\"wait_type\":");
            if (wait_type) |wt| try aw.writer.print("{f}", .{std.json.fmt(wt, .{})}) else try aw.writer.writeAll("null");
            try aw.writer.writeAll(",\"error\":");
            if (err_msg) |em| try aw.writer.print("{f}", .{std.json.fmt(em, .{})}) else try aw.writer.writeAll("null");
            try aw.writer.writeAll("}");
        } else {
            try std.json.Stringify.value(e.value_ptr.*, .{}, &aw.writer);
        }
    }
    try aw.writer.print(
        \\}},"created_at":{f},"updated_at":{f},"error":
    ,
        .{ std.json.fmt(created, .{}), std.json.fmt(now, .{}) },
    );
    if (run_error) |re| try aw.writer.print("{f}", .{std.json.fmt(re, .{})}) else try aw.writer.writeAll("null");
    try aw.writer.writeAll("}");

    const out = try aw.toOwnedSlice();
    try saveRunBytes(io, root, run_id, out);
    return out;
}

fn tryDeliverHttp(allocator: Allocator, io: Io, url: []const u8, body: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "http://")) return false;
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "user-agent", .value = "synapse-workflow/0.1.0" },
        },
        .keep_alive = false,
    }) catch return false;
    const code = @intFromEnum(result.status);
    return code >= 200 and code < 300;
}

/// Advance one run by at most one step transition. Returns owned run JSON.
pub fn tickRun(
    allocator: Allocator,
    io: Io,
    root: []const u8,
    run_id: []const u8,
    action_ctx: ?ActionExecCtx,
) ![]u8 {
    const bytes = try loadRunBytes(allocator, io, root, run_id);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const status_s = obj.get("status").?.string;
    if (std.mem.eql(u8, status_s, "completed") or
        std.mem.eql(u8, status_s, "failed") or
        std.mem.eql(u8, status_s, "cancelled"))
    {
        return try allocator.dupe(u8, bytes);
    }

    const workflow_name = obj.get("workflow").?.string;
    var def = try loadDef(allocator, io, root, workflow_name);
    defer def.deinit();

    const cursor = obj.get("cursor").?.string;
    if (cursor.len == 0) {
        return try rewriteRun(allocator, io, root, run_id, "completed", "", "", "completed", 0, null, null, null, null, null);
    }
    const step_idx = findStepIndex(&def, cursor) orelse {
        return try rewriteRun(allocator, io, root, run_id, "failed", cursor, cursor, "failed", 0, null, null, null, "unknown_cursor", "unknown_cursor");
    };
    const step = def.steps[step_idx];
    const steps_obj = obj.get("steps").?.object;
    const step_state = steps_obj.get(step.id).?.object;
    var attempts: i64 = if (step_state.get("attempts")) |a| a.integer else 0;
    const step_st = step_state.get("status").?.string;
    const now = nowMs(io);

    // Respect wake_at for waiting steps.
    if (std.mem.eql(u8, step_st, "waiting")) {
        if (step_state.get("wake_at_ms")) |w| {
            if (w != .null and w.integer > now) {
                return try allocator.dupe(u8, bytes);
            }
        }
        // wait_event without wake: stay waiting unless signaled (status flipped by signal()).
        if (step.kind == .wait_event) {
            if (step_state.get("wake_at_ms")) |w| {
                if (w == .null) return try allocator.dupe(u8, bytes);
            } else return try allocator.dupe(u8, bytes);
            // timed out
            return try rewriteRun(allocator, io, root, run_id, "failed", cursor, step.id, "failed", attempts, null, null, step.event_type, "timeout", "wait_event_timeout");
        }
    }

    switch (step.kind) {
        .noop => {
            const nxt = nextCursor(&def, step.id);
            return try rewriteRun(allocator, io, root, run_id, if (nxt == null) "completed" else "running", nxt orelse "", step.id, "completed", attempts + 1, "true", null, null, null, null);
        },
        .sleep => {
            if (!std.mem.eql(u8, step_st, "waiting")) {
                const wake = now + @as(i64, @intCast(step.ms));
                return try rewriteRun(allocator, io, root, run_id, "waiting", cursor, step.id, "waiting", attempts, null, wake, null, null, null);
            }
            // woken
            const nxt = nextCursor(&def, step.id);
            return try rewriteRun(allocator, io, root, run_id, if (nxt == null) "completed" else "running", nxt orelse "", step.id, "completed", attempts + 1, "true", null, null, null, null);
        },
        .wait_event => {
            if (!std.mem.eql(u8, step_st, "waiting") and !std.mem.eql(u8, step_st, "completed")) {
                const wake: ?i64 = if (step.timeout_ms > 0) now + @as(i64, @intCast(step.timeout_ms)) else null;
                return try rewriteRun(allocator, io, root, run_id, "waiting", cursor, step.id, "waiting", attempts, null, wake, step.event_type, null, null);
            }
            // completed via signal
            if (std.mem.eql(u8, step_st, "completed")) {
                const nxt = nextCursor(&def, step.id);
                return try rewriteRun(allocator, io, root, run_id, if (nxt == null) "completed" else "running", nxt orelse "", step.id, "completed", attempts, null, null, null, null, null);
            }
            return try allocator.dupe(u8, bytes);
        },
        .fanout => {
            // v1: record fanout intent and complete (child spawning is sequential stub).
            const out =
                \\{"fanout":"sequential_stub","note":"child runs not spawned in v1; mark completed"}
            ;
            const nxt = nextCursor(&def, step.id);
            return try rewriteRun(allocator, io, root, run_id, if (nxt == null) "completed" else "running", nxt orelse "", step.id, "completed", attempts + 1, out, null, null, null, null);
        },
        .action => {
            attempts += 1;
            const pol = step.retry orelse def.retry;
            var output: ?[]u8 = null;
            defer if (output) |o| allocator.free(o);
            var failed = false;
            var err_name: []const u8 = "action_failed";

            if (step.pipe) |pipe_name| {
                if (action_ctx) |ac| {
                    output = ac.exec(ac.ctx, pipe_name, step.params_json) catch |err| blk: {
                        failed = true;
                        err_name = @errorName(err);
                        break :blk null;
                    };
                } else {
                    failed = true;
                    err_name = "no_executor";
                }
            } else if (step.url) |url| {
                const body = step.params_json;
                if (!tryDeliverHttp(allocator, io, url, body)) {
                    failed = true;
                    err_name = "http_failed";
                } else {
                    output = try allocator.dupe(u8, "{\"ok\":true}");
                }
            } else {
                output = try allocator.dupe(u8, "{\"ok\":true}");
            }

            if (failed) {
                if (attempts < pol.max_attempts) {
                    const backoff: f64 = @floatFromInt(pol.backoff_ms);
                    const mult = std.math.pow(f64, pol.backoff_mult, @floatFromInt(attempts - 1));
                    const delay: i64 = @intFromFloat(backoff * mult);
                    const wake = now + delay;
                    return try rewriteRun(allocator, io, root, run_id, "waiting", cursor, step.id, "waiting", attempts, null, wake, null, err_name, null);
                }
                return try rewriteRun(allocator, io, root, run_id, "failed", cursor, step.id, "failed", attempts, null, null, null, err_name, err_name);
            }

            // Persist a compact receipt — full pipe payloads belong in datasources/graph.
            const receipt = try std.fmt.allocPrint(
                allocator,
                "{{\"ok\":true,\"bytes\":{d}}}",
                .{if (output) |o| o.len else 0},
            );
            defer allocator.free(receipt);

            const nxt = nextCursor(&def, step.id);
            return try rewriteRun(allocator, io, root, run_id, if (nxt == null) "completed" else "running", nxt orelse "", step.id, "completed", attempts, receipt, null, null, null, null);
        },
    }
}

pub fn tickAll(
    allocator: Allocator,
    io: Io,
    root: []const u8,
    action_ctx: ?ActionExecCtx,
) ![]u8 {
    const dir_path = try runsDir(allocator, root);
    defer allocator.free(dir_path);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"ticked\":[");
    var first = true;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        try aw.writer.writeAll("]}");
        return try aw.toOwnedSlice();
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const rid = entry.name[0 .. entry.name.len - ".json".len];
        const before = loadRunBytes(allocator, io, root, rid) catch continue;
        defer allocator.free(before);
        var bp = std.json.parseFromSlice(std.json.Value, allocator, before, .{}) catch continue;
        defer bp.deinit();
        const st = bp.value.object.get("status").?.string;
        if (!(std.mem.eql(u8, st, "running") or std.mem.eql(u8, st, "waiting") or std.mem.eql(u8, st, "pending"))) continue;
        const after = tickRun(allocator, io, root, rid, action_ctx) catch continue;
        defer allocator.free(after);
        if (!first) try aw.writer.writeAll(",");
        first = false;
        try aw.writer.print("{f}", .{std.json.fmt(rid, .{})});
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

pub fn signalRun(
    allocator: Allocator,
    io: Io,
    root: []const u8,
    run_id: []const u8,
    event_type: []const u8,
    payload_json: []const u8,
) ![]u8 {
    const bytes = try loadRunBytes(allocator, io, root, run_id);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const cursor = obj.get("cursor").?.string;
    const steps = obj.get("steps").?.object;
    const step_state = steps.get(cursor) orelse return error.NoCursorStep;
    const wait_type = if (step_state.object.get("wait_type")) |w| switch (w) {
        .string => |s| s,
        else => "",
    } else "";
    if (!std.mem.eql(u8, wait_type, event_type)) return error.EventTypeMismatch;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"signaled\":true,\"type\":");
    try aw.writer.print("{f},\"payload\":", .{std.json.fmt(event_type, .{})});
    try aw.writer.writeAll(if (payload_json.len > 0) payload_json else "{}");
    try aw.writer.writeAll("}");
    const out_payload = try aw.toOwnedSlice();
    defer allocator.free(out_payload);

    // Mark step completed with payload; tick will advance cursor.
    const attempts = if (step_state.object.get("attempts")) |a| a.integer else 0;
    const rewritten = try rewriteRun(allocator, io, root, run_id, "running", cursor, cursor, "completed", attempts, out_payload, null, null, null, null);
    allocator.free(rewritten);
    return try tickRun(allocator, io, root, run_id, null);
}

pub fn cancelRun(allocator: Allocator, io: Io, root: []const u8, run_id: []const u8) ![]u8 {
    const bytes = try loadRunBytes(allocator, io, root, run_id);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const cursor = parsed.value.object.get("cursor").?.string;
    return try rewriteRun(allocator, io, root, run_id, "cancelled", cursor, cursor, "skipped", 0, null, null, null, null, "cancelled");
}

test "parseDef and sleep/action flow" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp = "zig-cache/synapse-wf-test";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp ++ "/workflows");

    const def_json =
        \\{"name":"demo","version":1,"steps":[
        \\  {"id":"a","kind":"noop"},
        \\  {"id":"b","kind":"sleep","ms":1},
        \\  {"id":"c","kind":"noop"}
        \\],"retry":{"max_attempts":2,"backoff_ms":1}}
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp ++ "/workflows/demo.workflow.json", .data = def_json });

    var def = try loadDef(gpa, io, tmp, "demo");
    defer def.deinit();
    try std.testing.expectEqual(@as(usize, 3), def.steps.len);

    const started = try startRun(gpa, io, tmp, &def, "{\"x\":1}", "wf_demo1");
    defer gpa.free(started);
    try std.testing.expect(std.mem.indexOf(u8, started, "wf_demo1") != null);

    // tick noop a
    const r1 = try tickRun(gpa, io, tmp, "wf_demo1", null);
    defer gpa.free(r1);
    // tick sleep schedule
    const r2 = try tickRun(gpa, io, tmp, "wf_demo1", null);
    defer gpa.free(r2);
    // wait briefly then wake sleep step
    try Io.sleep(io, .fromMilliseconds(5), .real);
    const r3 = try tickRun(gpa, io, tmp, "wf_demo1", null);
    defer gpa.free(r3);
    const r4 = try tickRun(gpa, io, tmp, "wf_demo1", null);
    defer gpa.free(r4);
    try std.testing.expect(std.mem.indexOf(u8, r4, "completed") != null);
}
