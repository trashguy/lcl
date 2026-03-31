/// Custom NSView subclass for terminal rendering.

const std = @import("std");
const objc = @import("objc");
const coretext = @import("coretext");
const cell_mod = @import("cell");
const input = @import("input");

// ── Global state ────────────────────────────────────────────────────

var global_grid: ?*cell_mod.CellGrid = null;
var global_font: ?*const coretext.FontInfo = null;
var global_input_callback: ?*const fn ([]const u8) void = null;
var view_class_registered: bool = false;

extern "c" fn objc_allocateClassPair(superclass: ?objc.Class, name: [*:0]const u8, extra_bytes: usize) ?objc.Class;

// ── Public API ──────────────────────────────────────────────────────

pub fn createTerminalView(
    grid: *cell_mod.CellGrid,
    font: *const coretext.FontInfo,
    input_callback: *const fn ([]const u8) void,
) objc.id {
    global_grid = grid;
    global_font = font;
    global_input_callback = input_callback;

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

fn viewDrawRect(_: *const anyopaque, _: objc.SEL, _: objc.NSRect) callconv(.c) void {
    const grid = global_grid orelse return;
    const font = global_font orelse return;

    const NSGraphicsContext = objc.getClass("NSGraphicsContext") orelse return;
    const gfx_ctx = objc.msgSend(?objc.id, NSGraphicsContext, objc.sel("currentContext"), .{});
    if (gfx_ctx == null) return;
    const cg_ctx: coretext.CGContextRef = @ptrCast(objc.msgSend(objc.id, gfx_ctx.?, objc.sel("CGContext"), .{}));

    const default_fg = coretext.Rgb{ .r = 0.0, .g = 1.0, .b = 0.0 };
    const default_bg = coretext.Rgb{ .r = 0.0, .g = 0.0, .b = 0.0 };

    // Fill background
    const full_rect = objc.NSRect{
        .origin = .{},
        .size = .{
            .width = @as(objc.CGFloat, @floatFromInt(grid.cols)) * font.cell_width,
            .height = @as(objc.CGFloat, @floatFromInt(grid.rows)) * font.cell_height,
        },
    };
    coretext.fillRect(cg_ctx, full_rect, default_bg);

    // Draw cells
    var row: u16 = 0;
    while (row < grid.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < grid.cols) : (col += 1) {
            const c = grid.cellAtConst(row, col);
            const x = @as(objc.CGFloat, @floatFromInt(col)) * font.cell_width;
            const y = @as(objc.CGFloat, @floatFromInt(row)) * font.cell_height;

            const bg_rgb = colorToRgb(c.bg, c.attrs.reverse, default_fg, default_bg, true);
            if (bg_rgb.r != default_bg.r or bg_rgb.g != default_bg.g or bg_rgb.b != default_bg.b) {
                coretext.fillRect(cg_ctx, .{
                    .origin = .{ .x = x, .y = y },
                    .size = .{ .width = font.cell_width, .height = font.cell_height },
                }, bg_rgb);
            }

            if (c.char > 0x20) {
                const fg_rgb = colorToRgb(c.fg, c.attrs.reverse, default_fg, default_bg, false);
                coretext.drawChar(cg_ctx, c.char, x, y, font, fg_rgb);
            }
        }
    }

    // Cursor
    if (grid.cursor_visible and grid.cursor_row < grid.rows and grid.cursor_col < grid.cols) {
        const cx = @as(objc.CGFloat, @floatFromInt(grid.cursor_col)) * font.cell_width;
        const cy = @as(objc.CGFloat, @floatFromInt(grid.cursor_row)) * font.cell_height;
        coretext.CGContextSetRGBFillColor(cg_ctx, 0.8, 0.8, 0.8, 0.5);
        coretext.CGContextFillRect(cg_ctx, .{
            .origin = .{ .x = cx, .y = cy },
            .size = .{ .width = font.cell_width, .height = font.cell_height },
        });
    }
}

fn viewKeyDown(_: *const anyopaque, _: objc.SEL, event: objc.id) callconv(.c) void {
    const callback = global_input_callback orelse return;
    const grid = global_grid orelse return;

    const keycode: u16 = @intCast(objc.msgSend(u16, event, objc.sel("keyCode"), .{}));
    const modifier_flags: u64 = @intCast(objc.msgSend(objc.NSUInteger, event, objc.sel("modifierFlags"), .{}));

    const chars_ns = objc.msgSend(?objc.id, event, objc.sel("characters"), .{});
    var chars: []const u8 = &.{};
    if (chars_ns) |ns| {
        const cstr = objc.fromNSString(ns);
        chars = std.mem.span(cstr);
    }

    if (modifier_flags & input.ModifierFlags.command != 0) return;

    if (input.encodeKey(keycode, chars, modifier_flags, grid.app_cursor_keys)) |result| {
        callback(result.bytes());
    }
}

// ── Color helpers ───────────────────────────────────────────────────

fn colorToRgb(color: cell_mod.Color, reverse: bool, default_fg: coretext.Rgb, default_bg: coretext.Rgb, is_bg: bool) coretext.Rgb {
    const effective = if (reverse) !is_bg else is_bg;
    const def = if (effective) default_bg else default_fg;

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
