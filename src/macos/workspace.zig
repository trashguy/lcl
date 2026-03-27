/// NSWorkspace bindings for opening URLs and files.
/// Requires ObjC runtime (objc_msgSend) and AppKit framework.

const std = @import("std");
const objc = @import("objc");

/// Get the shared NSWorkspace instance.
fn sharedWorkspace() objc.id {
    const cls = objc.getClass("NSWorkspace") orelse @panic("NSWorkspace class not found");
    return objc.msgSend(objc.id, cls, objc.sel("sharedWorkspace"), .{});
}

/// Open a URL string or file path on the host.
/// Detects scheme (http://, https://, mailto:, etc.) to choose URL vs file path.
/// Returns true if the system accepted the open request.
pub fn open(target: []const u8) bool {
    const ws = sharedWorkspace();

    // Detect if this looks like a URL (has a scheme)
    const is_url = std.mem.indexOf(u8, target, "://") != null or
        std.mem.startsWith(u8, target, "mailto:");

    if (is_url) {
        const ns_str = objc.nsStringFromSlice(target);
        const url_cls = objc.getClass("NSURL") orelse @panic("NSURL class not found");
        const url = objc.msgSend(?objc.id, url_cls, objc.sel("URLWithString:"), .{ns_str});
        if (url) |u| {
            return objc.msgSend(objc.BOOL, ws, objc.sel("openURL:"), .{u}) != objc.NO;
        }
        return false;
    }

    // File path — use openURL with fileURLWithPath
    const ns_path = objc.nsStringFromSlice(target);
    const url_cls = objc.getClass("NSURL") orelse @panic("NSURL class not found");
    const file_url = objc.msgSend(objc.id, url_cls, objc.sel("fileURLWithPath:"), .{ns_path});
    return objc.msgSend(objc.BOOL, ws, objc.sel("openURL:"), .{file_url}) != objc.NO;
}

// ── Tests ────────────────────────────────────────────────────────────

test "NSWorkspace class exists" {
    try std.testing.expect(objc.getClass("NSWorkspace") != null);
}

test "sharedWorkspace is non-null" {
    const ws = sharedWorkspace();
    try std.testing.expect(ws != @as(?objc.id, null));
}
