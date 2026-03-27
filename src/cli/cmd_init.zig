/// lcl init — interactive environment setup.
/// Creates ~/.config/lcl/<name>/ with lcl.toml.

const std = @import("std");
const config_types = @import("config");

pub fn run(backing_allocator: std.mem.Allocator, opts: anytype) !void {
    _ = opts;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdin = std.fs.File.stdin().deprecatedReader();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // 1. Environment name
    try stdout.writeAll("Environment name [dev]: ");
    const name = try readLine(stdin, allocator) orelse "dev";
    const env_name = if (name.len == 0) "dev" else name;

    // 2. Base distro (for future image building)
    try stdout.writeAll(
        \\Pick a distro:
        \\  1) Alpine (recommended for testing)
        \\  2) Arch Linux
        \\  3) Ubuntu
        \\  4) Fedora
        \\
        \\Choice [1]:
    );
    const base_choice = try readLine(stdin, allocator) orelse "1";
    const base = switch (if (base_choice.len == 0) @as(u8, '1') else base_choice[0]) {
        '1' => "alpine",
        '2' => "archlinux",
        '3' => "ubuntu",
        '4' => "fedora",
        else => "alpine",
    };

    // 3. Shell
    try stdout.writeAll(
        \\Pick a shell:
        \\  1) zsh
        \\  2) bash
        \\  3) fish
        \\
        \\Choice [1]:
    );
    const shell_choice = try readLine(stdin, allocator) orelse "1";
    const shell_path = switch (if (shell_choice.len == 0) @as(u8, '1') else shell_choice[0]) {
        '1' => "/bin/zsh",
        '2' => "/bin/bash",
        '3' => "/usr/bin/fish",
        else => "/bin/zsh",
    };

    // 4. Mount home
    try stdout.writeAll("Mount home directory? [Y/n]: ");
    const mount_home_input = try readLine(stdin, allocator) orelse "y";
    const mount_home = mount_home_input.len == 0 or mount_home_input[0] == 'Y' or mount_home_input[0] == 'y';

    // 5. Dotfiles
    try stdout.writeAll("Dotfiles repo (optional, enter to skip): ");
    const dotfiles_input = try readLine(stdin, allocator) orelse "";
    const dotfiles: ?[]const u8 = if (dotfiles_input.len > 0) dotfiles_input else null;

    // Build config
    const config = config_types.LclConfig{
        .environment = .{
            .name = env_name,
            .base = base,
            .shell = shell_path,
        },
        .mounts = .{
            .home = mount_home,
        },
        .bridge = .{},
        .setup = .{
            .dotfiles = dotfiles,
        },
    };

    // Create config directory tree: ~/.config/lcl/<name>/
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    const dot_config = try std.fs.path.join(allocator, &.{ home, ".config" });
    std.fs.makeDirAbsolute(dot_config) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const base_dir = try config_types.configBasePath(allocator);
    std.fs.makeDirAbsolute(base_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const config_dir = try config_types.configPath(allocator, env_name);
    std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Write lcl.toml
    const toml_path = try std.fs.path.join(allocator, &.{ config_dir, "lcl.toml" });

    const toml_file = try std.fs.createFileAbsolute(toml_path, .{});
    defer toml_file.close();
    try config_types.serialize(config, toml_file.deprecatedWriter());

    // Summary
    try stdout.print(
        \\
        \\Created environment '{s}'
        \\  Config: {s}
        \\
        \\Next steps:
        \\  lcl build --name {s}     Build the VM image
        \\  lcl start --name {s}     Boot the environment
        \\
    , .{ env_name, toml_path, env_name, env_name });
}

fn readLine(reader: anytype, allocator: std.mem.Allocator) !?[]const u8 {
    var buf: [1024]u8 = undefined;
    const line = reader.readUntilDelimiter(&buf, '\n') catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    return try allocator.dupe(u8, std.mem.trim(u8, line, "\r"));
}
