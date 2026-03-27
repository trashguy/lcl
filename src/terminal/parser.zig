/// VT100/xterm terminal parser.
/// Paul Williams state machine with comptime-generated transition tables.
/// Processes byte streams and updates a CellGrid.

const std = @import("std");
const cell = @import("cell");
const CellGrid = cell.CellGrid;
const Color = cell.Color;
const Attrs = cell.Attrs;

// ── State machine ───────────────────────────────────────────────────

const State = enum(u4) {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    osc_string,
};

const max_params = 16;
const max_osc = 256;

pub const Parser = struct {
    grid: *CellGrid,

    state: State = .ground,
    params: [max_params]u16 = [_]u16{0} ** max_params,
    param_count: u8 = 0,
    private_marker: u8 = 0, // '?' or '>' or 0
    intermediate: u8 = 0,

    // OSC accumulation
    osc_buf: [max_osc]u8 = undefined,
    osc_len: u16 = 0,

    // Callbacks
    title_callback: ?*const fn ([]const u8) void = null,
    response_writer: ?std.posix.fd_t = null, // for DSR responses

    /// Feed a byte stream from the PTY into the parser.
    pub fn feed(self: *Parser, data: []const u8) void {
        for (data) |byte| {
            self.processByte(byte);
        }
    }

    fn processByte(self: *Parser, byte: u8) void {
        // C0 controls are handled in most states
        if (byte < 0x20 and self.state != .osc_string) {
            switch (byte) {
                0x00 => {}, // NUL — ignore
                0x07 => {}, // BEL
                0x08 => self.grid.moveCursorBack(1), // BS
                0x09 => self.handleTab(), // HT
                0x0A, 0x0B, 0x0C => self.lineFeed(), // LF, VT, FF
                0x0D => { // CR
                    self.grid.cursor_col = 0;
                    self.grid.wrap_pending = false;
                },
                0x1B => { // ESC
                    self.state = .escape;
                    self.private_marker = 0;
                    self.intermediate = 0;
                },
                else => {},
            }
            return;
        }

        switch (self.state) {
            .ground => self.stateGround(byte),
            .escape => self.stateEscape(byte),
            .escape_intermediate => self.stateEscapeIntermediate(byte),
            .csi_entry => self.stateCsiEntry(byte),
            .csi_param => self.stateCsiParam(byte),
            .csi_intermediate => self.stateCsiIntermediate(byte),
            .csi_ignore => self.stateCsiIgnore(byte),
            .osc_string => self.stateOscString(byte),
        }
    }

    // ── State handlers ──────────────────────────────────────────────

    fn stateGround(self: *Parser, byte: u8) void {
        if (byte >= 0x20) {
            // Printable character (or start of UTF-8)
            // For now, treat as single-byte. UTF-8 multi-byte can come later.
            self.grid.putChar(@intCast(byte));
        }
    }

    fn stateEscape(self: *Parser, byte: u8) void {
        switch (byte) {
            '[' => {
                self.state = .csi_entry;
                self.params = [_]u16{0} ** max_params;
                self.param_count = 0;
                self.private_marker = 0;
                self.intermediate = 0;
            },
            ']' => {
                self.state = .osc_string;
                self.osc_len = 0;
            },
            '7' => { // DECSC — save cursor
                self.grid.saveCursor();
                self.state = .ground;
            },
            '8' => { // DECRC — restore cursor
                self.grid.restoreCursor();
                self.state = .ground;
            },
            'D' => { // IND — index (scroll up)
                if (self.grid.cursor_row == self.grid.scroll_bottom) {
                    self.grid.scrollUp(1);
                } else if (self.grid.cursor_row < self.grid.rows - 1) {
                    self.grid.cursor_row += 1;
                }
                self.state = .ground;
            },
            'M' => { // RI — reverse index (scroll down)
                if (self.grid.cursor_row == self.grid.scroll_top) {
                    self.grid.scrollDown(1);
                } else if (self.grid.cursor_row > 0) {
                    self.grid.cursor_row -= 1;
                }
                self.state = .ground;
            },
            'c' => { // RIS — full reset
                self.grid.reset();
                self.state = .ground;
            },
            '(' , ')' , '*', '+' => { // Charset designation — collect and ignore
                self.state = .escape_intermediate;
            },
            else => {
                self.state = .ground;
            },
        }
    }

    fn stateEscapeIntermediate(self: *Parser, _: u8) void {
        // Consume one byte after ESC ( / ) etc., then back to ground
        self.state = .ground;
    }

    fn stateCsiEntry(self: *Parser, byte: u8) void {
        if (byte == '?' or byte == '>' or byte == '!') {
            self.private_marker = byte;
            self.state = .csi_param;
        } else if (byte >= '0' and byte <= '9') {
            self.params[0] = byte - '0';
            self.param_count = 1;
            self.state = .csi_param;
        } else if (byte == ';') {
            self.param_count = 2; // first param is 0 (default)
            self.state = .csi_param;
        } else if (byte >= 0x40 and byte <= 0x7E) {
            // Final character with no params
            self.param_count = 0;
            self.dispatchCsi(byte);
        } else if (byte >= 0x20 and byte <= 0x2F) {
            self.intermediate = byte;
            self.state = .csi_intermediate;
        } else {
            self.state = .csi_ignore;
        }
    }

    fn stateCsiParam(self: *Parser, byte: u8) void {
        if (byte >= '0' and byte <= '9') {
            const idx: usize = if (self.param_count == 0) 0 else self.param_count - 1;
            if (idx < max_params) {
                self.params[idx] = self.params[idx] *| 10 +| (byte - '0');
            }
            if (self.param_count == 0) self.param_count = 1;
        } else if (byte == ';') {
            if (self.param_count == 0) self.param_count = 1;
            if (self.param_count < max_params) {
                self.param_count += 1;
                self.params[self.param_count - 1] = 0;
            }
        } else if (byte >= 0x40 and byte <= 0x7E) {
            self.dispatchCsi(byte);
        } else if (byte >= 0x20 and byte <= 0x2F) {
            self.intermediate = byte;
            self.state = .csi_intermediate;
        } else {
            self.state = .csi_ignore;
        }
    }

    fn stateCsiIntermediate(self: *Parser, byte: u8) void {
        if (byte >= 0x40 and byte <= 0x7E) {
            self.dispatchCsi(byte);
        } else if (byte < 0x20 or byte > 0x2F) {
            self.state = .csi_ignore;
        }
    }

    fn stateCsiIgnore(self: *Parser, byte: u8) void {
        if (byte >= 0x40 and byte <= 0x7E) {
            self.state = .ground;
        }
    }

    fn stateOscString(self: *Parser, byte: u8) void {
        if (byte == 0x07 or byte == 0x9C) {
            // BEL or ST — end of OSC
            self.dispatchOsc();
            self.state = .ground;
        } else if (byte == 0x1B) {
            // Might be ESC \ (ST). For simplicity, end OSC on ESC.
            self.dispatchOsc();
            self.state = .escape;
        } else {
            if (self.osc_len < max_osc) {
                self.osc_buf[self.osc_len] = byte;
                self.osc_len += 1;
            }
        }
    }

    // ── CSI dispatch ────────────────────────────────────────────────

    fn param(self: *const Parser, idx: usize, default: u16) u16 {
        if (idx >= self.param_count) return default;
        const val = self.params[idx];
        return if (val == 0) default else val;
    }

    fn dispatchCsi(self: *Parser, final: u8) void {
        if (self.private_marker == '?') {
            self.dispatchDecPrivate(final);
            self.state = .ground;
            return;
        }

        switch (final) {
            'A' => self.grid.moveCursorUp(self.param(0, 1)),
            'B' => self.grid.moveCursorDown(self.param(0, 1)),
            'C' => self.grid.moveCursorForward(self.param(0, 1)),
            'D' => self.grid.moveCursorBack(self.param(0, 1)),
            'E' => { // CNL — cursor next line
                self.grid.moveCursorDown(self.param(0, 1));
                self.grid.cursor_col = 0;
            },
            'F' => { // CPL — cursor previous line
                self.grid.moveCursorUp(self.param(0, 1));
                self.grid.cursor_col = 0;
            },
            'G' => { // CHA — cursor character absolute
                self.grid.cursor_col = @min(self.param(0, 1) -| 1, self.grid.cols - 1);
                self.grid.wrap_pending = false;
            },
            'H', 'f' => { // CUP — cursor position
                self.grid.setCursorPos(
                    self.param(0, 1) -| 1,
                    self.param(1, 1) -| 1,
                );
            },
            'J' => self.grid.eraseInDisplay(self.param(0, 0)),
            'K' => self.grid.eraseInLine(self.param(0, 0)),
            'L' => self.grid.insertLines(self.param(0, 1)),
            'M' => self.grid.deleteLines(self.param(0, 1)),
            'P' => self.grid.deleteChars(self.param(0, 1)),
            'S' => self.grid.scrollUp(self.param(0, 1)),
            'T' => self.grid.scrollDown(self.param(0, 1)),
            'X' => self.grid.eraseChars(self.param(0, 1)),
            '@' => self.grid.insertChars(self.param(0, 1)),
            'd' => { // VPA — line position absolute
                self.grid.cursor_row = @min(self.param(0, 1) -| 1, self.grid.rows - 1);
                self.grid.wrap_pending = false;
            },
            'm' => self.handleSgr(),
            'n' => { // DSR — device status report
                if (self.param(0, 0) == 6) {
                    self.reportCursorPosition();
                }
            },
            'r' => { // DECSTBM — set scroll region
                const top = self.param(0, 1) -| 1;
                const bottom = self.param(1, self.grid.rows) -| 1;
                if (top < bottom and bottom < self.grid.rows) {
                    self.grid.scroll_top = @intCast(top);
                    self.grid.scroll_bottom = @intCast(bottom);
                    self.grid.setCursorPos(0, 0);
                }
            },
            else => {}, // Unhandled CSI
        }
        self.state = .ground;
    }

    fn dispatchDecPrivate(self: *Parser, final: u8) void {
        const mode = self.param(0, 0);
        const enable = (final == 'h');

        switch (mode) {
            1 => self.grid.app_cursor_keys = enable,
            7 => self.grid.auto_wrap = enable,
            25 => self.grid.cursor_visible = enable,
            47, 1047 => {
                if (enable) self.grid.switchToAltScreen() catch {} else self.grid.switchToMainScreen();
            },
            1049 => {
                if (enable) {
                    self.grid.saveCursor();
                    self.grid.switchToAltScreen() catch {};
                } else {
                    self.grid.switchToMainScreen();
                    self.grid.restoreCursor();
                }
            },
            2004 => self.grid.bracketed_paste = enable,
            else => {},
        }
    }

    // ── SGR (Select Graphic Rendition) ──────────────────────────────

    fn handleSgr(self: *Parser) void {
        if (self.param_count == 0) {
            self.resetPen();
            return;
        }

        var i: usize = 0;
        while (i < self.param_count) : (i += 1) {
            const p = self.params[i];
            switch (p) {
                0 => self.resetPen(),
                1 => self.grid.pen_attrs.bold = true,
                2 => self.grid.pen_attrs.dim = true,
                3 => self.grid.pen_attrs.italic = true,
                4 => self.grid.pen_attrs.underline = true,
                5 => self.grid.pen_attrs.blink = true,
                7 => self.grid.pen_attrs.reverse = true,
                8 => self.grid.pen_attrs.invisible = true,
                9 => self.grid.pen_attrs.strikethrough = true,
                22 => {
                    self.grid.pen_attrs.bold = false;
                    self.grid.pen_attrs.dim = false;
                },
                23 => self.grid.pen_attrs.italic = false,
                24 => self.grid.pen_attrs.underline = false,
                25 => self.grid.pen_attrs.blink = false,
                27 => self.grid.pen_attrs.reverse = false,
                28 => self.grid.pen_attrs.invisible = false,
                29 => self.grid.pen_attrs.strikethrough = false,
                30...37 => self.grid.pen_fg = .{ .palette = @intCast(p - 30) },
                38 => {
                    i += 1;
                    if (i < self.param_count) {
                        if (self.params[i] == 5 and i + 1 < self.param_count) {
                            // 256-color: 38;5;N
                            i += 1;
                            self.grid.pen_fg = .{ .palette = @intCast(self.params[i]) };
                        } else if (self.params[i] == 2 and i + 3 < self.param_count) {
                            // Truecolor: 38;2;R;G;B
                            self.grid.pen_fg = .{ .rgb = .{
                                .r = @intCast(self.params[i + 1]),
                                .g = @intCast(self.params[i + 2]),
                                .b = @intCast(self.params[i + 3]),
                            } };
                            i += 3;
                        }
                    }
                },
                39 => self.grid.pen_fg = .default,
                40...47 => self.grid.pen_bg = .{ .palette = @intCast(p - 40) },
                48 => {
                    i += 1;
                    if (i < self.param_count) {
                        if (self.params[i] == 5 and i + 1 < self.param_count) {
                            i += 1;
                            self.grid.pen_bg = .{ .palette = @intCast(self.params[i]) };
                        } else if (self.params[i] == 2 and i + 3 < self.param_count) {
                            self.grid.pen_bg = .{ .rgb = .{
                                .r = @intCast(self.params[i + 1]),
                                .g = @intCast(self.params[i + 2]),
                                .b = @intCast(self.params[i + 3]),
                            } };
                            i += 3;
                        }
                    }
                },
                49 => self.grid.pen_bg = .default,
                90...97 => self.grid.pen_fg = .{ .palette = @intCast(p - 90 + 8) },
                100...107 => self.grid.pen_bg = .{ .palette = @intCast(p - 100 + 8) },
                else => {},
            }
        }
    }

    fn resetPen(self: *Parser) void {
        self.grid.pen_fg = .default;
        self.grid.pen_bg = .default;
        self.grid.pen_attrs = .{};
    }

    // ── OSC dispatch ────────────────────────────────────────────────

    fn dispatchOsc(self: *Parser) void {
        const data = self.osc_buf[0..self.osc_len];
        // OSC format: Ps ; Pt
        if (std.mem.indexOfScalar(u8, data, ';')) |sep| {
            const ps = std.fmt.parseInt(u8, data[0..sep], 10) catch return;
            const pt = data[sep + 1 ..];
            switch (ps) {
                0, 1, 2 => {
                    // Set window title
                    const len = @min(pt.len, self.grid.title.len);
                    @memcpy(self.grid.title[0..len], pt[0..len]);
                    self.grid.title_len = @intCast(len);
                    if (self.title_callback) |cb| cb(pt);
                },
                else => {},
            }
        }
    }

    // ── DSR response ────────────────────────────────────────────────

    fn reportCursorPosition(self: *Parser) void {
        if (self.response_writer) |fd| {
            var buf: [32]u8 = undefined;
            const response = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                self.grid.cursor_row + 1,
                self.grid.cursor_col + 1,
            }) catch return;
            _ = std.posix.write(fd, response) catch {};
        }
    }

    // ── Tab ─────────────────────────────────────────────────────────

    fn handleTab(self: *Parser) void {
        // Move to next tab stop (every 8 columns)
        const next = (self.grid.cursor_col / 8 + 1) * 8;
        self.grid.cursor_col = @min(next, self.grid.cols - 1);
        self.grid.wrap_pending = false;
    }

    fn lineFeed(self: *Parser) void {
        if (self.grid.cursor_row == self.grid.scroll_bottom) {
            self.grid.scrollUp(1);
        } else if (self.grid.cursor_row < self.grid.rows - 1) {
            self.grid.cursor_row += 1;
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "parser: basic text output" {
    var grid = try CellGrid.init(std.testing.allocator, 80, 24);
    defer grid.deinit();
    var parser = Parser{ .grid = &grid };

    parser.feed("Hello");

    try std.testing.expectEqual(@as(u21, 'H'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), grid.cellAtConst(0, 4).char);
    try std.testing.expectEqual(@as(u16, 5), grid.cursor_col);
}

test "parser: cursor movement CSI" {
    var grid = try CellGrid.init(std.testing.allocator, 80, 24);
    defer grid.deinit();
    var parser = Parser{ .grid = &grid };

    // Move cursor to row 5, col 10 (1-indexed)
    parser.feed("\x1b[5;10H");
    try std.testing.expectEqual(@as(u16, 4), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 9), grid.cursor_col);

    // Move up 2
    parser.feed("\x1b[2A");
    try std.testing.expectEqual(@as(u16, 2), grid.cursor_row);
}

test "parser: SGR colors" {
    var grid = try CellGrid.init(std.testing.allocator, 80, 24);
    defer grid.deinit();
    var parser = Parser{ .grid = &grid };

    // Set red foreground (31) and bold (1)
    parser.feed("\x1b[1;31m");
    try std.testing.expect(grid.pen_attrs.bold);
    try std.testing.expect(grid.pen_fg.eql(.{ .palette = 1 }));

    // Write a char with these attributes
    parser.feed("X");
    try std.testing.expect(grid.cellAtConst(0, 0).attrs.bold);
    try std.testing.expect(grid.cellAtConst(0, 0).fg.eql(.{ .palette = 1 }));

    // Reset
    parser.feed("\x1b[0m");
    try std.testing.expect(!grid.pen_attrs.bold);
    try std.testing.expect(grid.pen_fg.eql(.default));
}

test "parser: 256-color" {
    var grid = try CellGrid.init(std.testing.allocator, 80, 24);
    defer grid.deinit();
    var parser = Parser{ .grid = &grid };

    parser.feed("\x1b[38;5;196m"); // bright red (256-color index 196)
    try std.testing.expect(grid.pen_fg.eql(.{ .palette = 196 }));
}

test "parser: truecolor" {
    var grid = try CellGrid.init(std.testing.allocator, 80, 24);
    defer grid.deinit();
    var parser = Parser{ .grid = &grid };

    parser.feed("\x1b[38;2;255;128;0m"); // orange RGB
    try std.testing.expect(grid.pen_fg.eql(.{ .rgb = .{ .r = 255, .g = 128, .b = 0 } }));
}

test "parser: erase in display" {
    var grid = try CellGrid.init(std.testing.allocator, 10, 3);
    defer grid.deinit();
    var parser = Parser{ .grid = &grid };

    parser.feed("ABCDEFGHIJ"); // fill row 0
    parser.feed("\x1b[2J"); // erase all
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char);
}

test "parser: scroll region" {
    var grid = try CellGrid.init(std.testing.allocator, 10, 5);
    defer grid.deinit();
    var parser = Parser{ .grid = &grid };

    // Set scroll region to rows 2-4 (1-indexed)
    parser.feed("\x1b[2;4r");
    try std.testing.expectEqual(@as(u16, 1), grid.scroll_top);
    try std.testing.expectEqual(@as(u16, 3), grid.scroll_bottom);
}

test "parser: DEC private mode - alt screen" {
    var grid = try CellGrid.init(std.testing.allocator, 10, 3);
    defer grid.deinit();
    var parser = Parser{ .grid = &grid };

    parser.feed("Main");
    try std.testing.expect(!grid.in_alt_screen);

    parser.feed("\x1b[?1049h"); // switch to alt screen
    try std.testing.expect(grid.in_alt_screen);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char); // alt screen is clear

    parser.feed("\x1b[?1049l"); // switch back
    try std.testing.expect(!grid.in_alt_screen);
    try std.testing.expectEqual(@as(u21, 'M'), grid.cellAtConst(0, 0).char); // main screen preserved
}

test "parser: OSC title" {
    var grid = try CellGrid.init(std.testing.allocator, 80, 24);
    defer grid.deinit();
    var parser = Parser{ .grid = &grid };

    parser.feed("\x1b]0;My Terminal\x07");
    try std.testing.expectEqualStrings("My Terminal", grid.title[0..grid.title_len]);
}

test "parser: CR LF" {
    var grid = try CellGrid.init(std.testing.allocator, 80, 24);
    defer grid.deinit();
    var parser = Parser{ .grid = &grid };

    parser.feed("Line1\r\nLine2");
    try std.testing.expectEqual(@as(u21, 'L'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'L'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_row);
}
