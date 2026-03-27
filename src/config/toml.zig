/// Minimal TOML parser for lcl.toml.
/// Supports: [tables], key = "string", key = true/false, key = ["array", "of", "strings"]
/// Does NOT support: nested tables, inline tables, multiline strings, dates, integers, floats.

const std = @import("std");
const types = @import("types");

pub const ParseError = error{
    UnexpectedCharacter,
    UnterminatedString,
    UnterminatedArray,
    UnknownTable,
    UnknownKey,
    InvalidValue,
    InvalidBool,
    EmptyInput,
    InvalidInteger,
} || std.mem.Allocator.Error;

const Table = enum {
    environment,
    mounts,
    bridge,
    setup,
};

/// Parse TOML content into an LclConfig.
/// Caller owns all allocated memory in the returned config.
/// Call `deinit` to free.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!ParsedConfig {
    var config = types.LclConfig{};
    var current_table: ?Table = null;

    // Collect dynamic arrays
    var packages: std.ArrayList([]const u8) = .{};
    var custom_mounts: std.ArrayList([]const u8) = .{};

    var line_iter = std.mem.splitScalar(u8, input, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // Skip empty lines and comments
        if (line.len == 0 or line[0] == '#') continue;

        // Table header
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse return error.UnexpectedCharacter;
            const table_name = std.mem.trim(u8, line[1..end], " \t");
            current_table = std.meta.stringToEnum(Table, table_name) orelse return error.UnknownTable;
            continue;
        }

        // Key = Value
        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        const raw_value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

        const table = current_table orelse return error.UnknownKey;

        switch (table) {
            .environment => {
                if (std.mem.eql(u8, key, "name")) {
                    config.environment.name = try parseString(allocator, raw_value);
                } else if (std.mem.eql(u8, key, "base")) {
                    config.environment.base = try parseString(allocator, raw_value);
                } else if (std.mem.eql(u8, key, "shell")) {
                    config.environment.shell = try parseString(allocator, raw_value);
                } else if (std.mem.eql(u8, key, "cpu")) {
                    config.environment.cpu = try parseUint(raw_value);
                } else if (std.mem.eql(u8, key, "memory_mb")) {
                    config.environment.memory_mb = try parseUint(raw_value);
                } else if (std.mem.eql(u8, key, "kernel")) {
                    config.environment.kernel = try parseString(allocator, raw_value);
                } else if (std.mem.eql(u8, key, "initrd")) {
                    config.environment.initrd = try parseString(allocator, raw_value);
                } else if (std.mem.eql(u8, key, "rootfs")) {
                    config.environment.rootfs = try parseString(allocator, raw_value);
                } else if (std.mem.eql(u8, key, "cmdline")) {
                    config.environment.cmdline = try parseString(allocator, raw_value);
                } else return error.UnknownKey;
            },
            .mounts => {
                if (std.mem.eql(u8, key, "home")) {
                    config.mounts.home = try parseBool(raw_value);
                } else if (std.mem.eql(u8, key, "custom")) {
                    const items = try parseStringArray(allocator, raw_value);
                    for (items) |item| try custom_mounts.append(allocator, item);
                    allocator.free(items);
                } else return error.UnknownKey;
            },
            .bridge => {
                if (std.mem.eql(u8, key, "keychain")) {
                    config.bridge.keychain = try parseBool(raw_value);
                } else if (std.mem.eql(u8, key, "clipboard")) {
                    config.bridge.clipboard = try parseBool(raw_value);
                } else if (std.mem.eql(u8, key, "okta")) {
                    config.bridge.okta = try parseBool(raw_value);
                } else if (std.mem.eql(u8, key, "open")) {
                    config.bridge.open = try parseBool(raw_value);
                } else return error.UnknownKey;
            },
            .setup => {
                if (std.mem.eql(u8, key, "packages")) {
                    const items = try parseStringArray(allocator, raw_value);
                    for (items) |item| try packages.append(allocator, item);
                    allocator.free(items);
                } else if (std.mem.eql(u8, key, "dotfiles")) {
                    config.setup.dotfiles = try parseString(allocator, raw_value);
                } else return error.UnknownKey;
            },
        }
    }

    config.setup.packages = try packages.toOwnedSlice(allocator);
    config.mounts.custom = try custom_mounts.toOwnedSlice(allocator);

    return .{
        .config = config,
        .allocator = allocator,
    };
}

fn parseString(allocator: std.mem.Allocator, raw: []const u8) ParseError![]const u8 {
    if (raw.len < 2 or raw[0] != '"') return error.UnterminatedString;
    const end = std.mem.lastIndexOfScalar(u8, raw, '"') orelse return error.UnterminatedString;
    if (end == 0) return error.UnterminatedString;
    return allocator.dupe(u8, raw[1..end]);
}

fn parseUint(raw: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, raw, 10) catch return error.InvalidInteger;
}

fn parseBool(raw: []const u8) ParseError!bool {
    if (std.mem.eql(u8, raw, "true")) return true;
    if (std.mem.eql(u8, raw, "false")) return false;
    return error.InvalidBool;
}

fn parseStringArray(allocator: std.mem.Allocator, raw: []const u8) ParseError![]const []const u8 {
    if (raw.len < 2 or raw[0] != '[') return error.UnterminatedArray;
    const end = std.mem.lastIndexOfScalar(u8, raw, ']') orelse return error.UnterminatedArray;
    const inner = std.mem.trim(u8, raw[1..end], " \t");

    if (inner.len == 0) return try allocator.alloc([]const u8, 0);

    var items: std.ArrayList([]const u8) = .{};
    var pos: usize = 0;

    while (pos < inner.len) {
        // Skip whitespace and commas
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == ',' or inner[pos] == '\t')) {
            pos += 1;
        }
        if (pos >= inner.len) break;

        if (inner[pos] != '"') return error.UnexpectedCharacter;
        pos += 1; // skip opening quote

        const str_start = pos;
        while (pos < inner.len and inner[pos] != '"') {
            pos += 1;
        }
        if (pos >= inner.len) return error.UnterminatedString;

        try items.append(allocator, try allocator.dupe(u8, inner[str_start..pos]));
        pos += 1; // skip closing quote
    }

    return try items.toOwnedSlice(allocator);
}

/// Result of parsing — holds the config and allocator for cleanup.
pub const ParsedConfig = struct {
    config: types.LclConfig,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedConfig) void {
        // Free allocated strings in environment
        freeIfAllocated(self.allocator, self.config.environment.name, "dev");
        freeIfAllocated(self.allocator, self.config.environment.base, "archlinux:latest");
        freeIfAllocated(self.allocator, self.config.environment.shell, "/bin/zsh");
        freeIfAllocated(self.allocator, self.config.environment.kernel, "vmlinuz");
        if (self.config.environment.initrd) |initrd| {
            freeIfAllocated(self.allocator, initrd, "initrd");
        }
        freeIfAllocated(self.allocator, self.config.environment.rootfs, "rootfs.raw");
        freeIfAllocated(self.allocator, self.config.environment.cmdline, "console=hvc0");

        // Free dotfiles
        if (self.config.setup.dotfiles) |d| self.allocator.free(d);

        // Free string arrays
        for (self.config.setup.packages) |p| self.allocator.free(p);
        self.allocator.free(self.config.setup.packages);

        for (self.config.mounts.custom) |c| self.allocator.free(c);
        self.allocator.free(self.config.mounts.custom);
    }
};

fn freeIfAllocated(allocator: std.mem.Allocator, value: []const u8, default: []const u8) void {
    if (value.ptr != default.ptr) {
        allocator.free(value);
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "parse minimal config" {
    const input =
        \\[environment]
        \\name = "arch-dev"
        \\base = "archlinux:latest"
        \\shell = "/bin/zsh"
        \\
        \\[mounts]
        \\home = true
        \\
        \\[bridge]
        \\keychain = true
        \\clipboard = true
        \\okta = false
        \\open = true
        \\
        \\[setup]
        \\packages = ["git", "neovim", "zsh"]
        \\dotfiles = "https://github.com/trashguy/dotfiles.git"
    ;

    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const config = result.config;

    try std.testing.expectEqualStrings("arch-dev", config.environment.name);
    try std.testing.expectEqualStrings("archlinux:latest", config.environment.base);
    try std.testing.expectEqualStrings("/bin/zsh", config.environment.shell);
    try std.testing.expect(config.mounts.home == true);
    try std.testing.expect(config.bridge.keychain == true);
    try std.testing.expect(config.bridge.okta == false);
    try std.testing.expectEqual(@as(usize, 3), config.setup.packages.len);
    try std.testing.expectEqualStrings("git", config.setup.packages[0]);
    try std.testing.expectEqualStrings("neovim", config.setup.packages[1]);
    try std.testing.expectEqualStrings("zsh", config.setup.packages[2]);
    try std.testing.expectEqualStrings("https://github.com/trashguy/dotfiles.git", config.setup.dotfiles.?);
}

test "parse with comments and blank lines" {
    const input =
        \\# This is a comment
        \\
        \\[environment]
        \\# Another comment
        \\name = "test"
        \\base = "ubuntu:latest"
        \\shell = "/bin/bash"
        \\
        \\[mounts]
        \\home = false
        \\
        \\[bridge]
        \\keychain = false
        \\clipboard = false
        \\okta = false
        \\open = false
        \\
        \\[setup]
    ;

    var result = try parse(std.testing.allocator, input);
    defer result.deinit();
    const config = result.config;

    try std.testing.expectEqualStrings("test", config.environment.name);
    try std.testing.expect(config.mounts.home == false);
    try std.testing.expect(config.bridge.keychain == false);
    try std.testing.expectEqual(@as(usize, 0), config.setup.packages.len);
}

test "parse empty array" {
    const input =
        \\[environment]
        \\name = "minimal"
        \\base = "alpine:latest"
        \\shell = "/bin/sh"
        \\
        \\[mounts]
        \\home = true
        \\
        \\[bridge]
        \\keychain = true
        \\clipboard = true
        \\okta = true
        \\open = true
        \\
        \\[setup]
        \\packages = []
    ;

    var result = try parse(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.config.setup.packages.len);
}

test "round-trip: serialize then parse" {
    const original = types.LclConfig{
        .environment = .{
            .name = "round-trip",
            .base = "fedora:latest",
            .shell = "/bin/fish",
        },
        .mounts = .{ .home = false },
        .bridge = .{
            .keychain = false,
            .clipboard = true,
            .okta = false,
            .open = true,
        },
        .setup = .{
            .packages = &.{ "vim", "tmux" },
            .dotfiles = "https://example.com/dots.git",
        },
    };

    // Serialize
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try types.serialize(original, stream.writer());
    const toml_text = stream.getWritten();

    // Parse back
    var result = try parse(std.testing.allocator, toml_text);
    defer result.deinit();
    const parsed = result.config;

    try std.testing.expectEqualStrings("round-trip", parsed.environment.name);
    try std.testing.expectEqualStrings("fedora:latest", parsed.environment.base);
    try std.testing.expectEqualStrings("/bin/fish", parsed.environment.shell);
    try std.testing.expect(parsed.mounts.home == false);
    try std.testing.expect(parsed.bridge.keychain == false);
    try std.testing.expect(parsed.bridge.clipboard == true);
    try std.testing.expectEqual(@as(usize, 2), parsed.setup.packages.len);
    try std.testing.expectEqualStrings("vim", parsed.setup.packages[0]);
    try std.testing.expectEqualStrings("tmux", parsed.setup.packages[1]);
    try std.testing.expectEqualStrings("https://example.com/dots.git", parsed.setup.dotfiles.?);
}
