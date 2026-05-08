/// Custom NSView subclass for terminal rendering.

const std = @import("std");
const objc = @import("objc");
const coretext = @import("coretext");
const cell_mod = @import("cell");
const input = @import("input");
const pasteboard = @import("pasteboard");

// ── Per-view state ──────────────────────────────────────────────────
//
// Font and theme colors are shared across every tab — they're driven by
// the user's appearance settings. Grid + input callback are per-view, so
// we look them up via a host-provided callback keyed on the NSView.

pub const ViewState = struct {
    grid: *cell_mod.CellGrid,
};

pub const ViewLookupFn = fn (objc.id) ?ViewState;
pub const InputFn = fn (objc.id, []const u8) void;

var view_lookup: ?*const ViewLookupFn = null;
var input_callback: ?*const InputFn = null;
var global_font: ?*const coretext.FontInfo = null;
var view_class_registered: bool = false;

var default_fg: coretext.Rgb = .{ .r = 0.0, .g = 1.0, .b = 0.0 };
var default_bg: coretext.Rgb = .{ .r = 0.0, .g = 0.0, .b = 0.0 };

/// Cursor block color. Default is light gray; themes can override via
/// setCursorColor. Drawn at 50% alpha so the underlying glyph stays visible.
var cursor_color: coretext.Rgb = .{ .r = 0.8, .g = 0.8, .b = 0.8 };

pub fn setDefaultColors(fg: coretext.Rgb, bg: coretext.Rgb) void {
    default_fg = fg;
    default_bg = bg;
}

/// Push the current background color into a specific NSWindow so the
/// title bar / non-content areas blend with the theme. Caller is
/// responsible for invoking this for every tab window after a theme change.
pub fn applyBackgroundToWindow(window: objc.id) void {
    const NSColor = objc.getClass("NSColor") orelse return;
    const color = objc.msgSend(objc.id, NSColor, objc.sel("colorWithSRGBRed:green:blue:alpha:"), .{
        default_bg.r, default_bg.g, default_bg.b, @as(objc.CGFloat, 1.0),
    });
    objc.msgSend(void, window, objc.sel("setBackgroundColor:"), .{color});
}

pub fn setCursorColor(rgb: coretext.Rgb) void {
    cursor_color = rgb;
}

pub fn setFont(font: *const coretext.FontInfo) void {
    global_font = font;
}

pub fn setViewLookup(lookup: *const ViewLookupFn) void {
    view_lookup = lookup;
}

pub fn setInputCallback(cb: *const InputFn) void {
    input_callback = cb;
}

extern "c" fn objc_allocateClassPair(superclass: ?objc.Class, name: [*:0]const u8, extra_bytes: usize) ?objc.Class;

// ── Public API ──────────────────────────────────────────────────────

pub fn createTerminalView(
    grid: *cell_mod.CellGrid,
    font: *const coretext.FontInfo,
) objc.id {
    global_font = font;

    ensureViewClass();

    const cls = objc.getClass("LCLTerminalView2") orelse @panic("LCLTerminalView2 not found");

    const width = @as(objc.CGFloat, @floatFromInt(grid.cols)) * font.cell_width;
    const height = @as(objc.CGFloat, @floatFromInt(grid.rows)) * font.cell_height;

    const frame = objc.NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = width, .height = height },
    };

    const view = objc.msgSend(objc.id, objc.alloc(cls), objc.sel("initWithFrame:"), .{frame});

    const width_sizable: objc.NSUInteger = 1 << 1;
    const height_sizable: objc.NSUInteger = 1 << 4;
    objc.msgSend(void, view, objc.sel("setAutoresizingMask:"), .{width_sizable | height_sizable});

    return view;
}

pub fn setNeedsDisplay(view: objc.id) void {
    objc.msgSend(void, view, objc.sel("setNeedsDisplay:"), .{objc.YES});
}

// ── ObjC class registration ────────────────────────────────────────

fn ensureViewClass() void {
    if (view_class_registered) return;

    const NSView = objc.getClass("NSView") orelse @panic("NSView not found");
    const view_cls = objc_allocateClassPair(NSView, "LCLTerminalView2", 0) orelse @panic("Failed to allocate LCLTerminalView2");

    _ = objc.addMethod(view_cls, objc.sel("drawRect:"), @ptrCast(&viewDrawRect), "v@:{NSRect={NSPoint=dd}{NSSize=dd}}");
    _ = objc.addMethod(view_cls, objc.sel("keyDown:"), @ptrCast(&viewKeyDown), "v@:@");
    _ = objc.addMethod(view_cls, objc.sel("mouseDown:"), @ptrCast(&viewMouseDown), "v@:@");
    _ = objc.addMethod(view_cls, objc.sel("mouseDragged:"), @ptrCast(&viewMouseDragged), "v@:@");
    _ = objc.addMethod(view_cls, objc.sel("mouseUp:"), @ptrCast(&viewMouseUp), "v@:@");
    _ = objc.addMethod(view_cls, objc.sel("scrollWheel:"), @ptrCast(&viewScrollWheel), "v@:@");
    _ = objc.addMethod(view_cls, objc.sel("acceptsFirstResponder"), @ptrCast(&acceptsFirstResponder), "c@:");
    _ = objc.addMethod(view_cls, objc.sel("isFlipped"), @ptrCast(&isFlipped), "c@:");

    objc.registerClass(view_cls);
    view_class_registered = true;
}

// ── ObjC method implementations ────────────────────────────────────

fn acceptsFirstResponder(_: *const anyopaque, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn isFlipped(_: *const anyopaque, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn viewDrawRect(view_self: *const anyopaque, _: objc.SEL, _: objc.NSRect) callconv(.c) void {
    const v: objc.id = @ptrCast(@constCast(view_self));
    const lookup = view_lookup orelse return;
    const state = lookup(v) orelse return;
    const grid = state.grid;
    const font = global_font orelse return;

    const NSGraphicsContext = objc.getClass("NSGraphicsContext") orelse return;
    const gfx_ctx = objc.msgSend(?objc.id, NSGraphicsContext, objc.sel("currentContext"), .{});
    if (gfx_ctx == null) return;
    const cg_ctx: coretext.CGContextRef = @ptrCast(objc.msgSend(objc.id, gfx_ctx.?, objc.sel("CGContext"), .{}));

    // Fill the entire view bounds with the background color so resizes past
    // the grid edge don't expose the window's default color.
    const bounds = objc.msgSend(objc.NSRect, v, objc.sel("bounds"), .{});
    coretext.fillRect(cg_ctx, bounds, default_bg);

    // Draw cells. When scrolled back (view_offset > 0) the top rows pull
    // from the scrollback ring instead of the live grid.
    var row: u16 = 0;
    while (row < grid.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < grid.cols) : (col += 1) {
            const c = grid.displayedCell(row, col);
            const x = @as(objc.CGFloat, @floatFromInt(col)) * font.cell_width;
            const y = @as(objc.CGFloat, @floatFromInt(row)) * font.cell_height;

            const selected = grid.selection.contains(row, col);
            const reverse = c.attrs.reverse != selected; // XOR: selection inverts colors

            const bg_rgb = colorToRgb(c.bg, reverse, default_fg, default_bg, true);
            if (bg_rgb.r != default_bg.r or bg_rgb.g != default_bg.g or bg_rgb.b != default_bg.b) {
                coretext.fillRect(cg_ctx, .{
                    .origin = .{ .x = x, .y = y },
                    .size = .{ .width = font.cell_width, .height = font.cell_height },
                }, bg_rgb);
            }

            if (c.char > 0x20) {
                const fg_rgb = colorToRgb(c.fg, reverse, default_fg, default_bg, false);
                coretext.drawChar(cg_ctx, c.char, x, y, font, fg_rgb);
            }
        }
    }

    // Cursor — only draw when at the bottom (view_offset == 0). When the
    // user is scrolled up reading history, hide the cursor.
    if (grid.view_offset == 0 and grid.cursor_visible and grid.cursor_row < grid.rows and grid.cursor_col < grid.cols) {
        const cx = @as(objc.CGFloat, @floatFromInt(grid.cursor_col)) * font.cell_width;
        const cy = @as(objc.CGFloat, @floatFromInt(grid.cursor_row)) * font.cell_height;
        coretext.CGContextSetRGBFillColor(cg_ctx, cursor_color.r, cursor_color.g, cursor_color.b, 0.5);
        coretext.CGContextFillRect(cg_ctx, .{
            .origin = .{ .x = cx, .y = cy },
            .size = .{ .width = font.cell_width, .height = font.cell_height },
        });
    }
}

fn eventToCell(view: objc.id, grid: *cell_mod.CellGrid, event: objc.id) struct { row: u16, col: u16 } {
    const font = global_font.?;
    const win_pt = objc.msgSend(objc.NSPoint, event, objc.sel("locationInWindow"), .{});
    const view_pt = objc.msgSend(objc.NSPoint, view, objc.sel("convertPoint:fromView:"), .{ win_pt, @as(?objc.id, null) });

    const col_f = view_pt.x / font.cell_width;
    const row_f = view_pt.y / font.cell_height;
    const col_clamped: u16 = if (col_f < 0) 0 else @intFromFloat(@min(col_f, @as(objc.CGFloat, @floatFromInt(grid.cols - 1))));
    const row_clamped: u16 = if (row_f < 0) 0 else @intFromFloat(@min(row_f, @as(objc.CGFloat, @floatFromInt(grid.rows - 1))));
    return .{ .row = row_clamped, .col = col_clamped };
}

fn lookupGrid(view: objc.id) ?*cell_mod.CellGrid {
    const lookup = view_lookup orelse return null;
    const state = lookup(view) orelse return null;
    return state.grid;
}

fn viewMouseDown(view: *const anyopaque, _: objc.SEL, event: objc.id) callconv(.c) void {
    const v: objc.id = @ptrCast(@constCast(view));
    const grid = lookupGrid(v) orelse return;
    const cell = eventToCell(v, grid, event);
    grid.selectionStart(cell.row, cell.col);
    objc.msgSend(void, v, objc.sel("setNeedsDisplay:"), .{objc.YES});
}

fn viewMouseDragged(view: *const anyopaque, _: objc.SEL, event: objc.id) callconv(.c) void {
    const v: objc.id = @ptrCast(@constCast(view));
    const grid = lookupGrid(v) orelse return;
    const cell = eventToCell(v, grid, event);
    grid.selectionExtend(cell.row, cell.col);
    objc.msgSend(void, v, objc.sel("setNeedsDisplay:"), .{objc.YES});
}

fn viewMouseUp(view: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) void {
    const v: objc.id = @ptrCast(@constCast(view));
    const grid = lookupGrid(v) orelse return;
    // Click without drag (anchor == head) clears any prior selection.
    if (grid.selection.active and
        grid.selection.anchor_row == grid.selection.head_row and
        grid.selection.anchor_col == grid.selection.head_col)
    {
        grid.selectionClear();
        objc.msgSend(void, v, objc.sel("setNeedsDisplay:"), .{objc.YES});
    }
}

/// Trackpad / mouse-wheel scroll. Positive deltaY = swipe-down on
/// trackpad / wheel-up = scroll back in time (older content). We
/// accumulate fractional deltas across events so a slow pan doesn't
/// stall when each event's deltaY < 1 line.
var scroll_accum: f64 = 0.0;

fn viewScrollWheel(view: *const anyopaque, _: objc.SEL, event: objc.id) callconv(.c) void {
    const v: objc.id = @ptrCast(@constCast(view));
    const grid = lookupGrid(v) orelse return;
    const font = global_font orelse return;
    if (font.cell_height <= 0) return;

    // -[NSEvent scrollingDeltaY]: pixels in the natural-scroll direction.
    // When the OS reports "precise" deltas (trackpad), this is fractional;
    // wheel events come in larger discrete chunks.
    const dy: f64 = objc.msgSend(f64, event, objc.sel("scrollingDeltaY"), .{});
    if (dy == 0.0) return;

    scroll_accum += dy;
    const lines_f = scroll_accum / @as(f64, @floatCast(font.cell_height));
    const lines: i32 = @intFromFloat(lines_f);
    if (lines == 0) return;
    scroll_accum -= @as(f64, @floatFromInt(lines)) * @as(f64, @floatCast(font.cell_height));

    // Positive deltaY = scroll back in time; matches how Terminal.app and
    // iTerm interpret natural scroll direction.
    grid.scrollViewBy(lines);

    objc.msgSend(void, v, objc.sel("setNeedsDisplay:"), .{objc.YES});
}

fn viewKeyDown(view_self: *const anyopaque, _: objc.SEL, event: objc.id) callconv(.c) void {
    const v: objc.id = @ptrCast(@constCast(view_self));
    const grid = lookupGrid(v) orelse return;
    const cb = input_callback orelse return;

    const keycode: u16 = @intCast(objc.msgSend(u16, event, objc.sel("keyCode"), .{}));
    const modifier_flags: u64 = @intCast(objc.msgSend(objc.NSUInteger, event, objc.sel("modifierFlags"), .{}));

    const chars_ns = objc.msgSend(?objc.id, event, objc.sel("characters"), .{});
    var chars: []const u8 = &.{};
    if (chars_ns) |ns| {
        const cstr = objc.fromNSString(ns);
        chars = std.mem.span(cstr);
    }

    if (modifier_flags & input.ModifierFlags.command != 0) {
        if (chars.len == 1) {
            switch (chars[0]) {
                'v', 'V' => handlePaste(v, grid, cb),
                'c', 'C' => handleCopy(grid, v),
                'a', 'A' => handleSelectAll(grid, v),
                else => {},
            }
        }
        return;
    }

    // Any non-modifier keystroke snaps the viewport back to the live
    // bottom — match the behaviour of Terminal.app/iTerm.
    if (grid.view_offset != 0) {
        grid.scrollViewToBottom();
        objc.msgSend(void, v, objc.sel("setNeedsDisplay:"), .{objc.YES});
    }

    if (input.encodeKey(keycode, chars, modifier_flags, grid.app_cursor_keys)) |result| {
        cb(v, result.bytes());
    }
}

fn handlePaste(view: objc.id, grid: *cell_mod.CellGrid, cb: *const InputFn) void {
    const text = pasteboard.getString() orelse return;
    if (text.len == 0) return;
    if (grid.bracketed_paste) {
        cb(view, "\x1b[200~");
        cb(view, text);
        cb(view, "\x1b[201~");
    } else {
        cb(view, text);
    }
}

fn handleCopy(grid: *cell_mod.CellGrid, view: objc.id) void {
    if (!grid.selection.active) return;
    const text = grid.selectionExtract(grid.allocator) catch return;
    defer grid.allocator.free(text);
    if (text.len == 0) return;
    _ = pasteboard.setString(text);
    grid.selectionClear();
    objc.msgSend(void, view, objc.sel("setNeedsDisplay:"), .{objc.YES});
}

fn handleSelectAll(grid: *cell_mod.CellGrid, view: objc.id) void {
    grid.selectAll();
    objc.msgSend(void, view, objc.sel("setNeedsDisplay:"), .{objc.YES});
}

// ── Color helpers ───────────────────────────────────────────────────

fn colorToRgb(color: cell_mod.Color, reverse: bool, fg: coretext.Rgb, bg: coretext.Rgb, is_bg: bool) coretext.Rgb {
    const effective = if (reverse) !is_bg else is_bg;
    const def = if (effective) bg else fg;

    return switch (color) {
        .default => def,
        .palette => |idx| coretext.paletteToRgb(idx),
        .rgb => |rgb| .{
            .r = @as(objc.CGFloat, @floatFromInt(rgb.r)) / 255.0,
            .g = @as(objc.CGFloat, @floatFromInt(rgb.g)) / 255.0,
            .b = @as(objc.CGFloat, @floatFromInt(rgb.b)) / 255.0,
        },
    };
}
