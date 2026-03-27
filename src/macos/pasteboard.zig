/// NSPasteboard bindings for clipboard access.
/// Requires ObjC runtime (objc_msgSend) and AppKit framework.

const std = @import("std");
const objc = @import("objc");

// NSPasteboardTypeString is an extern NSString constant from AppKit.
extern "c" var NSPasteboardTypeString: objc.id;

/// Get the shared general pasteboard.
fn generalPasteboard() objc.id {
    const cls = objc.getClass("NSPasteboard") orelse @panic("NSPasteboard class not found");
    return objc.msgSend(objc.id, cls, objc.sel("generalPasteboard"), .{});
}

/// Read the current clipboard string. Returns null if clipboard is empty
/// or doesn't contain string data. The returned slice points into ObjC
/// memory valid until the next autorelease drain.
pub fn getString() ?[]const u8 {
    const pb = generalPasteboard();
    const ns_str = objc.msgSend(?objc.id, pb, objc.sel("stringForType:"), .{NSPasteboardTypeString});
    if (ns_str) |s| {
        const cstr = objc.fromNSString(s);
        return std.mem.span(cstr);
    }
    return null;
}

/// Write a string to the clipboard. Returns true on success.
pub fn setString(text: []const u8) bool {
    const pb = generalPasteboard();

    // clearContents returns the new change count
    _ = objc.msgSend(objc.NSInteger, pb, objc.sel("clearContents"), .{});

    const ns_str = objc.nsStringFromSlice(text);
    const result = objc.msgSend(objc.BOOL, pb, objc.sel("setString:forType:"), .{
        ns_str,
        NSPasteboardTypeString,
    });
    return result != objc.NO;
}

// ── Tests ────────────────────────────────────────────────────────────

test "NSPasteboard class exists" {
    try std.testing.expect(objc.getClass("NSPasteboard") != null);
}

test "clipboard write then read round-trip" {
    const test_str = "lcl-bridge-test-clipboard-42";
    try std.testing.expect(setString(test_str));

    const result = getString();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(test_str, result.?);
}
