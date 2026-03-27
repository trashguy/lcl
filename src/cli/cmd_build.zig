const std = @import("std");
const config = @import("config");
const toml = @import("toml");
const image = @import("image");

pub fn run(allocator: std.mem.Allocator, opts: anytype) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const name = opts.name orelse "dev";

    // Read config to determine distro
    const config_dir = try config.configPath(allocator, name);
    defer allocator.free(config_dir);

    const toml_path = try std.fs.path.join(allocator, &.{ config_dir, "lcl.toml" });
    defer allocator.free(toml_path);

    const toml_data = std.fs.cwd().readFileAlloc(allocator, toml_path, 1024 * 1024) catch {
        try stderr.print("No config found for '{s}'. Run 'lcl init' first.\n", .{name});
        return;
    };
    defer allocator.free(toml_data);

    var parsed = toml.parse(allocator, toml_data) catch {
        try stderr.print("Failed to parse {s}\n", .{toml_path});
        return;
    };
    defer parsed.deinit();

    // Determine distro from base field
    const dist = image.distro.Distro.fromBase(parsed.config.environment.base) orelse {
        try stderr.print("Unsupported base distro: '{s}'\n", .{parsed.config.environment.base});
        try stderr.writeAll("Supported: alpine, archlinux\n");
        return;
    };

    image.buildImage(allocator, name, dist) catch |err| {
        try stderr.print("Build failed: {s}\n", .{@errorName(err)});
        return;
    };
}
