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
var cpu_field: ?objc.id = null;
var cpu_stepper: ?objc.id = null;
var mem_field: ?objc.id = null;
var mem_stepper: ?objc.id = null;
var home_check: ?objc.id = null;
var keychain_check: ?objc.id = null;
var clipboard_check: ?objc.id = null;
var open_check: ?objc.id = null;

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

    return view;
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

    // Help text
    addLabel(view, "VM changes apply on next start.", label_x, y - 8, 400);

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
        else => {},
    }
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
