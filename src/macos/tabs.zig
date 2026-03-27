/// Tab management using NSWindow tab groups.
/// Each tab is a separate NSWindow in the same tab group.

const objc = @import("objc");
const window = @import("window");

/// Create a new tab in the same window group as `existing_window`.
/// `content_view` is the terminal view for the new tab.
pub fn newTab(existing_window: objc.id, content_view: objc.id, title: [*:0]const u8) objc.id {
    return window.addTabbedWindow(existing_window, content_view, title);
}

/// Get the currently selected tab's window.
pub fn selectedTab(win: objc.id) objc.id {
    return objc.msgSend(objc.id, win, objc.sel("selectedTabViewItem"), .{});
}
