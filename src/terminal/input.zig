/// Terminal input encoding.
/// Translates macOS key events (keyCode + modifierFlags) into
/// VT100/xterm byte sequences for the PTY.

const std = @import("std");

// ── macOS virtual keycodes ──────────────────────────────────────────

pub const KeyCode = struct {
    pub const return_key = 0x24;
    pub const tab = 0x30;
    pub const delete = 0x33; // backspace
    pub const escape = 0x35;
    pub const forward_delete = 0x75;
    pub const up_arrow = 0x7E;
    pub const down_arrow = 0x7D;
    pub const left_arrow = 0x7B;
    pub const right_arrow = 0x7C;
    pub const home = 0x73;
    pub const end = 0x77;
    pub const page_up = 0x74;
    pub const page_down = 0x79;
    pub const f1 = 0x7A;
    pub const f2 = 0x78;
    pub const f3 = 0x63;
    pub const f4 = 0x76;
    pub const f5 = 0x60;
    pub const f6 = 0x61;
    pub const f7 = 0x62;
    pub const f8 = 0x64;
    pub const f9 = 0x65;
    pub const f10 = 0x6D;
    pub const f11 = 0x67;
    pub const f12 = 0x6F;
};

// ── NSEvent modifier flag masks ─────────────────────────────────────

pub const ModifierFlags = struct {
    pub const shift: u64 = 1 << 17;
    pub const control: u64 = 1 << 18;
    pub const option: u64 = 1 << 19; // Alt
    pub const command: u64 = 1 << 20;
};

// ── Encode result ───────────────────────────────────────────────────

pub const EncodeResult = struct {
    data: [32]u8 = undefined,
    len: u8 = 0,

    pub fn bytes(self: *const EncodeResult) []const u8 {
        return self.data[0..self.len];
    }
};

/// Encode a key event into VT byte sequence(s).
/// Returns null if the key should not be sent (e.g., bare Cmd press).
pub fn encodeKey(
    keycode: u16,
    characters: []const u8,
    modifiers: u64,
    app_cursor_mode: bool,
) ?EncodeResult {
    const ctrl = (modifiers & ModifierFlags.control) != 0;
    const alt = (modifiers & ModifierFlags.option) != 0;
    const shift = (modifiers & ModifierFlags.shift) != 0;

    // Modifier parameter for CSI sequences: 1 + (shift*1 + alt*2 + ctrl*4)
    const mod_param: u8 = 1 +
        (if (shift) @as(u8, 1) else 0) +
        (if (alt) @as(u8, 2) else 0) +
        (if (ctrl) @as(u8, 4) else 0);
    const has_mod = mod_param > 1;

    var result = EncodeResult{};

    // Special keys
    switch (keycode) {
        KeyCode.return_key => return emit(&result, "\r"),
        KeyCode.tab => return emit(&result, "\t"),
        KeyCode.escape => return emit(&result, "\x1b"),
        KeyCode.delete => return emit(&result, "\x7f"), // backspace
        KeyCode.forward_delete => {
            if (has_mod) return emitModifiedSpecial(&result, "3", mod_param)
            else return emit(&result, "\x1b[3~");
        },

        // Arrow keys
        KeyCode.up_arrow => return emitArrow(&result, 'A', has_mod, mod_param, app_cursor_mode),
        KeyCode.down_arrow => return emitArrow(&result, 'B', has_mod, mod_param, app_cursor_mode),
        KeyCode.right_arrow => return emitArrow(&result, 'C', has_mod, mod_param, app_cursor_mode),
        KeyCode.left_arrow => return emitArrow(&result, 'D', has_mod, mod_param, app_cursor_mode),

        // Navigation
        KeyCode.home => {
            if (has_mod) return emitModifiedSpecial(&result, "1", mod_param)
            else return emit(&result, "\x1b[H");
        },
        KeyCode.end => {
            if (has_mod) return emitModifiedSpecial(&result, "4", mod_param)
            else return emit(&result, "\x1b[F");
        },
        KeyCode.page_up => {
            if (has_mod) return emitModifiedSpecial(&result, "5", mod_param)
            else return emit(&result, "\x1b[5~");
        },
        KeyCode.page_down => {
            if (has_mod) return emitModifiedSpecial(&result, "6", mod_param)
            else return emit(&result, "\x1b[6~");
        },

        // Function keys
        KeyCode.f1 => return emitFKey(&result, "OP", has_mod, mod_param),
        KeyCode.f2 => return emitFKey(&result, "OQ", has_mod, mod_param),
        KeyCode.f3 => return emitFKey(&result, "OR", has_mod, mod_param),
        KeyCode.f4 => return emitFKey(&result, "OS", has_mod, mod_param),
        KeyCode.f5 => return emitFKeyTilde(&result, "15", has_mod, mod_param),
        KeyCode.f6 => return emitFKeyTilde(&result, "17", has_mod, mod_param),
        KeyCode.f7 => return emitFKeyTilde(&result, "18", has_mod, mod_param),
        KeyCode.f8 => return emitFKeyTilde(&result, "19", has_mod, mod_param),
        KeyCode.f9 => return emitFKeyTilde(&result, "20", has_mod, mod_param),
        KeyCode.f10 => return emitFKeyTilde(&result, "21", has_mod, mod_param),
        KeyCode.f11 => return emitFKeyTilde(&result, "23", has_mod, mod_param),
        KeyCode.f12 => return emitFKeyTilde(&result, "24", has_mod, mod_param),

        else => {},
    }

    // Ctrl+letter (A-Z)
    if (ctrl and characters.len == 1) {
        const ch = characters[0];
        if (ch >= 'a' and ch <= 'z') {
            return emit(&result, &[_]u8{ch - 'a' + 1});
        }
        if (ch >= 'A' and ch <= 'Z') {
            return emit(&result, &[_]u8{ch - 'A' + 1});
        }
        // Ctrl+[ = ESC, Ctrl+\ = 0x1C, Ctrl+] = 0x1D, etc.
        switch (ch) {
            '[' => return emit(&result, "\x1b"),
            '\\' => return emit(&result, "\x1c"),
            ']' => return emit(&result, "\x1d"),
            '^' => return emit(&result, "\x1e"),
            '_' => return emit(&result, "\x1f"),
            '@' => return emit(&result, "\x00"),
            else => {},
        }
    }

    // Alt+key: send ESC prefix + key
    if (alt and characters.len > 0) {
        result.data[0] = 0x1b;
        const copy_len = @min(characters.len, result.data.len - 1);
        @memcpy(result.data[1..][0..copy_len], characters[0..copy_len]);
        result.len = @intCast(1 + copy_len);
        return result;
    }

    // Normal printable characters
    if (characters.len > 0 and characters.len < result.data.len) {
        @memcpy(result.data[0..characters.len], characters);
        result.len = @intCast(characters.len);
        return result;
    }

    return null;
}

// ── Helpers ─────────────────────────────────────────────────────────

fn emit(result: *EncodeResult, data: []const u8) EncodeResult {
    @memcpy(result.data[0..data.len], data);
    result.len = @intCast(data.len);
    return result.*;
}

fn emitArrow(result: *EncodeResult, dir: u8, has_mod: bool, mod: u8, app_cursor: bool) EncodeResult {
    if (has_mod) {
        // ESC[1;{mod}A
        const s = std.fmt.bufPrint(&result.data, "\x1b[1;{d}{c}", .{ mod, dir }) catch return result.*;
        result.len = @intCast(s.len);
    } else if (app_cursor) {
        result.data[0] = 0x1b;
        result.data[1] = 'O';
        result.data[2] = dir;
        result.len = 3;
    } else {
        result.data[0] = 0x1b;
        result.data[1] = '[';
        result.data[2] = dir;
        result.len = 3;
    }
    return result.*;
}

fn emitModifiedSpecial(result: *EncodeResult, code: []const u8, mod: u8) EncodeResult {
    const s = std.fmt.bufPrint(&result.data, "\x1b[{s};{d}~", .{ code, mod }) catch return result.*;
    result.len = @intCast(s.len);
    return result.*;
}

fn emitFKey(result: *EncodeResult, base: []const u8, has_mod: bool, mod: u8) EncodeResult {
    if (has_mod) {
        // F1-F4 with modifiers: ESC[1;{mod}P/Q/R/S
        const final = base[base.len - 1];
        const s = std.fmt.bufPrint(&result.data, "\x1b[1;{d}{c}", .{ mod, final }) catch return result.*;
        result.len = @intCast(s.len);
    } else {
        result.data[0] = 0x1b;
        @memcpy(result.data[1..][0..base.len], base);
        result.len = @intCast(1 + base.len);
    }
    return result.*;
}

fn emitFKeyTilde(result: *EncodeResult, code: []const u8, has_mod: bool, mod: u8) EncodeResult {
    if (has_mod) {
        const s = std.fmt.bufPrint(&result.data, "\x1b[{s};{d}~", .{ code, mod }) catch return result.*;
        result.len = @intCast(s.len);
    } else {
        const s = std.fmt.bufPrint(&result.data, "\x1b[{s}~", .{code}) catch return result.*;
        result.len = @intCast(s.len);
    }
    return result.*;
}

// ── Tests ───────────────────────────────────────────────────────────

test "encode printable character" {
    const result = encodeKey(0, "a", 0, false);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("a", result.?.bytes());
}

test "encode return key" {
    const result = encodeKey(KeyCode.return_key, "", 0, false);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("\r", result.?.bytes());
}

test "encode arrow keys" {
    const up = encodeKey(KeyCode.up_arrow, "", 0, false);
    try std.testing.expectEqualStrings("\x1b[A", up.?.bytes());

    // App cursor mode
    const up_app = encodeKey(KeyCode.up_arrow, "", 0, true);
    try std.testing.expectEqualStrings("\x1bOA", up_app.?.bytes());
}

test "encode ctrl+c" {
    const result = encodeKey(0, "c", ModifierFlags.control, false);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("\x03", result.?.bytes());
}

test "encode alt+d" {
    const result = encodeKey(0, "d", ModifierFlags.option, false);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("\x1bd", result.?.bytes());
}

test "encode shift+up arrow" {
    const result = encodeKey(KeyCode.up_arrow, "", ModifierFlags.shift, false);
    try std.testing.expectEqualStrings("\x1b[1;2A", result.?.bytes());
}

test "encode F5" {
    const result = encodeKey(KeyCode.f5, "", 0, false);
    try std.testing.expectEqualStrings("\x1b[15~", result.?.bytes());
}
