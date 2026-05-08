/// LCL configuration types and serialization.
/// Represents the contents of an lcl.toml config file.

const std = @import("std");

pub const LclConfig = struct {
    environment: Environment = .{},
    mounts: Mounts = .{},
    bridge: Bridge = .{},
    setup: Setup = .{},
    appearance: Appearance = .{},

    pub const Environment = struct {
        name: []const u8 = "dev",
        base: []const u8 = "archlinux:latest",
        shell: []const u8 = "/bin/zsh",
        cpu: u32 = 4,
        memory_mb: u32 = 4096,
        kernel: []const u8 = "vmlinuz",
        initrd: ?[]const u8 = "initrd",
        rootfs: []const u8 = "rootfs.raw",
        cmdline: []const u8 = "console=hvc0",
    };

    pub const Mounts = struct {
        home: bool = true,
        custom: []const []const u8 = &.{},
    };

    pub const Bridge = struct {
        keychain: bool = true,
        clipboard: bool = true,
        okta: bool = true,
        open: bool = true,
    };

    pub const Setup = struct {
        packages: []const []const u8 = &.{},
        dotfiles: ?[]const u8 = null,
    };

    pub const Appearance = struct {
        font: []const u8 = "Menlo",
        font_size: f32 = 14.0,
        fg_r: f32 = 0.0,
        fg_g: f32 = 1.0,
        fg_b: f32 = 0.0,
        bg_r: f32 = 0.0,
        bg_g: f32 = 0.0,
        bg_b: f32 = 0.0,
        /// Optional Ghostty-style theme name. Resolved against bundled themes
        /// first, then ~/.config/lcl/themes/<name>(.conf). When set, the theme's
        /// palette / foreground / background / cursor color override the
        /// individual fg_*/bg_* fields above.
        theme: ?[]const u8 = null,

        /// How many lines of scrollback history the renderer retains.
        /// Ignored when `scrollback_unlimited` is true. Memory cost is
        /// approximately `lines * cols * 16 bytes`.
        scrollback_lines: u32 = 1000,

        /// If true, scrollback is capped at the internal "effectively
        /// unlimited" ceiling (100k lines) rather than honouring
        /// `scrollback_lines`. We don't expose true unlimited because a
        /// runaway log producer would otherwise grow allocations until
        /// the app is killed.
        scrollback_unlimited: bool = false,
    };
};

/// Internal ceiling used when the user ticks "Unlimited" in the scrollback
/// setting. ~100k lines × 100 cols × 16 B/cell ≈ 160 MB worst case.
pub const scrollback_unlimited_cap: u32 = 100_000;

/// Serialize an LclConfig to TOML format.
pub fn serialize(config: LclConfig, writer: anytype) !void {
    try writer.writeAll("[environment]\n");
    try writeString(writer, "name", config.environment.name);
    try writeString(writer, "base", config.environment.base);
    try writeString(writer, "shell", config.environment.shell);
    try writeInt(writer, "cpu", config.environment.cpu);
    try writeInt(writer, "memory_mb", config.environment.memory_mb);
    try writeString(writer, "kernel", config.environment.kernel);
    if (config.environment.initrd) |initrd| {
        try writeString(writer, "initrd", initrd);
    }
    try writeString(writer, "rootfs", config.environment.rootfs);
    try writeString(writer, "cmdline", config.environment.cmdline);

    try writer.writeAll("\n[mounts]\n");
    try writeBool(writer, "home", config.mounts.home);
    if (config.mounts.custom.len > 0) {
        try writeStringArray(writer, "custom", config.mounts.custom);
    }

    try writer.writeAll("\n[bridge]\n");
    try writeBool(writer, "keychain", config.bridge.keychain);
    try writeBool(writer, "clipboard", config.bridge.clipboard);
    try writeBool(writer, "okta", config.bridge.okta);
    try writeBool(writer, "open", config.bridge.open);

    try writer.writeAll("\n[setup]\n");
    if (config.setup.packages.len > 0) {
        try writeStringArray(writer, "packages", config.setup.packages);
    }
    if (config.setup.dotfiles) |dotfiles| {
        try writeString(writer, "dotfiles", dotfiles);
    }

    try writer.writeAll("\n[appearance]\n");
    try writeString(writer, "font", config.appearance.font);
    try writeFloat(writer, "font_size", config.appearance.font_size);
    try writeFloat(writer, "fg_r", config.appearance.fg_r);
    try writeFloat(writer, "fg_g", config.appearance.fg_g);
    try writeFloat(writer, "fg_b", config.appearance.fg_b);
    try writeFloat(writer, "bg_r", config.appearance.bg_r);
    try writeFloat(writer, "bg_g", config.appearance.bg_g);
    try writeFloat(writer, "bg_b", config.appearance.bg_b);
    if (config.appearance.theme) |t| {
        try writeString(writer, "theme", t);
    }
    try writeInt(writer, "scrollback_lines", config.appearance.scrollback_lines);
    try writeBool(writer, "scrollback_unlimited", config.appearance.scrollback_unlimited);
}

fn writeString(writer: anytype, key: []const u8, value: []const u8) !void {
    try writer.print("{s} = \"{s}\"\n", .{ key, value });
}

fn writeInt(writer: anytype, key: []const u8, value: u32) !void {
    try writer.print("{s} = {d}\n", .{ key, value });
}

fn writeBool(writer: anytype, key: []const u8, value: bool) !void {
    try writer.print("{s} = {s}\n", .{ key, if (value) "true" else "false" });
}

fn writeFloat(writer: anytype, key: []const u8, value: f32) !void {
    try writer.print("{s} = {d:.4}\n", .{ key, value });
}

fn writeStringArray(writer: anytype, key: []const u8, values: []const []const u8) !void {
    try writer.print("{s} = [", .{key});
    for (values, 0..) |val, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("\"{s}\"", .{val});
    }
    try writer.writeAll("]\n");
}

// ── Config directory helpers ─────────────────────────────────────────

/// Returns the path to ~/.config/lcl/ (caller owns memory).
pub fn configBasePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(allocator, &.{ home, ".config", "lcl" });
}

/// Returns the path to ~/.config/lcl/<name>/ (caller owns memory).
pub fn configPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(allocator, &.{ home, ".config", "lcl", name });
}

// ── Tests ────────────────────────────────────────────────────────────

test "serialize default config" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const config = LclConfig{};
    try serialize(config, writer);
    const output = stream.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "[environment]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name = \"dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[bridge]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "keychain = true") != null);
}

test "serialize config with packages" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const config = LclConfig{
        .environment = .{
            .name = "arch-dev",
            .base = "archlinux:latest",
            .shell = "/bin/zsh",
        },
        .setup = .{
            .packages = &.{ "git", "neovim", "zsh" },
            .dotfiles = "https://github.com/trashguy/dotfiles.git",
        },
    };
    try serialize(config, writer);
    const output = stream.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "name = \"arch-dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "packages = [\"git\", \"neovim\", \"zsh\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dotfiles = \"https://github.com/trashguy/dotfiles.git\"") != null);
}
