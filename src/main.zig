const std = @import("std");
const synapse = @import("synapse");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    synapse.cli.run(allocator, io, args) catch |err| switch (err) {
        error.Usage => {
            std.process.exit(2);
        },
        else => |e| return e,
    };
}
