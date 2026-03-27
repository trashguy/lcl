const std = @import("std");
const lifecycle = @import("lifecycle");

pub fn run(allocator: std.mem.Allocator, opts: anytype) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const name = opts.name orelse "dev";

    const pid = try lifecycle.readPidFile(allocator, name) orelse {
        try stderr.print("Environment '{s}' is not running.\n", .{name});
        return;
    };

    if (!lifecycle.isProcessAlive(pid)) {
        try stderr.print("Environment '{s}' is not running (stale pidfile).\n", .{name});
        try lifecycle.removePidFile(allocator, name);
        return;
    }

    // Send SIGTERM to the lcl start process
    std.posix.kill(pid, std.posix.SIG.TERM) catch |err| {
        try stderr.print("Failed to stop environment: {s}\n", .{@errorName(err)});
        return;
    };

    try stdout.print("Sent stop signal to '{s}' (pid {d}).\n", .{ name, pid });
}
