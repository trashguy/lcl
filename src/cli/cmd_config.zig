const std = @import("std");
const config_types = @import("config");

pub fn run(allocator: std.mem.Allocator, opts: anytype) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const name = opts.name orelse "dev";

    const config_dir = try config_types.configPath(allocator, name);
    defer allocator.free(config_dir);

    const toml_path = try std.fs.path.join(allocator, &.{ config_dir, "lcl.toml" });
    defer allocator.free(toml_path);

    const content = std.fs.cwd().readFileAlloc(allocator, toml_path, 64 * 1024) catch |err| {
        try stderr.print("Failed to read config at {s}: {s}\n", .{ toml_path, @errorName(err) });
        return;
    };
    defer allocator.free(content);

    try stdout.writeAll(content);
}
