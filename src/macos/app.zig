/// NSApplication setup and menu bar construction.
/// All via objc_msgSend — no Swift, no NIBs.

const objc = @import("objc");

/// Create and run the NSApplication.
/// This function does not return (NSApplication.run blocks forever).
pub fn runApp(app_delegate_class: objc.Class) noreturn {
    const NSApplication = objc.getClass("NSApplication") orelse @panic("NSApplication not found");
    const app = objc.msgSend(objc.id, NSApplication, objc.sel("sharedApplication"), .{});

    // Regular app with dock icon
    objc.msgSend(void, app, objc.sel("setActivationPolicy:"), .{@as(objc.NSInteger, 0)});

    // Create and set delegate
    const delegate = objc.init(objc.alloc(app_delegate_class));
    objc.msgSend(void, app, objc.sel("setDelegate:"), .{delegate});

    // Build menu bar
    setupMenuBar(app);

    // Activate and bring to front
    objc.msgSend(void, app, objc.sel("activateIgnoringOtherApps:"), .{objc.YES});

    // Also use NSRunningApplication to force focus
    const NSRunningApplication = objc.getClass("NSRunningApplication");
    if (NSRunningApplication) |cls| {
        const current = objc.msgSend(objc.id, cls, objc.sel("currentApplication"), .{});
        // NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps
        objc.msgSend(void, current, objc.sel("activateWithOptions:"), .{@as(objc.NSUInteger, 3)});
    }

    objc.msgSend(void, app, objc.sel("run"), .{});
    unreachable;
}

fn setupMenuBar(app: objc.id) void {
    const NSMenu = objc.getClass("NSMenu") orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;

    // Main menu bar
    const menu_bar = objc.init(objc.alloc(NSMenu));
    objc.msgSend(void, app, objc.sel("setMainMenu:"), .{menu_bar});

    // App menu
    const app_menu_item = objc.init(objc.alloc(NSMenuItem));
    objc.msgSend(void, menu_bar, objc.sel("addItem:"), .{app_menu_item});

    const app_menu = objc.msgSend(objc.id, objc.alloc(NSMenu), objc.sel("initWithTitle:"), .{
        objc.nsString("LCL"),
    });
    objc.msgSend(void, app_menu_item, objc.sel("setSubmenu:"), .{app_menu});

    // Quit item (Cmd+Q)
    addMenuItem(app_menu, "Quit LCL", "terminate:", "q");

    // Edit menu (for Cmd+C/V to work)
    const edit_item = objc.init(objc.alloc(NSMenuItem));
    objc.msgSend(void, menu_bar, objc.sel("addItem:"), .{edit_item});

    const edit_menu = objc.msgSend(objc.id, objc.alloc(NSMenu), objc.sel("initWithTitle:"), .{
        objc.nsString("Edit"),
    });
    objc.msgSend(void, edit_item, objc.sel("setSubmenu:"), .{edit_menu});

    addMenuItem(edit_menu, "Copy", "copy:", "c");
    addMenuItem(edit_menu, "Paste", "paste:", "v");
    addMenuItem(edit_menu, "Select All", "selectAll:", "a");

    // View menu
    const view_item = objc.init(objc.alloc(NSMenuItem));
    objc.msgSend(void, menu_bar, objc.sel("addItem:"), .{view_item});

    const view_menu = objc.msgSend(objc.id, objc.alloc(NSMenu), objc.sel("initWithTitle:"), .{
        objc.nsString("View"),
    });
    objc.msgSend(void, view_item, objc.sel("setSubmenu:"), .{view_menu});

    addMenuItem(view_menu, "New Tab", "newTab:", "t");
    addMenuItem(view_menu, "Split Vertical", "splitVertical:", "d");

    // Window menu
    const window_item = objc.init(objc.alloc(NSMenuItem));
    objc.msgSend(void, menu_bar, objc.sel("addItem:"), .{window_item});

    const window_menu = objc.msgSend(objc.id, objc.alloc(NSMenu), objc.sel("initWithTitle:"), .{
        objc.nsString("Window"),
    });
    objc.msgSend(void, window_item, objc.sel("setSubmenu:"), .{window_menu});

    addMenuItem(window_menu, "Minimize", "performMiniaturize:", "m");
    addMenuItem(window_menu, "Close", "performClose:", "w");

    // Tell NSApplication this is the Window menu (enables window list)
    objc.msgSend(void, app, objc.sel("setWindowsMenu:"), .{window_menu});
}

fn addMenuItem(menu: objc.id, title: [*:0]const u8, action: [*:0]const u8, key: [*:0]const u8) void {
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const item = objc.msgSend(objc.id, objc.alloc(NSMenuItem), objc.sel("initWithTitle:action:keyEquivalent:"), .{
        objc.nsString(title),
        objc.sel(action),
        objc.nsString(key),
    });
    objc.msgSend(void, menu, objc.sel("addItem:"), .{item});
}
