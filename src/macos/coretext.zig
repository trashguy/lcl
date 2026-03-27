/// CoreText / CoreGraphics bindings for terminal text rendering.
/// Provides monospace font creation, cell size calculation, and text drawing.

const std = @import("std");
const objc = @import("objc");

// ── CoreText C API ──────────────────────────────────────────────────

const CTFontRef = *opaque {};
pub const CGContextRef = *opaque {};
const CGColorRef = *opaque {};
const CGColorSpaceRef = *opaque {};
const CFAttributedStringRef = *opaque {};
const CTLineRef = *opaque {};

extern "c" fn CTFontCreateWithName(name: objc.id, size: objc.CGFloat, matrix: ?*const anyopaque) CTFontRef;
extern "c" fn CTFontGetAscent(font: CTFontRef) objc.CGFloat;
extern "c" fn CTFontGetDescent(font: CTFontRef) objc.CGFloat;
extern "c" fn CTFontGetLeading(font: CTFontRef) objc.CGFloat;

extern "c" fn CTLineCreateWithAttributedString(attrString: CFAttributedStringRef) CTLineRef;
extern "c" fn CTLineDraw(line: CTLineRef, context: CGContextRef) void;

extern "c" fn CGContextSetTextPosition(ctx: CGContextRef, x: objc.CGFloat, y: objc.CGFloat) void;
pub extern "c" fn CGContextSetRGBFillColor(ctx: CGContextRef, r: objc.CGFloat, g: objc.CGFloat, b: objc.CGFloat, a: objc.CGFloat) void;
pub extern "c" fn CGContextFillRect(ctx: CGContextRef, rect: objc.NSRect) void;
extern "c" fn CGContextSaveGState(ctx: CGContextRef) void;
extern "c" fn CGContextRestoreGState(ctx: CGContextRef) void;
extern "c" fn CGContextTranslateCTM(ctx: CGContextRef, tx: objc.CGFloat, ty: objc.CGFloat) void;
extern "c" fn CGContextScaleCTM(ctx: CGContextRef, sx: objc.CGFloat, sy: objc.CGFloat) void;

extern "c" fn CGColorSpaceCreateDeviceRGB() CGColorSpaceRef;

// CFRelease
extern "c" fn CFRelease(cf: *anyopaque) void;

// ── Font management ─────────────────────────────────────────────────

pub const FontInfo = struct {
    font: CTFontRef,
    ns_font: objc.id, // NSFont object for attributed strings
    cell_width: objc.CGFloat,
    cell_height: objc.CGFloat,
    ascent: objc.CGFloat,
    descent: objc.CGFloat,
    leading: objc.CGFloat,
};

/// Create a monospace font and compute cell dimensions.
pub fn createFont(name: [*:0]const u8, size: objc.CGFloat) FontInfo {
    const NSFont = objc.getClass("NSFont") orelse @panic("NSFont not found");

    // Try the named font first, fall back to system monospace
    const ns_name = objc.nsString(name);
    var ns_font = objc.msgSend(?objc.id, NSFont, objc.sel("fontWithName:size:"), .{ ns_name, size });
    if (ns_font == null) {
        // Use system monospace font (guaranteed to exist)
        ns_font = objc.msgSend(?objc.id, NSFont, objc.sel("monospacedSystemFontOfSize:weight:"), .{
            size,
            @as(objc.CGFloat, 0.0), // NSFontWeightRegular
        });
    }
    const font = ns_font orelse @panic("No monospace font available");
    // Retain — the font is autoreleased and drawRect fires after the pool drains
    _ = objc.retain(font);

    // Create CTFont from the same font
    const font_name = objc.msgSend(objc.id, font, objc.sel("fontName"), .{});
    const ct_font = CTFontCreateWithName(font_name, size, null);

    const ascent = CTFontGetAscent(ct_font);
    const descent = CTFontGetDescent(ct_font);
    const leading = CTFontGetLeading(ct_font);

    // Get cell width from maximumAdvancement
    const advancement = objc.msgSend(objc.NSSize, font, objc.sel("maximumAdvancement"), .{});
    const cell_width = @round(advancement.width);
    const cell_height = @ceil(ascent + descent + leading);

    return .{
        .font = ct_font,
        .ns_font = font,
        .cell_width = if (cell_width > 0) cell_width else size * 0.6,
        .cell_height = if (cell_height > 0) cell_height else size * 1.2,
        .ascent = ascent,
        .descent = descent,
        .leading = leading,
    };
}

// ── Color conversion ────────────────────────────────────────────────

/// Standard ANSI 16-color palette (xterm defaults).
pub const ansi_palette = [16][3]u8{
    .{ 0, 0, 0 }, // 0: black
    .{ 205, 0, 0 }, // 1: red
    .{ 0, 205, 0 }, // 2: green
    .{ 205, 205, 0 }, // 3: yellow
    .{ 0, 0, 238 }, // 4: blue
    .{ 205, 0, 205 }, // 5: magenta
    .{ 0, 205, 205 }, // 6: cyan
    .{ 229, 229, 229 }, // 7: white
    .{ 127, 127, 127 }, // 8: bright black
    .{ 255, 0, 0 }, // 9: bright red
    .{ 0, 255, 0 }, // 10: bright green
    .{ 255, 255, 0 }, // 11: bright yellow
    .{ 92, 92, 255 }, // 12: bright blue
    .{ 255, 0, 255 }, // 13: bright magenta
    .{ 0, 255, 255 }, // 14: bright cyan
    .{ 255, 255, 255 }, // 15: bright white
};

pub const Rgb = struct { r: objc.CGFloat, g: objc.CGFloat, b: objc.CGFloat };

/// Convert a 256-color palette index to RGB floats (0.0-1.0).
pub fn paletteToRgb(index: u8) Rgb {
    if (index < 16) {
        const c = ansi_palette[index];
        return .{
            .r = @as(objc.CGFloat, @floatFromInt(c[0])) / 255.0,
            .g = @as(objc.CGFloat, @floatFromInt(c[1])) / 255.0,
            .b = @as(objc.CGFloat, @floatFromInt(c[2])) / 255.0,
        };
    } else if (index < 232) {
        // 216-color cube: 16-231
        const i = index - 16;
        const r_val: u8 = i / 36;
        const g_val: u8 = (i % 36) / 6;
        const b_val: u8 = i % 6;
        return .{
            .r = if (r_val == 0) 0 else @as(objc.CGFloat, @floatFromInt(@as(u16, r_val) * 40 + 55)) / 255.0,
            .g = if (g_val == 0) 0 else @as(objc.CGFloat, @floatFromInt(@as(u16, g_val) * 40 + 55)) / 255.0,
            .b = if (b_val == 0) 0 else @as(objc.CGFloat, @floatFromInt(@as(u16, b_val) * 40 + 55)) / 255.0,
        };
    } else {
        // Grayscale: 232-255
        const gray: u16 = @as(u16, index - 232) * 10 + 8;
        const v = @as(objc.CGFloat, @floatFromInt(gray)) / 255.0;
        return .{ .r = v, .g = v, .b = v };
    }
}

// ── Drawing helpers ─────────────────────────────────────────────────

/// Fill a rectangle with an RGB color.
pub fn fillRect(ctx: CGContextRef, rect: objc.NSRect, rgb: Rgb) void {
    CGContextSetRGBFillColor(ctx, rgb.r, rgb.g, rgb.b, 1.0);
    CGContextFillRect(ctx, rect);
}

/// Draw a single character at (x, y) with the given font and color.
/// The position is the baseline origin.
pub fn drawChar(ctx: CGContextRef, char: u21, x: objc.CGFloat, y: objc.CGFloat, font_info: *const FontInfo, rgb: Rgb) void {
    if (char < 0x20) return; // control chars — don't render

    // Create NSAttributedString with the character
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(char, &buf) catch return;

    const NSAttributedString = objc.getClass("NSAttributedString") orelse return;
    const NSFont_key = objc.nsString("NSFont");
    const NSColor_key = objc.nsString("NSColor"); // NSForegroundColorAttributeName = @"NSColor"

    // Create NSColor from RGB
    const NSColor = objc.getClass("NSColor") orelse return;
    const color = objc.msgSend(objc.id, NSColor, objc.sel("colorWithRed:green:blue:alpha:"), .{
        rgb.r, rgb.g, rgb.b, @as(objc.CGFloat, 1.0),
    });

    // Attributes dictionary — NSDictionary crashes on nil values
    const attrs = objc.nsMutableDictionary();
    if (@intFromPtr(font_info.ns_font) == 0) return;
    objc.dictSetObject(attrs, font_info.ns_font, NSFont_key);
    objc.dictSetObject(attrs, color, NSColor_key);

    const ns_str = objc.nsStringFromSlice(buf[0..len]);
    const attr_str = objc.msgSend(objc.id, objc.alloc(NSAttributedString), objc.sel("initWithString:attributes:"), .{
        ns_str, attrs,
    });

    // Use NSAttributedString drawAtPoint: — respects flipped views natively
    _ = ctx; // CGContext not needed for this approach
    const point = objc.NSPoint{ .x = x, .y = y };
    objc.msgSend(void, attr_str, objc.sel("drawAtPoint:"), .{point});
}
