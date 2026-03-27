const std = @import("std");
const lifecycle = @import("lifecycle");

pub fn run(allocator: std.mem.Allocator, opts: anytype) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const name = opts.name orelse "dev";

    const pid = try lifecycle.readPidFile(allocator, name) orelse {
        try stdout.print("{s}: stopped\n", .{name});
        return;
    };

    if (lifecycle.isProcessAlive(pid)) {
        try stdout.print("{s}: running (pid {d})\n", .{ name, pid });
    } else {
        try stdout.print("{s}: stopped (stale pidfile removed)\n", .{name});
        try lifecycle.removePidFile(allocator, name);
    }
}
