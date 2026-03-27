const std = @import("std");
const config_types = @import("config");
const lifecycle = @import("lifecycle");

pub fn run(allocator: std.mem.Allocator, opts: anytype) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const name = opts.name orelse "dev";

    // Check if running
    if (try lifecycle.readPidFile(allocator, name)) |pid| {
        if (lifecycle.isProcessAlive(pid)) {
            if (!opts.force) {
                try stderr.print("Environment '{s}' is running (pid {d}). Use --force to stop and destroy.\n", .{ name, pid });
                return;
            }
            // Force stop
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }
    }

    // Delete config directory
    const config_dir = try config_types.configPath(allocator, name);
    defer allocator.free(config_dir);

    std.fs.deleteTreeAbsolute(config_dir) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print("Environment '{s}' does not exist.\n", .{name});
            return;
        },
        else => {
            try stderr.print("Failed to destroy environment: {s}\n", .{@errorName(err)});
            return;
        },
    };

    try stdout.print("Destroyed environment '{s}'.\n", .{name});
}
