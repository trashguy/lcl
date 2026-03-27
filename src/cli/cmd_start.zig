const std = @import("std");
const config_types = @import("config");
const toml = @import("toml");
const vm_config = @import("vm_config");
const lifecycle = @import("lifecycle");

pub fn run(allocator: std.mem.Allocator, opts: anytype) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Determine environment name
    const name = opts.name orelse "dev";

    // Check if already running
    if (try lifecycle.readPidFile(allocator, name)) |pid| {
        if (lifecycle.isProcessAlive(pid)) {
            try stderr.print("Environment '{s}' is already running (pid {d})\n", .{ name, pid });
            return;
        }
        // Stale pidfile
        try lifecycle.removePidFile(allocator, name);
    }

    // Read config
    const config_dir = try config_types.configPath(allocator, name);
    defer allocator.free(config_dir);

    const toml_path = try std.fs.path.join(allocator, &.{ config_dir, "lcl.toml" });
    defer allocator.free(toml_path);

    const toml_content = std.fs.cwd().readFileAlloc(allocator, toml_path, 64 * 1024) catch |err| {
        try stderr.print("Failed to read config at {s}: {s}\n", .{ toml_path, @errorName(err) });
        return;
    };
    defer allocator.free(toml_content);

    var parsed = toml.parse(allocator, toml_content) catch |err| {
        try stderr.print("Failed to parse config: {s}\n", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();

    // Check kernel exists
    const kernel_path = try std.fs.path.join(allocator, &.{ config_dir, parsed.config.environment.kernel });
    defer allocator.free(kernel_path);
    std.fs.accessAbsolute(kernel_path, .{}) catch {
        try stderr.print("Kernel not found: {s}\n", .{kernel_path});
        try stderr.writeAll("Place a Linux kernel (vmlinuz) in your config directory.\n");
        return;
    };

    // Check rootfs exists
    const rootfs_path = try std.fs.path.join(allocator, &.{ config_dir, parsed.config.environment.rootfs });
    defer allocator.free(rootfs_path);
    std.fs.accessAbsolute(rootfs_path, .{}) catch {
        try stderr.print("Root filesystem not found: {s}\n", .{rootfs_path});
        try stderr.writeAll("Place a root filesystem image (rootfs.raw) in your config directory.\n");
        return;
    };

    // Build VM configuration
    const vz_config = vm_config.buildVmConfig(parsed.config, config_dir, allocator) catch |err| {
        try stderr.print("Failed to build VM config: {s}\n", .{@errorName(err)});
        return;
    };

    try stdout.print("Booting '{s}'...\n", .{name});

    // Build bridge config from parsed TOML
    const bridge_config = lifecycle.BridgeConfig{
        .keychain = parsed.config.bridge.keychain,
        .clipboard = parsed.config.bridge.clipboard,
        .open = parsed.config.bridge.open,
    };

    // Start VM — blocks until exit
    lifecycle.startVm(allocator, vz_config, name, bridge_config) catch |err| {
        try stderr.print("VM error: {s}\n", .{@errorName(err)});
        return;
    };

    try stdout.print("\nVM '{s}' stopped.\n", .{name});
}
