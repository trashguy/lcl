/// Ghostty-compatible theme parser.
/// Reads files in the form:
///     palette = N=#rrggbb        (N = 0..15; entries 16+ are ignored)
///     background = #rrggbb
///     foreground = #rrggbb
///     cursor-color = #rrggbb
///     selection-background = #rrggbb
///     selection-foreground = #rrggbb
/// Unknown keys are silently ignored for forward compatibility.

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

pub const Theme = struct {
    palette: [16]?Rgb = .{null} ** 16,
    foreground: ?Rgb = null,
    background: ?Rgb = null,
    cursor_color: ?Rgb = null,
    selection_bg: ?Rgb = null,
    selection_fg: ?Rgb = null,
};

pub const ParseError = error{ InvalidHex, InvalidPaletteIndex, BadFormat };

pub fn parse(input: []const u8) ParseError!Theme {
    var theme: Theme = .{};
    var line_iter = std.mem.splitScalar(u8, input, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "palette")) {
            const inner_eq = std.mem.indexOfScalar(u8, val, '=') orelse return error.BadFormat;
            const idx_str = std.mem.trim(u8, val[0..inner_eq], " \t");
            const hex = std.mem.trim(u8, val[inner_eq + 1 ..], " \t");
            const idx = std.fmt.parseInt(u16, idx_str, 10) catch return error.InvalidPaletteIndex;
            if (idx >= 16) continue;
            theme.palette[@intCast(idx)] = try parseHex(hex);
        } else if (std.mem.eql(u8, key, "foreground")) {
            theme.foreground = try parseHex(val);
        } else if (std.mem.eql(u8, key, "background")) {
            theme.background = try parseHex(val);
        } else if (std.mem.eql(u8, key, "cursor-color")) {
            theme.cursor_color = try parseHex(val);
        } else if (std.mem.eql(u8, key, "selection-background")) {
            theme.selection_bg = try parseHex(val);
        } else if (std.mem.eql(u8, key, "selection-foreground")) {
            theme.selection_fg = try parseHex(val);
        }
    }
    return theme;
}

fn parseHex(s: []const u8) ParseError!Rgb {
    var hex = s;
    if (hex.len > 0 and hex[0] == '#') hex = hex[1..];
    if (hex.len != 6) return error.InvalidHex;
    return .{
        .r = std.fmt.parseInt(u8, hex[0..2], 16) catch return error.InvalidHex,
        .g = std.fmt.parseInt(u8, hex[2..4], 16) catch return error.InvalidHex,
        .b = std.fmt.parseInt(u8, hex[4..6], 16) catch return error.InvalidHex,
    };
}

// ── Bundled themes ──────────────────────────────────────────────────

pub const bundled_names = [_][]const u8{
    "dracula",
    "nord",
    "solarized-dark",
    "tokyo-night",
    "gruvbox-dark",
    "catppuccin-mocha",
};

fn bundledData(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "dracula")) return @embedFile("themes/dracula.conf");
    if (std.mem.eql(u8, name, "nord")) return @embedFile("themes/nord.conf");
    if (std.mem.eql(u8, name, "solarized-dark")) return @embedFile("themes/solarized-dark.conf");
    if (std.mem.eql(u8, name, "tokyo-night")) return @embedFile("themes/tokyo-night.conf");
    if (std.mem.eql(u8, name, "gruvbox-dark")) return @embedFile("themes/gruvbox-dark.conf");
    if (std.mem.eql(u8, name, "catppuccin-mocha")) return @embedFile("themes/catppuccin-mocha.conf");
    return null;
}

/// Look up a theme by name. Resolution order:
///   1. Bundled themes (compiled in)
///   2. ~/.config/lcl/themes/<name>
///   3. ~/.config/lcl/themes/<name>.conf
/// Returns null if the theme cannot be found or fails to parse.
pub fn loadByName(allocator: std.mem.Allocator, name: []const u8) ?Theme {
    if (bundledData(name)) |data| {
        return parse(data) catch null;
    }

    const home = std.posix.getenv("HOME") orelse return null;

    if (tryLoadFile(allocator, home, name, false)) |t| return t;
    if (tryLoadFile(allocator, home, name, true)) |t| return t;
    return null;
}

fn tryLoadFile(allocator: std.mem.Allocator, home: []const u8, name: []const u8, add_ext: bool) ?Theme {
    var name_buf: [256]u8 = undefined;
    const fname = if (add_ext)
        std.fmt.bufPrint(&name_buf, "{s}.conf", .{name}) catch return null
    else
        name;

    const path = std.fs.path.join(allocator, &.{ home, ".config", "lcl", "themes", fname }) catch return null;
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch return null;
    defer allocator.free(data);

    return parse(data) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "parseHex basic" {
    const c = try parseHex("#ff8040");
    try std.testing.expectEqual(@as(u8, 0xff), c.r);
    try std.testing.expectEqual(@as(u8, 0x80), c.g);
    try std.testing.expectEqual(@as(u8, 0x40), c.b);
}

test "parseHex without hash" {
    const c = try parseHex("00aabb");
    try std.testing.expectEqual(@as(u8, 0x00), c.r);
    try std.testing.expectEqual(@as(u8, 0xaa), c.g);
    try std.testing.expectEqual(@as(u8, 0xbb), c.b);
}

test "parseHex invalid length" {
    try std.testing.expectError(error.InvalidHex, parseHex("#fff"));
}

test "parse palette and colors" {
    const input =
        \\# A comment
        \\palette = 0=#000000
        \\palette = 1 = #ff0000
        \\palette = 15=#ffffff
        \\foreground = #cccccc
        \\background = #111111
        \\cursor-color = #00ff00
        \\selection-background = #333333
        \\unknown-key = #ffffff
    ;
    const t = try parse(input);
    try std.testing.expect(Rgb.eql(t.palette[0].?, .{ .r = 0, .g = 0, .b = 0 }));
    try std.testing.expect(Rgb.eql(t.palette[1].?, .{ .r = 0xff, .g = 0, .b = 0 }));
    try std.testing.expect(Rgb.eql(t.palette[15].?, .{ .r = 0xff, .g = 0xff, .b = 0xff }));
    try std.testing.expect(t.palette[2] == null);
    try std.testing.expect(Rgb.eql(t.foreground.?, .{ .r = 0xcc, .g = 0xcc, .b = 0xcc }));
    try std.testing.expect(Rgb.eql(t.background.?, .{ .r = 0x11, .g = 0x11, .b = 0x11 }));
    try std.testing.expect(Rgb.eql(t.cursor_color.?, .{ .r = 0, .g = 0xff, .b = 0 }));
    try std.testing.expect(Rgb.eql(t.selection_bg.?, .{ .r = 0x33, .g = 0x33, .b = 0x33 }));
    try std.testing.expect(t.selection_fg == null);
}

test "parse ignores out-of-range palette index" {
    const input = "palette = 256=#ffffff\nforeground = #abcdef";
    const t = try parse(input);
    try std.testing.expect(Rgb.eql(t.foreground.?, .{ .r = 0xab, .g = 0xcd, .b = 0xef }));
}

test "bundled dracula parses" {
    const data = bundledData("dracula").?;
    const t = try parse(data);
    try std.testing.expect(Rgb.eql(t.background.?, .{ .r = 0x28, .g = 0x2a, .b = 0x36 }));
    try std.testing.expect(Rgb.eql(t.foreground.?, .{ .r = 0xf8, .g = 0xf8, .b = 0xf2 }));
    try std.testing.expect(t.palette[1] != null);
}

test "bundled names all resolve" {
    for (bundled_names) |n| {
        const data = bundledData(n) orelse return error.MissingBundled;
        _ = try parse(data);
    }
}
