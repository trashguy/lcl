/// NSWindow creation and delegate.

const objc = @import("objc");

var window_delegate_registered: bool = false;

/// Create a main window with the given content view.
pub fn createMainWindow(content_view: objc.id, title: [*:0]const u8) objc.id {
    const NSWindow = objc.getClass("NSWindow") orelse @panic("NSWindow not found");

    // Style mask: titled + closable + resizable + miniaturizable
    const style: objc.NSUInteger = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3);

    // Content rect
    const rect = objc.NSRect{
        .origin = .{ .x = 100, .y = 100 },
        .size = .{ .width = 800, .height = 600 },
    };

    const window = objc.msgSend(objc.id, objc.alloc(NSWindow), objc.sel("initWithContentRect:styleMask:backing:defer:"), .{
        rect,
        style,
        @as(objc.NSUInteger, 2), // NSBackingStoreBuffered
        objc.NO,
    });

    objc.msgSend(void, window, objc.sel("setTitle:"), .{objc.nsString(title)});
    objc.msgSend(void, window, objc.sel("setContentView:"), .{content_view});

    // Black background to match terminal
    const NSColor = objc.getClass("NSColor");
    if (NSColor) |cls| {
        const black = objc.msgSend(objc.id, cls, objc.sel("blackColor"), .{});
        objc.msgSend(void, window, objc.sel("setBackgroundColor:"), .{black});
    }

    objc.msgSend(void, window, objc.sel("makeKeyAndOrderFront:"), .{@as(?objc.id, null)});

    // Center on screen
    objc.msgSend(void, window, objc.sel("center"), .{});

    // Set delegate
    ensureWindowDelegateClass();
    const delegate_cls = objc.getClass("LCLWindowDelegate") orelse return window;
    const delegate = objc.init(objc.alloc(delegate_cls));
    objc.msgSend(void, window, objc.sel("setDelegate:"), .{delegate});

    // Enable window tabbing
    objc.msgSend(void, window, objc.sel("setTabbingMode:"), .{@as(objc.NSInteger, 0)}); // automatic

    return window;
}

/// Add a new tabbed window to an existing window.
pub fn addTabbedWindow(existing: objc.id, content_view: objc.id, title: [*:0]const u8) objc.id {
    const NSWindow = objc.getClass("NSWindow") orelse @panic("NSWindow not found");

    const style: objc.NSUInteger = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3);
    const rect = objc.NSRect{
        .origin = .{ .x = 100, .y = 100 },
        .size = .{ .width = 800, .height = 600 },
    };

    const new_window = objc.msgSend(objc.id, objc.alloc(NSWindow), objc.sel("initWithContentRect:styleMask:backing:defer:"), .{
        rect,
        style,
        @as(objc.NSUInteger, 2),
        objc.NO,
    });

    objc.msgSend(void, new_window, objc.sel("setTitle:"), .{objc.nsString(title)});
    objc.msgSend(void, new_window, objc.sel("setContentView:"), .{content_view});

    // Add as tabbed window (NSWindowAbove = 1)
    objc.msgSend(void, existing, objc.sel("addTabbedWindow:ordered:"), .{
        new_window,
        @as(objc.NSInteger, 1),
    });

    // Make it the selected tab
    objc.msgSend(void, new_window, objc.sel("makeKeyAndOrderFront:"), .{@as(?objc.id, null)});

    return new_window;
}

fn ensureWindowDelegateClass() void {
    if (window_delegate_registered) return;

    const cls = objc.createClass("LCLWindowDelegate") orelse return;

    // windowShouldClose: -> BOOL
    _ = objc.addMethod(
        cls,
        objc.sel("windowShouldClose:"),
        @ptrCast(&windowShouldClose),
        "c@:@",
    );

    objc.registerClass(cls);
    window_delegate_registered = true;
}

fn windowShouldClose(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) objc.BOOL {
    return objc.YES;
}

// ── NSRect / NSSize / NSPoint ───────────────────────────────────────
// These are passed by value in ObjC calls. We need to define the
// struct layout for Zig's msgSend to handle them correctly.

// Note: These are re-exported from objc.zig if they exist there.
// If not, they're defined here.
