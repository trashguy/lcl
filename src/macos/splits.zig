/// Split panel management using NSSplitView.
/// Supports recursive splitting: a split contains either terminal
/// views or nested splits.

const objc = @import("objc");

pub const SplitDirection = enum {
    horizontal, // left/right
    vertical, // top/bottom
};

/// Split the given view's parent into two panes.
/// Replaces the view with an NSSplitView containing the original view
/// and the new_view. Returns the NSSplitView.
pub fn split(existing_view: objc.id, new_view: objc.id, direction: SplitDirection) objc.id {
    const NSSplitView = objc.getClass("NSSplitView") orelse @panic("NSSplitView not found");

    // Get the parent and frame
    const parent = objc.msgSend(?objc.id, existing_view, objc.sel("superview"), .{});
    const frame = objc.msgSend(objc.NSRect, existing_view, objc.sel("frame"), .{});

    // Create split view
    const split_view = objc.msgSend(objc.id, objc.alloc(NSSplitView), objc.sel("initWithFrame:"), .{frame});

    // Set orientation
    const is_vertical = direction == .horizontal; // NSSplitView.isVertical = horizontal splits
    objc.msgSend(void, split_view, objc.sel("setVertical:"), .{
        if (is_vertical) objc.YES else objc.NO,
    });

    // Set divider style (thin line)
    objc.msgSend(void, split_view, objc.sel("setDividerStyle:"), .{@as(objc.NSInteger, 2)}); // NSSplitViewDividerStyleThin

    // Remove existing view from parent and add split view in its place
    if (parent) |p| {
        objc.msgSend(void, split_view, objc.sel("setAutoresizingMask:"), .{
            @as(objc.NSUInteger, (1 << 1) | (1 << 4)), // NSViewWidthSizable | NSViewHeightSizable
        });
        objc.msgSend(void, existing_view, objc.sel("removeFromSuperview"), .{});
        objc.msgSend(void, p, objc.sel("addSubview:"), .{split_view});
    }

    // Add both views to the split
    objc.msgSend(void, split_view, objc.sel("addSubview:"), .{existing_view});
    objc.msgSend(void, split_view, objc.sel("addSubview:"), .{new_view});

    // Set equal sizes
    objc.msgSend(void, split_view, objc.sel("adjustSubviews"), .{});

    return split_view;
}

/// Replace the content view of a window with a split containing
/// the current content and a new view.
pub fn splitWindow(win: objc.id, new_view: objc.id, direction: SplitDirection) objc.id {
    const content = objc.msgSend(objc.id, win, objc.sel("contentView"), .{});
    const split_view = split(content, new_view, direction);
    objc.msgSend(void, win, objc.sel("setContentView:"), .{split_view});
    return split_view;
}
