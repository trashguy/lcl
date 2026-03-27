const std = @import("std");
const args = @import("args.zig");
const cmd_init = @import("cmd_init.zig");
const cmd_start = @import("cmd_start.zig");
const cmd_stop = @import("cmd_stop.zig");
const cmd_status = @import("cmd_status.zig");
const cmd_config = @import("cmd_config.zig");
const cmd_build = @import("cmd_build.zig");
const cmd_shell = @import("cmd_shell.zig");
const cmd_destroy = @import("cmd_destroy.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    const opts = args.parseArgs(raw_args);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const command = opts.command orelse {
        try stderr.print("lcl: unknown command '{s}'\n", .{if (opts.rest.len > 0) opts.rest[0] else "?"});
        try stderr.writeAll("Run 'lcl help' for usage.\n");
        std.process.exit(1);
    };

    if (opts.help and command != .help) {
        try args.printHelp(stdout);
        return;
    }

    switch (command) {
        .help => try args.printHelp(stdout),
        .version => try args.printVersion(stdout),
        .@"init" => try cmd_init.run(allocator, opts),
        .start => try cmd_start.run(allocator, opts),
        .stop => try cmd_stop.run(allocator, opts),
        .status => try cmd_status.run(allocator, opts),
        .config => try cmd_config.run(allocator, opts),
        .build => try cmd_build.run(allocator, opts),
        .shell => try cmd_shell.run(allocator, opts),
        .destroy => try cmd_destroy.run(allocator, opts),
    }
}
