const std = @import("std");
const lifecycle = @import("lifecycle");

pub fn run(allocator: std.mem.Allocator, opts: anytype) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const name = opts.name orelse "dev";

    if (try lifecycle.readPidFile(allocator, name)) |pid| {
        if (lifecycle.isProcessAlive(pid)) {
            try stdout.print("Environment '{s}' is running (pid {d}).\n", .{ name, pid });
            try stdout.writeAll("The serial console is attached to the terminal running 'lcl start'.\n");
            try stdout.writeAll("Connect to the VM from that terminal.\n");
            return;
        }
    }

    try stderr.print("Environment '{s}' is not running. Start it with 'lcl start'.\n", .{name});
}
