/// Terminal cell grid — the in-memory representation of the terminal screen.
/// Each cell holds a character, foreground/background color, and text attributes.

const std = @import("std");

// ── Color ───────────────────────────────────────────────────────────

pub const Color = union(enum) {
    default, // terminal default fg or bg
    palette: u8, // 0-255 (ANSI 16 + 216 cube + 24 gray)
    rgb: struct { r: u8, g: u8, b: u8 },

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .palette => |ap| switch (b) {
                .palette => |bp| ap == bp,
                else => false,
            },
            .rgb => |ar| switch (b) {
                .rgb => |br| ar.r == br.r and ar.g == br.g and ar.b == br.b,
                else => false,
            },
        };
    }
};

// ── Attributes ──────────────────────────────────────────────────────

pub const Attrs = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
};

// ── Cell ────────────────────────────────────────────────────────────

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},
    dirty: bool = true,
};

// ── Cursor state (for save/restore) ─────────────────────────────────

pub const CursorState = struct {
    row: u16,
    col: u16,
    fg: Color,
    bg: Color,
    attrs: Attrs,
};

// ── Cell Grid ───────────────────────────────────────────────────────

pub const CellGrid = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    cols: u16,
    rows: u16,

    // Cursor
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_visible: bool = true,

    // Scroll region (inclusive)
    scroll_top: u16 = 0,
    scroll_bottom: u16,

    // Current pen
    pen_fg: Color = .default,
    pen_bg: Color = .default,
    pen_attrs: Attrs = .{},

    // Saved cursor
    saved_cursor: ?CursorState = null,

    // Alternate screen
    alt_cells: ?[]Cell = null,
    in_alt_screen: bool = false,

    // Modes
    auto_wrap: bool = true,
    origin_mode: bool = false,
    app_cursor_keys: bool = false,
    bracketed_paste: bool = false,

    // Wrap pending: cursor at right margin, next printable wraps
    wrap_pending: bool = false,

    // Title
    title: [256]u8 = undefined,
    title_len: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !CellGrid {
        const size = @as(usize, cols) * @as(usize, rows);
        const cells = try allocator.alloc(Cell, size);
        for (cells) |*c| c.* = .{};
        return .{
            .allocator = allocator,
            .cells = cells,
            .cols = cols,
            .rows = rows,
            .scroll_bottom = rows - 1,
        };
    }

    pub fn deinit(self: *CellGrid) void {
        self.allocator.free(self.cells);
        if (self.alt_cells) |ac| self.allocator.free(ac);
    }

    pub fn cellAt(self: *CellGrid, row: u16, col: u16) *Cell {
        return &self.cells[@as(usize, row) * self.cols + col];
    }

    pub fn cellAtConst(self: *const CellGrid, row: u16, col: u16) *const Cell {
        return &self.cells[@as(usize, row) * self.cols + col];
    }

    // ── Character output ────────────────────────────────────────────

    pub fn putChar(self: *CellGrid, codepoint: u21) void {
        if (self.wrap_pending) {
            self.wrap_pending = false;
            self.cursor_col = 0;
            if (self.cursor_row == self.scroll_bottom) {
                self.scrollUp(1);
            } else if (self.cursor_row < self.rows - 1) {
                self.cursor_row += 1;
            }
        }

        if (self.cursor_col < self.cols and self.cursor_row < self.rows) {
            const cell = self.cellAt(self.cursor_row, self.cursor_col);
            cell.char = codepoint;
            cell.fg = self.pen_fg;
            cell.bg = self.pen_bg;
            cell.attrs = self.pen_attrs;
            cell.dirty = true;
        }

        if (self.cursor_col < self.cols - 1) {
            self.cursor_col += 1;
        } else if (self.auto_wrap) {
            self.wrap_pending = true;
        }
    }

    // ── Scrolling ───────────────────────────────────────────────────

    pub fn scrollUp(self: *CellGrid, count: u16) void {
        const n = @min(count, self.scroll_bottom - self.scroll_top + 1);
        if (n == 0) return;

        // Move lines up
        var row = self.scroll_top;
        while (row + n <= self.scroll_bottom) : (row += 1) {
            const dst_start = @as(usize, row) * self.cols;
            const src_start = @as(usize, row + n) * self.cols;
            @memcpy(self.cells[dst_start..][0..self.cols], self.cells[src_start..][0..self.cols]);
        }

        // Clear bottom lines
        while (row <= self.scroll_bottom) : (row += 1) {
            self.clearRow(row);
        }
        self.markAllDirty();
    }

    pub fn scrollDown(self: *CellGrid, count: u16) void {
        const n = @min(count, self.scroll_bottom - self.scroll_top + 1);
        if (n == 0) return;

        var row = self.scroll_bottom;
        while (row >= self.scroll_top + n) : (row -= 1) {
            const dst_start = @as(usize, row) * self.cols;
            const src_start = @as(usize, row - n) * self.cols;
            @memcpy(self.cells[dst_start..][0..self.cols], self.cells[src_start..][0..self.cols]);
            if (row == self.scroll_top + n) break;
        }

        row = self.scroll_top;
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            self.clearRow(row + i);
        }
        self.markAllDirty();
    }

    // ── Erase operations ────────────────────────────────────────────

    /// ED - Erase in Display. mode: 0=below, 1=above, 2=all, 3=all+scrollback
    pub fn eraseInDisplay(self: *CellGrid, mode: u16) void {
        switch (mode) {
            0 => {
                // Erase from cursor to end
                self.eraseInLine(0);
                var row = self.cursor_row + 1;
                while (row < self.rows) : (row += 1) self.clearRow(row);
            },
            1 => {
                // Erase from start to cursor
                self.eraseInLine(1);
                var row: u16 = 0;
                while (row < self.cursor_row) : (row += 1) self.clearRow(row);
            },
            2, 3 => {
                // Erase all
                var row: u16 = 0;
                while (row < self.rows) : (row += 1) self.clearRow(row);
            },
            else => {},
        }
    }

    /// EL - Erase in Line. mode: 0=right, 1=left, 2=all
    pub fn eraseInLine(self: *CellGrid, mode: u16) void {
        const row = self.cursor_row;
        switch (mode) {
            0 => {
                var col = self.cursor_col;
                while (col < self.cols) : (col += 1) self.clearCell(row, col);
            },
            1 => {
                var col: u16 = 0;
                while (col <= self.cursor_col) : (col += 1) self.clearCell(row, col);
            },
            2 => self.clearRow(row),
            else => {},
        }
    }

    // ── Cursor movement ─────────────────────────────────────────────

    pub fn setCursorPos(self: *CellGrid, row: u16, col: u16) void {
        self.cursor_row = @min(row, self.rows - 1);
        self.cursor_col = @min(col, self.cols - 1);
        self.wrap_pending = false;
    }

    pub fn moveCursorUp(self: *CellGrid, n: u16) void {
        self.cursor_row -|= n;
        self.wrap_pending = false;
    }

    pub fn moveCursorDown(self: *CellGrid, n: u16) void {
        self.cursor_row = @min(self.cursor_row + n, self.rows - 1);
        self.wrap_pending = false;
    }

    pub fn moveCursorForward(self: *CellGrid, n: u16) void {
        self.cursor_col = @min(self.cursor_col + n, self.cols - 1);
        self.wrap_pending = false;
    }

    pub fn moveCursorBack(self: *CellGrid, n: u16) void {
        self.cursor_col -|= n;
        self.wrap_pending = false;
    }

    // ── Line operations ─────────────────────────────────────────────

    pub fn insertLines(self: *CellGrid, count: u16) void {
        if (self.cursor_row < self.scroll_top or self.cursor_row > self.scroll_bottom) return;
        const saved_top = self.scroll_top;
        self.scroll_top = self.cursor_row;
        self.scrollDown(count);
        self.scroll_top = saved_top;
    }

    pub fn deleteLines(self: *CellGrid, count: u16) void {
        if (self.cursor_row < self.scroll_top or self.cursor_row > self.scroll_bottom) return;
        const saved_top = self.scroll_top;
        self.scroll_top = self.cursor_row;
        self.scrollUp(count);
        self.scroll_top = saved_top;
    }

    pub fn insertChars(self: *CellGrid, count: u16) void {
        const row = self.cursor_row;
        const n = @min(count, self.cols - self.cursor_col);
        // Shift right
        var col = self.cols - 1;
        while (col >= self.cursor_col + n) : (col -= 1) {
            self.cells[@as(usize, row) * self.cols + col] =
                self.cells[@as(usize, row) * self.cols + col - n];
            if (col == self.cursor_col + n) break;
        }
        // Clear inserted
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            self.clearCell(row, self.cursor_col + i);
        }
    }

    pub fn deleteChars(self: *CellGrid, count: u16) void {
        const row = self.cursor_row;
        const n = @min(count, self.cols - self.cursor_col);
        // Shift left
        var col = self.cursor_col;
        while (col + n < self.cols) : (col += 1) {
            self.cells[@as(usize, row) * self.cols + col] =
                self.cells[@as(usize, row) * self.cols + col + n];
        }
        // Clear end
        while (col < self.cols) : (col += 1) {
            self.clearCell(row, col);
        }
    }

    pub fn eraseChars(self: *CellGrid, count: u16) void {
        const n = @min(count, self.cols - self.cursor_col);
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            self.clearCell(self.cursor_row, self.cursor_col + i);
        }
    }

    // ── Alternate screen ────────────────────────────────────────────

    pub fn switchToAltScreen(self: *CellGrid) !void {
        if (self.in_alt_screen) return;
        const size = @as(usize, self.cols) * @as(usize, self.rows);
        self.alt_cells = try self.allocator.alloc(Cell, size);
        // Swap
        const tmp = self.cells;
        self.cells = self.alt_cells.?;
        self.alt_cells = tmp;
        // Clear alt screen
        for (self.cells) |*c| c.* = .{};
        self.in_alt_screen = true;
    }

    pub fn switchToMainScreen(self: *CellGrid) void {
        if (!self.in_alt_screen) return;
        if (self.alt_cells) |ac| {
            const tmp = self.cells;
            self.cells = ac;
            self.alt_cells = null;
            self.allocator.free(tmp);
        }
        self.in_alt_screen = false;
        self.markAllDirty();
    }

    // ── Save / restore cursor ───────────────────────────────────────

    pub fn saveCursor(self: *CellGrid) void {
        self.saved_cursor = .{
            .row = self.cursor_row,
            .col = self.cursor_col,
            .fg = self.pen_fg,
            .bg = self.pen_bg,
            .attrs = self.pen_attrs,
        };
    }

    pub fn restoreCursor(self: *CellGrid) void {
        if (self.saved_cursor) |sc| {
            self.cursor_row = @min(sc.row, self.rows - 1);
            self.cursor_col = @min(sc.col, self.cols - 1);
            self.pen_fg = sc.fg;
            self.pen_bg = sc.bg;
            self.pen_attrs = sc.attrs;
            self.wrap_pending = false;
        }
    }

    // ── Dirty tracking ──────────────────────────────────────────────

    pub fn markAllDirty(self: *CellGrid) void {
        for (self.cells) |*c| c.dirty = true;
    }

    pub fn clearAllDirty(self: *CellGrid) void {
        for (self.cells) |*c| c.dirty = false;
    }

    // ── Helpers ─────────────────────────────────────────────────────

    fn clearRow(self: *CellGrid, row: u16) void {
        var col: u16 = 0;
        while (col < self.cols) : (col += 1) self.clearCell(row, col);
    }

    fn clearCell(self: *CellGrid, row: u16, col: u16) void {
        const cell = self.cellAt(row, col);
        cell.* = .{
            .bg = self.pen_bg,
            .dirty = true,
        };
    }

    /// Perform a full reset (RIS).
    pub fn reset(self: *CellGrid) void {
        if (self.in_alt_screen) self.switchToMainScreen();
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.cursor_visible = true;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.pen_fg = .default;
        self.pen_bg = .default;
        self.pen_attrs = .{};
        self.saved_cursor = null;
        self.auto_wrap = true;
        self.origin_mode = false;
        self.app_cursor_keys = false;
        self.bracketed_paste = false;
        self.wrap_pending = false;
        for (self.cells) |*c| c.* = .{};
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "grid init and putChar" {
    var grid = try CellGrid.init(std.testing.allocator, 80, 24);
    defer grid.deinit();

    grid.putChar('H');
    grid.putChar('i');

    try std.testing.expectEqual(@as(u21, 'H'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u16, 2), grid.cursor_col);
}

test "grid auto-wrap" {
    var grid = try CellGrid.init(std.testing.allocator, 5, 3);
    defer grid.deinit();

    // Fill first row
    for (0..5) |_| grid.putChar('X');
    try std.testing.expect(grid.wrap_pending);

    // Next char wraps to row 1
    grid.putChar('Y');
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_col);
    try std.testing.expectEqual(@as(u21, 'Y'), grid.cellAtConst(1, 0).char);
}

test "grid scroll up" {
    var grid = try CellGrid.init(std.testing.allocator, 5, 3);
    defer grid.deinit();

    // Put A on row 0, B on row 1, C on row 2
    grid.setCursorPos(0, 0);
    grid.putChar('A');
    grid.setCursorPos(1, 0);
    grid.putChar('B');
    grid.setCursorPos(2, 0);
    grid.putChar('C');

    grid.scrollUp(1);

    // Row 0 should now have B, row 1 should have C, row 2 cleared
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(2, 0).char);
}

test "grid erase in display" {
    var grid = try CellGrid.init(std.testing.allocator, 5, 3);
    defer grid.deinit();

    for (0..5) |_| grid.putChar('X');
    grid.eraseInDisplay(2); // erase all

    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char);
}

test "Color equality" {
    try std.testing.expect(Color.eql(.default, .default));
    try std.testing.expect(Color.eql(.{ .palette = 5 }, .{ .palette = 5 }));
    try std.testing.expect(!Color.eql(.default, .{ .palette = 0 }));
    try std.testing.expect(Color.eql(
        .{ .rgb = .{ .r = 255, .g = 0, .b = 128 } },
        .{ .rgb = .{ .r = 255, .g = 0, .b = 128 } },
    ));
}
