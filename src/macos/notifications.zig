/// UserNotifications bindings for posting macOS notifications.
/// Uses NSUserNotificationCenter (available without entitlements).

const std = @import("std");
const objc = @import("objc");

/// Post a macOS notification with a title and body.
pub fn postNotification(title: []const u8, body: []const u8) void {
    const NSUserNotification = objc.getClass("NSUserNotification") orelse {
        // NSUserNotification removed in newer macOS — fall back silently
        return;
    };

    const notification = objc.init(objc.alloc(NSUserNotification));
    objc.msgSend(void, notification, objc.sel("setTitle:"), .{objc.nsStringFromSlice(title)});
    objc.msgSend(void, notification, objc.sel("setInformativeText:"), .{objc.nsStringFromSlice(body)});

    const center_cls = objc.getClass("NSUserNotificationCenter") orelse return;
    const center = objc.msgSend(objc.id, center_cls, objc.sel("defaultUserNotificationCenter"), .{});
    objc.msgSend(void, center, objc.sel("deliverNotification:"), .{notification});
}

// ── Tests ────────────────────────────────────────────────────────────

test "notification classes exist or gracefully absent" {
    // NSUserNotification may be removed in future macOS.
    // The postNotification function handles this gracefully.
    // Just verify it doesn't crash.
    postNotification("LCL Test", "If you see this, notifications work!");
}
