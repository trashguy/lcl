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

/// Returned by `displayedCell` for out-of-range scrollback queries — lets
/// the renderer treat it as a blank cell without special-casing.
const empty_cell: Cell = .{};

// ── Cursor state (for save/restore) ─────────────────────────────────

pub const CursorState = struct {
    row: u16,
    col: u16,
    fg: Color,
    bg: Color,
    attrs: Attrs,
};

// ── Selection ───────────────────────────────────────────────────────

pub const Selection = struct {
    active: bool = false,
    anchor_row: u16 = 0,
    anchor_col: u16 = 0,
    head_row: u16 = 0,
    head_col: u16 = 0,

    /// Returns (start_row, start_col, end_row, end_col) in reading order.
    pub fn ordered(self: Selection) struct { sr: u16, sc: u16, er: u16, ec: u16 } {
        const a_before = self.anchor_row < self.head_row or
            (self.anchor_row == self.head_row and self.anchor_col <= self.head_col);
        return if (a_before)
            .{ .sr = self.anchor_row, .sc = self.anchor_col, .er = self.head_row, .ec = self.head_col }
        else
            .{ .sr = self.head_row, .sc = self.head_col, .er = self.anchor_row, .ec = self.anchor_col };
    }

    pub fn contains(self: Selection, row: u16, col: u16) bool {
        if (!self.active) return false;
        const o = self.ordered();
        if (row < o.sr or row > o.er) return false;
        if (o.sr == o.er) return col >= o.sc and col <= o.ec;
        if (row == o.sr) return col >= o.sc;
        if (row == o.er) return col <= o.ec;
        return true;
    }
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

    // Selection (set by GUI mouse, used by renderer + clipboard copy)
    selection: Selection = .{},

    // Title
    title: [256]u8 = undefined,
    title_len: u16 = 0,

    // ── Scrollback ──────────────────────────────────────────────────
    // Ring buffer of past lines that have scrolled off the top of the
    // live grid. Sized at init (and on resize) to `scrollback_capacity *
    // cols` cells; lines are pushed one at a time when scrollUp on the
    // FULL screen (not a DECSTBM region, not in alt-screen) drops a row
    // off the top.
    //
    // `view_offset` is how many lines back the renderer is currently
    // showing — 0 means "live bottom" (no scroll), max == scrollback_count
    // means "looking at the oldest retained line".
    scrollback: ?[]Cell = null,
    scrollback_cols: u16 = 0,
    scrollback_capacity: u16 = 0,
    scrollback_count: u16 = 0,
    scrollback_head: u16 = 0,
    view_offset: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !CellGrid {
        const size = @as(usize, cols) * @as(usize, rows);
        const cells = try allocator.alloc(Cell, size);
        for (cells) |*c| c.* = .{};

        const sb_cap: u16 = 1000;
        const sb = try allocator.alloc(Cell, @as(usize, sb_cap) * cols);
        for (sb) |*c| c.* = .{};

        return .{
            .allocator = allocator,
            .cells = cells,
            .cols = cols,
            .rows = rows,
            .scroll_bottom = rows - 1,
            .scrollback = sb,
            .scrollback_cols = cols,
            .scrollback_capacity = sb_cap,
        };
    }

    pub fn deinit(self: *CellGrid) void {
        self.allocator.free(self.cells);
        if (self.alt_cells) |ac| self.allocator.free(ac);
        if (self.scrollback) |sb| self.allocator.free(sb);
    }

    /// Push a single grid row into the scrollback ring. Called from
    /// scrollUp when a line is about to be pushed off the top of the
    /// full-screen scroll region.
    fn pushScrollback(self: *CellGrid, src_row: u16) void {
        const sb = self.scrollback orelse return;
        const cols = self.scrollback_cols;
        if (cols == 0 or self.scrollback_capacity == 0) return;
        const slot: u16 = self.scrollback_head;
        const src_off = @as(usize, src_row) * self.cols;
        const dst_off = @as(usize, slot) * cols;
        const n = @min(@as(usize, cols), @as(usize, self.cols));
        @memcpy(sb[dst_off..][0..n], self.cells[src_off..][0..n]);
        // Pad if scrollback is wider than current cols (shouldn't happen
        // with the resize-invalidates-scrollback policy, but defensive).
        if (n < cols) {
            for (sb[dst_off + n .. dst_off + cols]) |*c| c.* = .{};
        }
        self.scrollback_head = (slot + 1) % self.scrollback_capacity;
        if (self.scrollback_count < self.scrollback_capacity) self.scrollback_count += 1;
    }

    /// Adjust the view offset by `delta` lines. Positive = scroll back
    /// in time (show older content); negative = scroll forward. Clamps
    /// to [0, scrollback_count].
    pub fn scrollViewBy(self: *CellGrid, delta: i32) void {
        const cur: i32 = @intCast(self.view_offset);
        const max: i32 = @intCast(self.scrollback_count);
        var next = cur + delta;
        if (next < 0) next = 0;
        if (next > max) next = max;
        self.view_offset = @intCast(next);
    }

    pub fn scrollViewToBottom(self: *CellGrid) void {
        self.view_offset = 0;
    }

    /// Resize the scrollback ring to `new_capacity` lines, preserving the
    /// most-recent `min(scrollback_count, new_capacity)` lines. Caller
    /// passes 0 to disable scrollback entirely.
    pub fn setScrollbackCapacity(self: *CellGrid, new_capacity: u32) !void {
        const new_cap_u16 = if (new_capacity > std.math.maxInt(u16))
            std.math.maxInt(u16)
        else
            @as(u16, @intCast(new_capacity));
        if (new_cap_u16 == self.scrollback_capacity) return;

        const cols = self.scrollback_cols;
        if (new_cap_u16 == 0) {
            if (self.scrollback) |old| self.allocator.free(old);
            self.scrollback = null;
            self.scrollback_capacity = 0;
            self.scrollback_count = 0;
            self.scrollback_head = 0;
            self.view_offset = 0;
            return;
        }

        const new_buf = try self.allocator.alloc(Cell, @as(usize, new_cap_u16) * cols);
        for (new_buf) |*c| c.* = .{};

        // Copy the newest `keep` lines from the old ring into the front of
        // the new buffer (in chronological order).
        const keep: u16 = @min(self.scrollback_count, new_cap_u16);
        if (keep > 0 and self.scrollback != null) {
            const old = self.scrollback.?;
            const old_cap = self.scrollback_capacity;
            // Index of oldest of the kept lines, in the *old* ring.
            // newest line is at (head - 1) mod cap; we want the line that's
            // (keep - 1) older than that.
            const newest_idx: u32 = (self.scrollback_head + old_cap - 1) % old_cap;
            const start_idx: u32 = (newest_idx + old_cap - (@as(u32, keep) - 1)) % old_cap;
            var i: u16 = 0;
            while (i < keep) : (i += 1) {
                const src_idx = (start_idx + i) % old_cap;
                const src_off = @as(usize, src_idx) * cols;
                const dst_off = @as(usize, i) * cols;
                @memcpy(new_buf[dst_off..][0..cols], old[src_off..][0..cols]);
            }
            self.allocator.free(old);
        } else if (self.scrollback) |old| {
            self.allocator.free(old);
        }

        self.scrollback = new_buf;
        self.scrollback_capacity = new_cap_u16;
        self.scrollback_count = keep;
        self.scrollback_head = if (keep == new_cap_u16) 0 else keep;
        if (self.view_offset > self.scrollback_count) self.view_offset = self.scrollback_count;
    }

    /// Resolve viewport row r (0..rows-1) to the cell that should be
    /// rendered there given the current view_offset. When scrolled up,
    /// the top rows pull from the scrollback ring instead of the live
    /// grid.
    pub fn displayedCell(self: *const CellGrid, row: u16, col: u16) *const Cell {
        const k = self.view_offset;
        if (row >= k) {
            const live_row: u16 = row - k;
            if (live_row < self.rows) return self.cellAtConst(live_row, col);
        }
        // Scrollback line index from oldest: scrollback_count - k + row.
        // (row < k is guaranteed here.)
        const i_signed = @as(i32, @intCast(self.scrollback_count)) -
            @as(i32, @intCast(k)) + @as(i32, @intCast(row));
        if (i_signed < 0 or i_signed >= @as(i32, @intCast(self.scrollback_count))) {
            return &empty_cell;
        }
        const i: u16 = @intCast(i_signed);
        const ring_idx: u16 = if (self.scrollback_count < self.scrollback_capacity)
            i
        else
            @intCast((@as(u32, self.scrollback_head) + i) % self.scrollback_capacity);
        const sb = self.scrollback orelse return &empty_cell;
        const cols = self.scrollback_cols;
        if (col >= cols) return &empty_cell;
        return &sb[@as(usize, ring_idx) * cols + col];
    }

    /// Resize the grid to `new_cols x new_rows`, preserving cell content
    /// from the top-left. Cursor is clamped to the new bounds and the
    /// scroll region is reset to full-screen. Caller must follow up with
    /// a TIOCSWINSZ-equivalent (writeResize on the shell fd) so the
    /// remote PTY agrees on the new size.
    pub fn resize(self: *CellGrid, new_cols: u16, new_rows: u16) !void {
        if (new_cols == 0 or new_rows == 0) return;
        if (new_cols == self.cols and new_rows == self.rows) return;

        const new_size = @as(usize, new_cols) * @as(usize, new_rows);
        const new_cells = try self.allocator.alloc(Cell, new_size);
        for (new_cells) |*c| c.* = .{};

        const copy_rows = @min(self.rows, new_rows);
        const copy_cols = @min(self.cols, new_cols);
        var r: u16 = 0;
        while (r < copy_rows) : (r += 1) {
            const dst = @as(usize, r) * new_cols;
            const src = @as(usize, r) * self.cols;
            @memcpy(new_cells[dst..][0..copy_cols], self.cells[src..][0..copy_cols]);
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;

        if (self.alt_cells) |old_alt| {
            const new_alt = try self.allocator.alloc(Cell, new_size);
            for (new_alt) |*c| c.* = .{};
            self.allocator.free(old_alt);
            self.alt_cells = new_alt;
        }

        self.cols = new_cols;
        self.rows = new_rows;

        if (self.cursor_row >= new_rows) self.cursor_row = new_rows - 1;
        if (self.cursor_col >= new_cols) self.cursor_col = new_cols - 1;

        self.scroll_top = 0;
        self.scroll_bottom = new_rows - 1;
        self.wrap_pending = false;
        self.selectionClear();

        // Cols change invalidates scrollback row-storage layout. Reflowing
        // historical rows is its own project — for v1 we just drop them
        // and reallocate at the new width.
        if (new_cols != self.scrollback_cols) {
            if (self.scrollback) |old_sb| self.allocator.free(old_sb);
            const new_sb = self.allocator.alloc(Cell, @as(usize, self.scrollback_capacity) * new_cols) catch null;
            if (new_sb) |sb| {
                for (sb) |*c| c.* = .{};
            }
            self.scrollback = new_sb;
            self.scrollback_cols = new_cols;
            self.scrollback_count = 0;
            self.scrollback_head = 0;
            self.view_offset = 0;
        }
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

        // Push the lines about to be discarded into scrollback, but only
        // when this is a full-screen scroll on the live screen. DECSTBM
        // partial-screen scrolling and alt-screen apps (vim, less)
        // shouldn't pollute user history.
        if (!self.in_alt_screen and self.scroll_top == 0 and self.scroll_bottom == self.rows - 1) {
            var i: u16 = 0;
            while (i < n) : (i += 1) {
                self.pushScrollback(self.scroll_top + i);
            }
        }

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

    // ── Selection ───────────────────────────────────────────────────

    pub fn selectionStart(self: *CellGrid, row: u16, col: u16) void {
        const r = @min(row, self.rows -| 1);
        const c = @min(col, self.cols -| 1);
        self.selection = .{ .active = true, .anchor_row = r, .anchor_col = c, .head_row = r, .head_col = c };
    }

    pub fn selectionExtend(self: *CellGrid, row: u16, col: u16) void {
        if (!self.selection.active) return;
        self.selection.head_row = @min(row, self.rows -| 1);
        self.selection.head_col = @min(col, self.cols -| 1);
    }

    pub fn selectionClear(self: *CellGrid) void {
        self.selection.active = false;
    }

    pub fn selectAll(self: *CellGrid) void {
        self.selection = .{
            .active = true,
            .anchor_row = 0,
            .anchor_col = 0,
            .head_row = self.rows -| 1,
            .head_col = self.cols -| 1,
        };
    }

    /// Extract selected text as UTF-8. Trailing spaces on each line are
    /// trimmed; rows are joined with '\n'. Caller owns returned memory.
    /// Returns empty slice if no active selection.
    pub fn selectionExtract(self: *const CellGrid, allocator: std.mem.Allocator) ![]u8 {
        if (!self.selection.active) return try allocator.alloc(u8, 0);
        const o = self.selection.ordered();

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        var row: u16 = o.sr;
        while (row <= o.er) : (row += 1) {
            const col_start: u16 = if (row == o.sr) o.sc else 0;
            const col_end: u16 = if (row == o.er) o.ec else self.cols - 1;

            // Find last non-space cell ≤ col_end so trailing blanks are dropped
            var last: i32 = @as(i32, col_start) - 1;
            var col: u16 = col_start;
            while (col <= col_end) : (col += 1) {
                const ch = self.cellAtConst(row, col).char;
                if (ch != ' ' and ch != 0) last = @intCast(col);
            }

            col = col_start;
            while (@as(i32, col) <= last) : (col += 1) {
                const ch = self.cellAtConst(row, col).char;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(ch, &buf) catch 0;
                if (n > 0) try out.appendSlice(allocator, buf[0..n]);
            }

            if (row != o.er) try out.append(allocator, '\n');
        }

        return try out.toOwnedSlice(allocator);
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
        self.selection = .{};
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

test "selection extract single row trims trailing spaces" {
    var grid = try CellGrid.init(std.testing.allocator, 10, 3);
    defer grid.deinit();

    for ("hello") |ch| grid.putChar(ch);
    grid.selectionStart(0, 0);
    grid.selectionExtend(0, 9);

    const out = try grid.selectionExtract(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "selection extract multi-row joins with newlines" {
    var grid = try CellGrid.init(std.testing.allocator, 5, 3);
    defer grid.deinit();

    grid.setCursorPos(0, 0);
    for ("foo") |ch| grid.putChar(ch);
    grid.setCursorPos(1, 0);
    for ("bar") |ch| grid.putChar(ch);
    grid.setCursorPos(2, 0);
    for ("baz") |ch| grid.putChar(ch);

    grid.selectionStart(0, 0);
    grid.selectionExtend(2, 4);

    const out = try grid.selectionExtract(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("foo\nbar\nbaz", out);
}

test "selection ordered handles backward drag" {
    var grid = try CellGrid.init(std.testing.allocator, 10, 3);
    defer grid.deinit();

    for ("hello") |ch| grid.putChar(ch);
    grid.selectionStart(0, 4);
    grid.selectionExtend(0, 0);

    const out = try grid.selectionExtract(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
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
