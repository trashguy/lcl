/// LCL Settings window — Cmd+, opens this. Two tabs: Appearance and VM.
///
/// Architecture: a single NSTabView fills the window. Each control has a
/// tag; one shared action handler reads the sender, updates the in-memory
/// model, and writes ~/.config/lcl/<env>/lcl.toml back to disk. Appearance
/// changes also fire `on_appearance_changed` for live re-rendering.

const std = @import("std");
const objc = @import("objc");
const config_types = @import("config");
const toml = @import("toml");
const theme_mod = @import("theme");
const image = @import("image");

// libdispatch — used to bounce the rebuild result back to the main thread
// after the background build thread finishes.
extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_async(queue: *anyopaque, block: *const anyopaque) void;
fn mainQueue() *anyopaque {
    return &_dispatch_main_q;
}

// ── Public callbacks ────────────────────────────────────────────────

pub const AppearanceCallback = *const fn (config_types.LclConfig.Appearance) void;
pub var on_appearance_changed: ?AppearanceCallback = null;

// ── Module state ────────────────────────────────────────────────────

var settings_window: ?objc.id = null;
var settings_controller: ?objc.id = null;
var allocator: std.mem.Allocator = undefined;
var current_config: config_types.LclConfig = .{};
var env_name: []const u8 = "dev";
var class_registered: bool = false;

// Control references (held so we can update displays on stepper changes)
var font_field: ?objc.id = null;
var font_size_field: ?objc.id = null;
var font_size_stepper: ?objc.id = null;
var fg_well: ?objc.id = null;
var bg_well: ?objc.id = null;
var theme_popup: ?objc.id = null;
var scrollback_field: ?objc.id = null;
var scrollback_unlimited_check: ?objc.id = null;
var cpu_field: ?objc.id = null;
var cpu_stepper: ?objc.id = null;
var mem_field: ?objc.id = null;
var mem_stepper: ?objc.id = null;
var home_check: ?objc.id = null;
var keychain_check: ?objc.id = null;
var clipboard_check: ?objc.id = null;
var open_check: ?objc.id = null;
var rebuild_button: ?objc.id = null;
var rebuild_status_label: ?objc.id = null;
var rebuild_spinner: ?objc.id = null;

// Rebuild thread state. The button click spawns a background thread that
// runs the long-running buildImage call; when it returns it sets these
// fields and dispatches `rebuild_done_block` onto the main queue, which
// reads them and updates the UI.
var rebuild_in_progress: bool = false;
var rebuild_status_buf: [256]u8 = undefined;
var rebuild_status_len: usize = 0;
var rebuild_status_mu: std.Thread.Mutex = .{};

// Tags for the shared action dispatcher.
const TAG_FONT_FIELD: i32 = 1;
const TAG_FONT_SIZE: i32 = 2;
const TAG_FONT_SIZE_STEPPER: i32 = 3;
const TAG_FG_COLOR: i32 = 4;
const TAG_BG_COLOR: i32 = 5;
const TAG_CPU: i32 = 10;
const TAG_CPU_STEPPER: i32 = 11;
const TAG_MEM: i32 = 12;
const TAG_MEM_STEPPER: i32 = 13;
const TAG_MOUNT_HOME: i32 = 14;
const TAG_BRIDGE_KEYCHAIN: i32 = 15;
const TAG_BRIDGE_CLIPBOARD: i32 = 16;
const TAG_BRIDGE_OPEN: i32 = 17;
const TAG_THEME: i32 = 18;
const TAG_REBUILD: i32 = 19;
const TAG_SCROLLBACK_LINES: i32 = 20;
const TAG_SCROLLBACK_UNLIMITED: i32 = 21;

// ── Public API ──────────────────────────────────────────────────────

pub fn init(alloc: std.mem.Allocator, env: []const u8) void {
    allocator = alloc;
    env_name = env;
}

/// Show the settings window, creating and loading config on first call.
pub fn show() void {
    if (settings_window == null) {
        loadConfig();
        settings_window = createWindow();
    }
    const win = settings_window.?;
    objc.msgSend(void, win, objc.sel("center"), .{});
    objc.msgSend(void, win, objc.sel("makeKeyAndOrderFront:"), .{@as(?objc.id, null)});

    const NSApp = objc.getClass("NSApplication") orelse return;
    const app = objc.msgSend(objc.id, NSApp, objc.sel("sharedApplication"), .{});
    objc.msgSend(void, app, objc.sel("activateIgnoringOtherApps:"), .{objc.YES});
}

// ── Config load / save ──────────────────────────────────────────────

fn loadConfig() void {
    const dir = config_types.configPath(allocator, env_name) catch return;
    defer allocator.free(dir);
    const path = std.fs.path.join(allocator, &.{ dir, "lcl.toml" }) catch return;
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return;
    defer allocator.free(data);

    var parsed = toml.parse(allocator, data) catch return;
    defer parsed.deinit();

    // Copy out the parsed config — duplicate strings since parsed.deinit frees them.
    current_config = .{
        .environment = .{
            .name = allocator.dupe(u8, parsed.config.environment.name) catch "dev",
            .base = allocator.dupe(u8, parsed.config.environment.base) catch "archlinux:latest",
            .shell = allocator.dupe(u8, parsed.config.environment.shell) catch "/bin/zsh",
            .cpu = parsed.config.environment.cpu,
            .memory_mb = parsed.config.environment.memory_mb,
            .kernel = allocator.dupe(u8, parsed.config.environment.kernel) catch "vmlinuz",
            .initrd = if (parsed.config.environment.initrd) |i| allocator.dupe(u8, i) catch null else null,
            .rootfs = allocator.dupe(u8, parsed.config.environment.rootfs) catch "rootfs.raw",
            .cmdline = allocator.dupe(u8, parsed.config.environment.cmdline) catch "console=hvc0",
        },
        .mounts = .{ .home = parsed.config.mounts.home, .custom = &.{} },
        .bridge = parsed.config.bridge,
        .setup = .{ .packages = &.{}, .dotfiles = null },
        .appearance = .{
            .font = allocator.dupe(u8, parsed.config.appearance.font) catch "Menlo",
            .font_size = parsed.config.appearance.font_size,
            .fg_r = parsed.config.appearance.fg_r,
            .fg_g = parsed.config.appearance.fg_g,
            .fg_b = parsed.config.appearance.fg_b,
            .bg_r = parsed.config.appearance.bg_r,
            .bg_g = parsed.config.appearance.bg_g,
            .bg_b = parsed.config.appearance.bg_b,
            .theme = if (parsed.config.appearance.theme) |t|
                (allocator.dupe(u8, t) catch null)
            else
                null,
            .scrollback_lines = parsed.config.appearance.scrollback_lines,
            .scrollback_unlimited = parsed.config.appearance.scrollback_unlimited,
        },
    };
}

fn saveConfig() void {
    const dir = config_types.configPath(allocator, env_name) catch return;
    defer allocator.free(dir);
    const path = std.fs.path.join(allocator, &.{ dir, "lcl.toml" }) catch return;
    defer allocator.free(path);

    var buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    config_types.serialize(current_config, stream.writer()) catch return;

    std.fs.cwd().writeFile(.{ .sub_path = path, .data = stream.getWritten() }) catch {};
}

// ── Window construction ─────────────────────────────────────────────

fn createWindow() objc.id {
    ensureControllerClass();

    const NSWindow = objc.getClass("NSWindow") orelse @panic("NSWindow");
    const NSTabView = objc.getClass("NSTabView") orelse @panic("NSTabView");
    const NSTabViewItem = objc.getClass("NSTabViewItem") orelse @panic("NSTabViewItem");

    const frame = objc.NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 520, .height = 380 },
    };

    // titled (1) | closable (2) | miniaturizable (4)
    const mask: objc.NSUInteger = 1 | 2 | 4;

    const win = objc.msgSend(objc.id, objc.alloc(NSWindow), objc.sel("initWithContentRect:styleMask:backing:defer:"), .{
        frame,
        mask,
        @as(objc.NSUInteger, 2), // NSBackingStoreBuffered
        objc.NO,
    });

    objc.msgSend(void, win, objc.sel("setTitle:"), .{objc.nsString("LCL Settings")});
    objc.msgSend(void, win, objc.sel("setReleasedWhenClosed:"), .{objc.NO});

    // Create the controller instance — single shared target for all controls.
    const cls = objc.getClass("LCLSettingsController") orelse @panic("LCLSettingsController not found");
    settings_controller = objc.init(objc.alloc(cls));

    const tab_view = objc.init(objc.alloc(NSTabView));
    objc.msgSend(void, tab_view, objc.sel("setFrame:"), .{frame});

    const appearance_item = objc.msgSend(objc.id, objc.alloc(NSTabViewItem), objc.sel("initWithIdentifier:"), .{objc.nsString("appearance")});
    objc.msgSend(void, appearance_item, objc.sel("setLabel:"), .{objc.nsString("Appearance")});
    objc.msgSend(void, appearance_item, objc.sel("setView:"), .{buildAppearanceView()});
    objc.msgSend(void, tab_view, objc.sel("addTabViewItem:"), .{appearance_item});

    const vm_item = objc.msgSend(objc.id, objc.alloc(NSTabViewItem), objc.sel("initWithIdentifier:"), .{objc.nsString("vm")});
    objc.msgSend(void, vm_item, objc.sel("setLabel:"), .{objc.nsString("VM")});
    objc.msgSend(void, vm_item, objc.sel("setView:"), .{buildVmView()});
    objc.msgSend(void, tab_view, objc.sel("addTabViewItem:"), .{vm_item});

    objc.msgSend(void, win, objc.sel("setContentView:"), .{tab_view});

    return win;
}

// ── Tab views ───────────────────────────────────────────────────────

fn buildAppearanceView() objc.id {
    const NSView = objc.getClass("NSView") orelse @panic("NSView");
    const view = objc.init(objc.alloc(NSView));

    const target = settings_controller.?;
    const action = objc.sel("onSettingChanged:");

    // Layout: simple absolute frames. Y measured from top of the tab content area.
    // Tab content area is roughly 504 wide × 320 tall.
    var y: f64 = 280;
    const row_h: f64 = 32;
    const label_x: f64 = 20;
    const label_w: f64 = 160;
    const ctrl_x: f64 = 200;

    // Font
    addLabel(view, "Font", label_x, y, label_w);
    var f = objc.NSRect{
        .origin = .{ .x = ctrl_x, .y = y },
        .size = .{ .width = 200, .height = 22 },
    };
    var font_buf: [256]u8 = undefined;
    const font_z = std.fmt.bufPrintZ(&font_buf, "{s}", .{current_config.appearance.font}) catch "Menlo";
    font_field = makeTextField(&f, font_z, target, action, TAG_FONT_FIELD);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{font_field.?});
    y -= row_h;

    // Font size
    addLabel(view, "Font size", label_x, y, label_w);
    var size_buf: [32]u8 = undefined;
    const size_str = std.fmt.bufPrintZ(&size_buf, "{d:.0}", .{current_config.appearance.font_size}) catch "14";
    f = .{ .origin = .{ .x = ctrl_x, .y = y }, .size = .{ .width = 60, .height = 22 } };
    font_size_field = makeTextField(&f, size_str, target, action, TAG_FONT_SIZE);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{font_size_field.?});

    f = .{ .origin = .{ .x = ctrl_x + 60 + 4, .y = y }, .size = .{ .width = 19, .height = 27 } };
    font_size_stepper = makeStepper(&f, current_config.appearance.font_size, 8, 72, 1, target, action, TAG_FONT_SIZE_STEPPER);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{font_size_stepper.?});
    y -= row_h;

    // Foreground color
    addLabel(view, "Foreground", label_x, y, label_w);
    f = .{ .origin = .{ .x = ctrl_x, .y = y }, .size = .{ .width = 50, .height = 24 } };
    fg_well = makeColorWell(&f, current_config.appearance.fg_r, current_config.appearance.fg_g, current_config.appearance.fg_b, target, action, TAG_FG_COLOR);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{fg_well.?});
    y -= row_h;

    // Background color
    addLabel(view, "Background", label_x, y, label_w);
    f = .{ .origin = .{ .x = ctrl_x, .y = y }, .size = .{ .width = 50, .height = 24 } };
    bg_well = makeColorWell(&f, current_config.appearance.bg_r, current_config.appearance.bg_g, current_config.appearance.bg_b, target, action, TAG_BG_COLOR);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{bg_well.?});
    y -= row_h;

    // Theme picker — when set, overrides the fg/bg colors above.
    addLabel(view, "Theme", label_x, y, label_w);
    f = .{ .origin = .{ .x = ctrl_x, .y = y }, .size = .{ .width = 220, .height = 26 } };
    theme_popup = makeThemePopup(&f, current_config.appearance.theme, target, action, TAG_THEME);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{theme_popup.?});
    y -= row_h;

    addLabel(view, "Themes override the fg/bg colors above.", label_x, y - 4, 400);
    y -= row_h;

    // Scrollback — line count + unlimited checkbox. The field is
    // disabled while "Unlimited" is on; reading it back from the field
    // when toggling off keeps the user's previous value visible.
    addLabel(view, "Scrollback", label_x, y, label_w);
    var sb_buf: [16]u8 = undefined;
    const sb_str = std.fmt.bufPrintZ(&sb_buf, "{d}", .{current_config.appearance.scrollback_lines}) catch "1000";
    f = .{ .origin = .{ .x = ctrl_x, .y = y }, .size = .{ .width = 80, .height = 22 } };
    scrollback_field = makeTextField(&f, sb_str, target, action, TAG_SCROLLBACK_LINES);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{scrollback_field.?});

    f = .{ .origin = .{ .x = ctrl_x + 80 + 12, .y = y }, .size = .{ .width = 130, .height = 22 } };
    scrollback_unlimited_check = makeCheckbox(&f, "Unlimited", current_config.appearance.scrollback_unlimited, target, action, TAG_SCROLLBACK_UNLIMITED);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{scrollback_unlimited_check.?});

    // Disable the line-count field if unlimited is on at load time.
    objc.msgSend(void, scrollback_field.?, objc.sel("setEnabled:"), .{
        if (current_config.appearance.scrollback_unlimited) objc.NO else objc.YES,
    });

    return view;
}

fn makeThemePopup(frame: *const objc.NSRect, current: ?[]const u8, target: objc.id, action: objc.SEL, tag: i32) objc.id {
    const NSPopUpButton = objc.getClass("NSPopUpButton") orelse @panic("NSPopUpButton");
    const popup = objc.msgSend(objc.id, objc.alloc(NSPopUpButton), objc.sel("initWithFrame:pullsDown:"), .{
        frame.*, objc.NO,
    });

    objc.msgSend(void, popup, objc.sel("addItemWithTitle:"), .{objc.nsString("None")});
    for (theme_mod.bundled_names) |n| {
        var buf: [64:0]u8 = undefined;
        const len = @min(n.len, buf.len);
        @memcpy(buf[0..len], n[0..len]);
        buf[len] = 0;
        objc.msgSend(void, popup, objc.sel("addItemWithTitle:"), .{objc.nsString(@ptrCast(&buf))});
    }

    if (current) |name| if (name.len > 0) {
        var buf: [64:0]u8 = undefined;
        const len = @min(name.len, buf.len);
        @memcpy(buf[0..len], name[0..len]);
        buf[len] = 0;
        objc.msgSend(void, popup, objc.sel("selectItemWithTitle:"), .{objc.nsString(@ptrCast(&buf))});
    };

    objc.msgSend(void, popup, objc.sel("setTag:"), .{@as(objc.NSInteger, tag)});
    objc.msgSend(void, popup, objc.sel("setTarget:"), .{target});
    objc.msgSend(void, popup, objc.sel("setAction:"), .{action});
    return popup;
}

fn buildVmView() objc.id {
    const NSView = objc.getClass("NSView") orelse @panic("NSView");
    const view = objc.init(objc.alloc(NSView));

    const target = settings_controller.?;
    const action = objc.sel("onSettingChanged:");

    var y: f64 = 280;
    const row_h: f64 = 32;
    const label_x: f64 = 20;
    const label_w: f64 = 160;
    const ctrl_x: f64 = 200;

    // CPU
    addLabel(view, "CPU cores", label_x, y, label_w);
    var cpu_buf: [16]u8 = undefined;
    const cpu_str = std.fmt.bufPrintZ(&cpu_buf, "{d}", .{current_config.environment.cpu}) catch "4";
    var f = objc.NSRect{
        .origin = .{ .x = ctrl_x, .y = y },
        .size = .{ .width = 60, .height = 22 },
    };
    cpu_field = makeTextField(&f, cpu_str, target, action, TAG_CPU);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{cpu_field.?});

    f = .{ .origin = .{ .x = ctrl_x + 60 + 4, .y = y }, .size = .{ .width = 19, .height = 27 } };
    cpu_stepper = makeStepper(&f, @as(f64, @floatFromInt(current_config.environment.cpu)), 1, 16, 1, target, action, TAG_CPU_STEPPER);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{cpu_stepper.?});
    y -= row_h;

    // Memory
    addLabel(view, "Memory (MB)", label_x, y, label_w);
    var mem_buf: [16]u8 = undefined;
    const mem_str = std.fmt.bufPrintZ(&mem_buf, "{d}", .{current_config.environment.memory_mb}) catch "4096";
    f = .{ .origin = .{ .x = ctrl_x, .y = y }, .size = .{ .width = 80, .height = 22 } };
    mem_field = makeTextField(&f, mem_str, target, action, TAG_MEM);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{mem_field.?});

    f = .{ .origin = .{ .x = ctrl_x + 80 + 4, .y = y }, .size = .{ .width = 19, .height = 27 } };
    mem_stepper = makeStepper(&f, @as(f64, @floatFromInt(current_config.environment.memory_mb)), 256, 65536, 256, target, action, TAG_MEM_STEPPER);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{mem_stepper.?});
    y -= row_h;

    // Mount home
    f = .{ .origin = .{ .x = ctrl_x, .y = y }, .size = .{ .width = 220, .height = 22 } };
    home_check = makeCheckbox(&f, "Mount host home directory", current_config.mounts.home, target, action, TAG_MOUNT_HOME);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{home_check.?});
    y -= row_h;

    // Bridge toggles
    addLabel(view, "Bridge features", label_x, y, label_w);
    f = .{ .origin = .{ .x = ctrl_x, .y = y }, .size = .{ .width = 180, .height = 22 } };
    keychain_check = makeCheckbox(&f, "Keychain", current_config.bridge.keychain, target, action, TAG_BRIDGE_KEYCHAIN);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{keychain_check.?});
    y -= row_h - 8;

    f = .{ .origin = .{ .x = ctrl_x, .y = y }, .size = .{ .width = 180, .height = 22 } };
    clipboard_check = makeCheckbox(&f, "Clipboard", current_config.bridge.clipboard, target, action, TAG_BRIDGE_CLIPBOARD);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{clipboard_check.?});
    y -= row_h - 8;

    f = .{ .origin = .{ .x = ctrl_x, .y = y }, .size = .{ .width = 180, .height = 22 } };
    open_check = makeCheckbox(&f, "Open URLs", current_config.bridge.open, target, action, TAG_BRIDGE_OPEN);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{open_check.?});
    y -= row_h;

    // Rebuild rootfs
    addLabel(view, "Rootfs", label_x, y, label_w);
    f = .{ .origin = .{ .x = ctrl_x, .y = y - 2 }, .size = .{ .width = 180, .height = 28 } };
    rebuild_button = makePushButton(&f, "Rebuild rootfs…", target, action, TAG_REBUILD);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{rebuild_button.?});

    // Spinner shown next to the button while a rebuild is in flight.
    const spin_frame = objc.NSRect{
        .origin = .{ .x = ctrl_x + 180 + 8, .y = y + 2 },
        .size = .{ .width = 20, .height = 20 },
    };
    rebuild_spinner = makeSpinner(&spin_frame);
    objc.msgSend(void, view, objc.sel("addSubview:"), .{rebuild_spinner.?});
    y -= row_h;

    // Status label updated from the rebuild thread. Anchored at the left
    // margin so the full message has the entire tab width available.
    const status_frame = objc.NSRect{
        .origin = .{ .x = label_x, .y = y - 6 },
        .size = .{ .width = 480, .height = 17 },
    };
    rebuild_status_label = makeMutableLabel(&status_frame, "");
    objc.msgSend(void, view, objc.sel("addSubview:"), .{rebuild_status_label.?});
    y -= row_h;

    // Help text
    addLabel(view, "VM changes apply on next start. Rebuild requires the VM to be stopped.", label_x, y - 8, 480);

    return view;
}

// ── Control factories ───────────────────────────────────────────────

fn addLabel(view: objc.id, text: [*:0]const u8, x: f64, y: f64, w: f64) void {
    const NSTextField = objc.getClass("NSTextField") orelse return;
    const frame = objc.NSRect{
        .origin = .{ .x = x, .y = y + 4 },
        .size = .{ .width = w, .height = 17 },
    };
    const label = objc.msgSend(objc.id, NSTextField, objc.sel("labelWithString:"), .{objc.nsString(text)});
    objc.msgSend(void, label, objc.sel("setFrame:"), .{frame});
    objc.msgSend(void, view, objc.sel("addSubview:"), .{label});
}

fn makeTextField(frame: *const objc.NSRect, value: [*:0]const u8, target: objc.id, action: objc.SEL, tag: i32) objc.id {
    const NSTextField = objc.getClass("NSTextField") orelse @panic("NSTextField");
    const tf = objc.msgSend(objc.id, objc.alloc(NSTextField), objc.sel("initWithFrame:"), .{frame.*});
    objc.msgSend(void, tf, objc.sel("setStringValue:"), .{objc.nsString(value)});
    objc.msgSend(void, tf, objc.sel("setTag:"), .{@as(objc.NSInteger, tag)});
    objc.msgSend(void, tf, objc.sel("setTarget:"), .{target});
    objc.msgSend(void, tf, objc.sel("setAction:"), .{action});
    return tf;
}

fn makeStepper(frame: *const objc.NSRect, value: f64, min_v: f64, max_v: f64, step: f64, target: objc.id, action: objc.SEL, tag: i32) objc.id {
    const NSStepper = objc.getClass("NSStepper") orelse @panic("NSStepper");
    const st = objc.msgSend(objc.id, objc.alloc(NSStepper), objc.sel("initWithFrame:"), .{frame.*});
    objc.msgSend(void, st, objc.sel("setMinValue:"), .{min_v});
    objc.msgSend(void, st, objc.sel("setMaxValue:"), .{max_v});
    objc.msgSend(void, st, objc.sel("setIncrement:"), .{step});
    objc.msgSend(void, st, objc.sel("setDoubleValue:"), .{value});
    objc.msgSend(void, st, objc.sel("setTag:"), .{@as(objc.NSInteger, tag)});
    objc.msgSend(void, st, objc.sel("setTarget:"), .{target});
    objc.msgSend(void, st, objc.sel("setAction:"), .{action});
    return st;
}

fn makeColorWell(frame: *const objc.NSRect, r: f32, g: f32, b: f32, target: objc.id, action: objc.SEL, tag: i32) objc.id {
    const NSColorWell = objc.getClass("NSColorWell") orelse @panic("NSColorWell");
    const NSColor = objc.getClass("NSColor") orelse @panic("NSColor");

    const well = objc.msgSend(objc.id, objc.alloc(NSColorWell), objc.sel("initWithFrame:"), .{frame.*});
    const color = objc.msgSend(objc.id, NSColor, objc.sel("colorWithSRGBRed:green:blue:alpha:"), .{
        @as(f64, @floatCast(r)),
        @as(f64, @floatCast(g)),
        @as(f64, @floatCast(b)),
        @as(f64, 1.0),
    });
    objc.msgSend(void, well, objc.sel("setColor:"), .{color});
    objc.msgSend(void, well, objc.sel("setTag:"), .{@as(objc.NSInteger, tag)});
    objc.msgSend(void, well, objc.sel("setTarget:"), .{target});
    objc.msgSend(void, well, objc.sel("setAction:"), .{action});
    return well;
}

fn makePushButton(frame: *const objc.NSRect, title: [*:0]const u8, target: objc.id, action: objc.SEL, tag: i32) objc.id {
    const NSButton = objc.getClass("NSButton") orelse @panic("NSButton");
    const btn = objc.msgSend(objc.id, NSButton, objc.sel("buttonWithTitle:target:action:"), .{
        objc.nsString(title), target, action,
    });
    objc.msgSend(void, btn, objc.sel("setFrame:"), .{frame.*});
    objc.msgSend(void, btn, objc.sel("setTag:"), .{@as(objc.NSInteger, tag)});
    return btn;
}

fn makeMutableLabel(frame: *const objc.NSRect, text: [*:0]const u8) objc.id {
    const NSTextField = objc.getClass("NSTextField") orelse @panic("NSTextField");
    const lbl = objc.msgSend(objc.id, NSTextField, objc.sel("labelWithString:"), .{objc.nsString(text)});
    objc.msgSend(void, lbl, objc.sel("setFrame:"), .{frame.*});
    return lbl;
}

fn makeSpinner(frame: *const objc.NSRect) objc.id {
    const NSProgressIndicator = objc.getClass("NSProgressIndicator") orelse @panic("NSProgressIndicator");
    const spin = objc.msgSend(objc.id, objc.alloc(NSProgressIndicator), objc.sel("initWithFrame:"), .{frame.*});
    // NSProgressIndicatorStyleSpinning = 1
    objc.msgSend(void, spin, objc.sel("setStyle:"), .{@as(objc.NSUInteger, 1)});
    // NSControlSizeSmall = 1
    objc.msgSend(void, spin, objc.sel("setControlSize:"), .{@as(objc.NSUInteger, 1)});
    objc.msgSend(void, spin, objc.sel("setDisplayedWhenStopped:"), .{objc.NO});
    return spin;
}

fn makeCheckbox(frame: *const objc.NSRect, title: [*:0]const u8, on: bool, target: objc.id, action: objc.SEL, tag: i32) objc.id {
    const NSButton = objc.getClass("NSButton") orelse @panic("NSButton");
    const btn = objc.msgSend(objc.id, NSButton, objc.sel("checkboxWithTitle:target:action:"), .{
        objc.nsString(title),
        target,
        action,
    });
    objc.msgSend(void, btn, objc.sel("setFrame:"), .{frame.*});
    objc.msgSend(void, btn, objc.sel("setState:"), .{@as(objc.NSInteger, if (on) 1 else 0)});
    objc.msgSend(void, btn, objc.sel("setTag:"), .{@as(objc.NSInteger, tag)});
    return btn;
}

// ── Controller class (target for all control actions) ──────────────

extern "c" fn objc_allocateClassPair(superclass: ?objc.Class, name: [*:0]const u8, extra_bytes: usize) ?objc.Class;

fn ensureControllerClass() void {
    if (class_registered) return;
    const NSObject = objc.getClass("NSObject") orelse @panic("NSObject");
    const cls = objc_allocateClassPair(NSObject, "LCLSettingsController", 0) orelse @panic("alloc class");
    _ = objc.addMethod(cls, objc.sel("onSettingChanged:"), @ptrCast(&onSettingChanged), "v@:@");
    objc.registerClass(cls);
    class_registered = true;
}

fn onSettingChanged(_: *const anyopaque, _: objc.SEL, sender: objc.id) callconv(.c) void {
    const tag: objc.NSInteger = objc.msgSend(objc.NSInteger, sender, objc.sel("tag"), .{});

    switch (tag) {
        TAG_FONT_FIELD => {
            const ns = objc.msgSend(objc.id, sender, objc.sel("stringValue"), .{});
            const cstr = objc.fromNSString(ns);
            updateFont(std.mem.span(cstr));
        },
        TAG_FONT_SIZE => {
            const v = objc.msgSend(f64, sender, objc.sel("doubleValue"), .{});
            updateFontSize(@floatCast(v));
            // Reflect in stepper
            if (font_size_stepper) |st| objc.msgSend(void, st, objc.sel("setDoubleValue:"), .{v});
        },
        TAG_FONT_SIZE_STEPPER => {
            const v = objc.msgSend(f64, sender, objc.sel("doubleValue"), .{});
            updateFontSize(@floatCast(v));
            if (font_size_field) |tf| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrintZ(&buf, "{d:.0}", .{v}) catch "14";
                objc.msgSend(void, tf, objc.sel("setStringValue:"), .{objc.nsString(s)});
            }
        },
        TAG_FG_COLOR => {
            const ns_color = objc.msgSend(objc.id, sender, objc.sel("color"), .{});
            const rgb = readSrgb(ns_color);
            current_config.appearance.fg_r = rgb[0];
            current_config.appearance.fg_g = rgb[1];
            current_config.appearance.fg_b = rgb[2];
            applyAndSave();
        },
        TAG_BG_COLOR => {
            const ns_color = objc.msgSend(objc.id, sender, objc.sel("color"), .{});
            const rgb = readSrgb(ns_color);
            current_config.appearance.bg_r = rgb[0];
            current_config.appearance.bg_g = rgb[1];
            current_config.appearance.bg_b = rgb[2];
            applyAndSave();
        },
        TAG_CPU => {
            const v = objc.msgSend(f64, sender, objc.sel("doubleValue"), .{});
            current_config.environment.cpu = @intFromFloat(@max(@as(f64, 1), v));
            if (cpu_stepper) |st| objc.msgSend(void, st, objc.sel("setDoubleValue:"), .{v});
            saveConfig();
        },
        TAG_CPU_STEPPER => {
            const v = objc.msgSend(f64, sender, objc.sel("doubleValue"), .{});
            current_config.environment.cpu = @intFromFloat(v);
            if (cpu_field) |tf| {
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrintZ(&buf, "{d}", .{current_config.environment.cpu}) catch "4";
                objc.msgSend(void, tf, objc.sel("setStringValue:"), .{objc.nsString(s)});
            }
            saveConfig();
        },
        TAG_MEM => {
            const v = objc.msgSend(f64, sender, objc.sel("doubleValue"), .{});
            current_config.environment.memory_mb = @intFromFloat(@max(@as(f64, 256), v));
            if (mem_stepper) |st| objc.msgSend(void, st, objc.sel("setDoubleValue:"), .{v});
            saveConfig();
        },
        TAG_MEM_STEPPER => {
            const v = objc.msgSend(f64, sender, objc.sel("doubleValue"), .{});
            current_config.environment.memory_mb = @intFromFloat(v);
            if (mem_field) |tf| {
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrintZ(&buf, "{d}", .{current_config.environment.memory_mb}) catch "4096";
                objc.msgSend(void, tf, objc.sel("setStringValue:"), .{objc.nsString(s)});
            }
            saveConfig();
        },
        TAG_MOUNT_HOME => {
            current_config.mounts.home = boolFromState(sender);
            saveConfig();
        },
        TAG_BRIDGE_KEYCHAIN => {
            current_config.bridge.keychain = boolFromState(sender);
            saveConfig();
        },
        TAG_BRIDGE_CLIPBOARD => {
            current_config.bridge.clipboard = boolFromState(sender);
            saveConfig();
        },
        TAG_BRIDGE_OPEN => {
            current_config.bridge.open = boolFromState(sender);
            saveConfig();
        },
        TAG_THEME => {
            const ns_title = objc.msgSend(?objc.id, sender, objc.sel("titleOfSelectedItem"), .{}) orelse return;
            const cstr = objc.fromNSString(ns_title);
            const title = std.mem.span(cstr);
            updateTheme(title);
        },
        TAG_REBUILD => startRebuild(),
        TAG_SCROLLBACK_LINES => {
            const value = readUintField(sender) orelse return;
            // Clamp to a sane window. 100 lines is the floor; below that
            // scrollback has no real value. Upper bound matches the
            // "Unlimited" cap, since exceeding it would be a lie.
            const clamped: u32 = @max(100, @min(value, config_types.scrollback_unlimited_cap));
            current_config.appearance.scrollback_lines = clamped;
            applyAndSave();
        },
        TAG_SCROLLBACK_UNLIMITED => {
            const on = boolFromState(sender);
            current_config.appearance.scrollback_unlimited = on;
            // Mirror the disabled/enabled state on the line-count field
            // so the UI matches the active mode.
            if (scrollback_field) |fld| {
                objc.msgSend(void, fld, objc.sel("setEnabled:"), .{
                    if (on) objc.NO else objc.YES,
                });
            }
            applyAndSave();
        },
        else => {},
    }
}

/// Read an NSTextField's stringValue and parse it as a u32. Returns
/// null if the field is missing or contains non-numeric text.
fn readUintField(sender: objc.id) ?u32 {
    const ns_str = objc.msgSend(?objc.id, sender, objc.sel("stringValue"), .{}) orelse return null;
    const cstr = objc.fromNSString(ns_str);
    const slice = std.mem.span(cstr);
    return std.fmt.parseInt(u32, slice, 10) catch null;
}

fn boolFromState(sender: objc.id) bool {
    const state: objc.NSInteger = objc.msgSend(objc.NSInteger, sender, objc.sel("state"), .{});
    return state != 0;
}

fn readSrgb(ns_color: objc.id) [3]f32 {
    const NSColorSpace = objc.getClass("NSColorSpace") orelse return .{ 0, 0, 0 };
    const srgb = objc.msgSend(objc.id, NSColorSpace, objc.sel("sRGBColorSpace"), .{});
    const converted = objc.msgSend(?objc.id, ns_color, objc.sel("colorUsingColorSpace:"), .{srgb}) orelse return .{ 0, 0, 0 };
    const r = objc.msgSend(f64, converted, objc.sel("redComponent"), .{});
    const g = objc.msgSend(f64, converted, objc.sel("greenComponent"), .{});
    const b = objc.msgSend(f64, converted, objc.sel("blueComponent"), .{});
    return .{ @floatCast(r), @floatCast(g), @floatCast(b) };
}

fn updateTheme(title: []const u8) void {
    if (std.mem.eql(u8, title, "None")) {
        current_config.appearance.theme = null;
    } else {
        const dup = allocator.dupe(u8, title) catch return;
        current_config.appearance.theme = dup;
    }
    applyAndSave();
}

fn updateFont(name: []const u8) void {
    const dup = allocator.dupe(u8, name) catch return;
    // Free previous if it was heap-allocated; we don't track that strictly,
    // so leak the previous to avoid double-free of a literal default.
    current_config.appearance.font = dup;
    applyAndSave();
}

fn updateFontSize(size: f32) void {
    current_config.appearance.font_size = size;
    applyAndSave();
}

fn applyAndSave() void {
    if (on_appearance_changed) |cb| cb(current_config.appearance);
    saveConfig();
}

// ── Rebuild rootfs ──────────────────────────────────────────────────

fn startRebuild() void {
    if (rebuild_in_progress) return;

    if (!confirmRebuild()) return;

    rebuild_in_progress = true;
    setRebuildButtonEnabled(false, "Rebuilding…");
    startSpinner();
    setStatusMessage("Starting rebuild…");

    image.progress_callback = &rebuildProgressFromThread;

    const t = std.Thread.spawn(.{}, rebuildThread, .{}) catch {
        image.progress_callback = null;
        stopSpinner();
        setRebuildResult("Failed to spawn build thread", false);
        return;
    };
    t.detach();
}

fn startSpinner() void {
    const s = rebuild_spinner orelse return;
    objc.msgSend(void, s, objc.sel("startAnimation:"), .{@as(?objc.id, null)});
}

fn stopSpinner() void {
    const s = rebuild_spinner orelse return;
    objc.msgSend(void, s, objc.sel("stopAnimation:"), .{@as(?objc.id, null)});
}

/// Called by buildImage on its background thread for each progress
/// milestone. Stashes the message and dispatches a UI update onto the main
/// queue.
fn rebuildProgressFromThread(msg: []const u8) void {
    rebuild_status_mu.lock();
    const n = @min(msg.len, rebuild_status_buf.len);
    @memcpy(rebuild_status_buf[0..n], msg[0..n]);
    rebuild_status_len = n;
    rebuild_status_mu.unlock();
    dispatch_async(mainQueue(), @ptrCast(&rebuild_progress_block));
}

const RebuildProgressFn = fn (*anyopaque) callconv(.c) void;
const RebuildProgressBlock = objc.Block(RebuildProgressFn);
var rebuild_progress_desc = objc.blockDescriptor(RebuildProgressBlock);
var rebuild_progress_block = RebuildProgressBlock{ .invoke = &onRebuildProgress, .descriptor = &rebuild_progress_desc };

fn onRebuildProgress(_: *anyopaque) callconv(.c) void {
    var z_buf: [257]u8 = undefined;
    rebuild_status_mu.lock();
    const n = rebuild_status_len;
    @memcpy(z_buf[0..n], rebuild_status_buf[0..n]);
    rebuild_status_mu.unlock();
    z_buf[n] = 0;
    setStatusMessageZ(@ptrCast(&z_buf));
}

fn confirmRebuild() bool {
    const NSAlert = objc.getClass("NSAlert") orelse return false;
    const alert = objc.init(objc.alloc(NSAlert));
    objc.msgSend(void, alert, objc.sel("setMessageText:"), .{objc.nsString("Rebuild rootfs?")});
    objc.msgSend(void, alert, objc.sel("setInformativeText:"), .{objc.nsString(
        "This downloads the latest distro tarball and overwrites rootfs.raw. Stop the VM first if it's running. The first boot afterwards will install the LCL package set.",
    )});
    // NSAlertStyleCritical = 2
    objc.msgSend(void, alert, objc.sel("setAlertStyle:"), .{@as(objc.NSUInteger, 2)});
    _ = objc.msgSend(objc.id, alert, objc.sel("addButtonWithTitle:"), .{objc.nsString("Rebuild")});
    _ = objc.msgSend(objc.id, alert, objc.sel("addButtonWithTitle:"), .{objc.nsString("Cancel")});

    const response: objc.NSInteger = objc.msgSend(objc.NSInteger, alert, objc.sel("runModal"), .{});
    return response == 1000; // NSAlertFirstButtonReturn
}

fn rebuildThread() void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Re-read the toml fresh so we pick up any [setup].packages the user has
    // edited since startup.
    const dir = config_types.configPath(a, env_name) catch {
        finishRebuild("Failed to resolve config path", false);
        return;
    };
    const path = std.fs.path.join(a, &.{ dir, "lcl.toml" }) catch {
        finishRebuild("Out of memory", false);
        return;
    };
    const data = std.fs.cwd().readFileAlloc(a, path, 1024 * 1024) catch {
        finishRebuild("Could not read lcl.toml", false);
        return;
    };
    var parsed = toml.parse(a, data) catch {
        finishRebuild("Failed to parse lcl.toml", false);
        return;
    };
    defer parsed.deinit();

    const dist = image.distro.Distro.fromBase(parsed.config.environment.base) orelse {
        finishRebuild("Unsupported base distro", false);
        return;
    };

    image.buildImage(a, env_name, dist, parsed.config.setup.packages) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Build failed: {s}", .{@errorName(err)}) catch "Build failed";
        finishRebuild(msg, false);
        return;
    };

    finishRebuild("Rebuild complete. Restart the VM to use the new rootfs.", true);
}

/// Stash the result string and bounce execution back onto the main thread
/// so we can safely touch the AppKit controls.
fn finishRebuild(msg: []const u8, success: bool) void {
    _ = success;
    rebuild_status_mu.lock();
    const n = @min(msg.len, rebuild_status_buf.len);
    @memcpy(rebuild_status_buf[0..n], msg[0..n]);
    rebuild_status_len = n;
    rebuild_status_mu.unlock();
    dispatch_async(mainQueue(), @ptrCast(&rebuild_done_block));
}

const RebuildDoneFn = fn (*anyopaque) callconv(.c) void;
const RebuildDoneBlock = objc.Block(RebuildDoneFn);
var rebuild_done_desc = objc.blockDescriptor(RebuildDoneBlock);
var rebuild_done_block = RebuildDoneBlock{ .invoke = &onRebuildDone, .descriptor = &rebuild_done_desc };

fn onRebuildDone(_: *anyopaque) callconv(.c) void {
    rebuild_in_progress = false;
    image.progress_callback = null;
    stopSpinner();
    setRebuildButtonEnabled(true, "Rebuild rootfs…");

    var z_buf: [257]u8 = undefined;
    rebuild_status_mu.lock();
    const n = rebuild_status_len;
    @memcpy(z_buf[0..n], rebuild_status_buf[0..n]);
    rebuild_status_mu.unlock();
    z_buf[n] = 0;
    setStatusMessageZ(@ptrCast(&z_buf));
}

fn setRebuildResult(msg: []const u8, success: bool) void {
    rebuild_in_progress = false;
    setRebuildButtonEnabled(true, "Rebuild rootfs…");
    _ = success;
    setStatusMessage(msg);
}

fn setRebuildButtonEnabled(enabled: bool, title: [*:0]const u8) void {
    const btn = rebuild_button orelse return;
    objc.msgSend(void, btn, objc.sel("setEnabled:"), .{if (enabled) objc.YES else objc.NO});
    objc.msgSend(void, btn, objc.sel("setTitle:"), .{objc.nsString(title)});
}

fn setStatusMessage(msg: []const u8) void {
    var buf: [257]u8 = undefined;
    const n = @min(msg.len, buf.len - 1);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
    setStatusMessageZ(@ptrCast(&buf));
}

fn setStatusMessageZ(text: [*:0]const u8) void {
    const lbl = rebuild_status_label orelse return;
    objc.msgSend(void, lbl, objc.sel("setStringValue:"), .{objc.nsString(text)});
}
