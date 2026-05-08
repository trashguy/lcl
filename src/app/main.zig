/// LCL Terminal App — boots a VM and connects via vsock shell.

const std = @import("std");
const objc = @import("objc");
const app_ui = @import("app_mod");
const win_mod = @import("window");
const cell_mod = @import("cell");
const parser_mod = @import("parser");
const coretext = @import("coretext");
const terminal_view = @import("terminal_view");
const tabs = @import("tabs");
const session_mod = @import("session");
const shell_protocol = @import("shell_protocol");
const vz = @import("vz");
const config = @import("config");
const toml = @import("toml");
const theme_mod = @import("theme");
const vm_config = @import("vm_config");
const bridge_handler = @import("bridge_handler");
const ssh_agent = @import("ssh_agent_host");
const settings = @import("settings");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var global_font: ?coretext.FontInfo = null;
var global_machine: ?vz.VirtualMachine = null;
var primary_window: ?objc.id = null;

extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_async(queue: *anyopaque, block: *const anyopaque) void;
extern "c" fn dispatch_after(when: u64, queue: *anyopaque, block: *const anyopaque) void;
extern "c" fn dispatch_time(base: u64, delta: i64) u64;

fn mainQueue() *anyopaque { return &_dispatch_main_q; }

pub fn main() void {
    const cls = registerAppDelegate();
    app_ui.runApp(cls);
}

fn registerAppDelegate() objc.Class {
    const cls = objc.createClass("LCLAppDelegate") orelse @panic("Failed");
    _ = objc.addMethod(cls, objc.sel("applicationDidFinishLaunching:"), @ptrCast(&appDidFinishLaunching), "v@:@");
    _ = objc.addMethod(cls, objc.sel("applicationShouldTerminateAfterLastWindowClosed:"), @ptrCast(&shouldTerminate), "c@:@");
    _ = objc.addMethod(cls, objc.sel("applicationShouldTerminate:"), @ptrCast(&shouldTerminateApp), "L@:@");
    _ = objc.addMethod(cls, objc.sel("vmStart:"), @ptrCast(&vmStartAction), "v@:@");
    _ = objc.addMethod(cls, objc.sel("vmStop:"), @ptrCast(&vmStopAction), "v@:@");
    _ = objc.addMethod(cls, objc.sel("vmForceStop:"), @ptrCast(&vmForceStopAction), "v@:@");
    _ = objc.addMethod(cls, objc.sel("vmRestart:"), @ptrCast(&vmRestartAction), "v@:@");
    _ = objc.addMethod(cls, objc.sel("validateMenuItem:"), @ptrCast(&validateMenuItem), "c@:@");
    _ = objc.addMethod(cls, objc.sel("openSettings:"), @ptrCast(&openSettingsAction), "v@:@");
    _ = objc.addMethod(cls, objc.sel("newTab:"), @ptrCast(&newTabAction), "v@:@");
    objc.registerClass(cls);
    return objc.getClass("LCLAppDelegate") orelse @panic("Not found");
}

fn appDidFinishLaunching(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) void {
    const allocator = gpa.allocator();

    settings.init(allocator, "dev");
    settings.on_appearance_changed = &applyAppearance;

    const initial_appearance = readAppearance(allocator);

    global_font = coretext.createFont(toCString(initial_appearance.font), initial_appearance.font_size);
    applyColors(allocator, initial_appearance);

    session_mod.initRegistry(allocator);
    terminal_view.setViewLookup(&lookupViewState);
    terminal_view.setInputCallback(&onInput);
    win_mod.setResizeCallback(&onWindowResize);
    win_mod.setWillCloseCallback(&onWindowWillClose);

    // Boot VM first so the primary session has something to connect to.
    bootVm(allocator);

    // Create the primary session + window.
    const initial_cols: u16 = @max(20, @as(u16, @intFromFloat(800.0 / global_font.?.cell_width)));
    const initial_rows: u16 = @max(8, @as(u16, @intFromFloat(600.0 / global_font.?.cell_height)));

    const machine = global_machine orelse @panic("VM failed to init");
    const primary = session_mod.create(allocator, initial_cols, initial_rows, machine) catch @panic("OOM");
    applyScrollbackToSession(primary, initial_appearance);

    {
        const grid = &primary.grid;
        const msg = "Booting VM...\r\n";
        for (msg) |ch| grid.putChar(ch);
    }

    const view = terminal_view.createTerminalView(&primary.grid, &global_font.?);
    session_mod.bindView(primary, view) catch {};

    const win = win_mod.createMainWindow(view, "LCL Terminal");
    session_mod.bindWindow(primary, win) catch {};
    primary_window = win;
    terminal_view.applyBackgroundToWindow(win);

    objc.msgSend(void, win, objc.sel("center"), .{});
    objc.msgSend(void, win, objc.sel("orderFrontRegardless"), .{});
    objc.msgSend(void, win, objc.sel("makeKeyAndOrderFront:"), .{@as(?objc.id, null)});

    const NSApp = objc.getClass("NSApplication") orelse return;
    const ns_app = objc.msgSend(objc.id, NSApp, objc.sel("sharedApplication"), .{});
    objc.msgSend(void, ns_app, objc.sel("activateIgnoringOtherApps:"), .{objc.YES});

    session_mod.beginConnect(primary, 5);
    schedulePoll();
}

fn lookupViewState(view: objc.id) ?terminal_view.ViewState {
    const session = session_mod.byView(view) orelse return null;
    return .{ .grid = &session.grid };
}

fn onInput(view: objc.id, data: []const u8) void {
    const session = session_mod.byView(view) orelse return;
    session_mod.sendInput(session, data);
}

/// Build (and create the parent dir for) the serial-console log file path.
/// Returns an allocator-owned null-terminated slice; caller frees.
fn ensureConsoleLogPath(allocator: std.mem.Allocator, env_name: []const u8) ![:0]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const dir = try std.fs.path.join(allocator, &.{ home, "Library", "Logs", "LCL" });
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};
    const file_name = try std.fmt.allocPrint(allocator, "{s}-console.log", .{env_name});
    defer allocator.free(file_name);
    const full = try std.fs.path.join(allocator, &.{ dir, file_name });
    defer allocator.free(full);
    return try allocator.dupeZ(u8, full);
}

/// Tear down a session when its tab/window is about to close. Closes the
/// vsock connection (which kills the shell inside the VM via SIGHUP),
/// joins the read thread, and frees the grid.
fn onWindowWillClose(win: objc.id) void {
    const session = session_mod.byWindow(win) orelse return;
    session_mod.destroy(session);
    if (primary_window) |pw| {
        if (@intFromPtr(pw) == @intFromPtr(win)) primary_window = null;
    }
}

/// Window-resize callback. Looks up the session for this window,
/// recomputes grid dimensions from the view's bounds and the current
/// font metrics, resizes the grid, and forwards the new size to that
/// session's PTY.
fn onWindowResize(win: objc.id) void {
    const session = session_mod.byWindow(win) orelse return;
    const view = session.view orelse return;
    const font = global_font orelse return;

    const bounds = objc.msgSend(objc.NSRect, view, objc.sel("bounds"), .{});
    const cols_f = bounds.size.width / font.cell_width;
    const rows_f = bounds.size.height / font.cell_height;
    const new_cols: u16 = @intFromFloat(@max(@as(objc.CGFloat, 1.0), cols_f));
    const new_rows: u16 = @intFromFloat(@max(@as(objc.CGFloat, 1.0), rows_f));

    const grid = &session.grid;
    if (new_cols == grid.cols and new_rows == grid.rows) return;
    grid.resize(new_cols, new_rows) catch return;
    session_mod.sendResize(session, new_cols, new_rows);
    terminal_view.setNeedsDisplay(view);
}

// ── VM lifecycle ────────────────────────────────────────────────────

fn bootVm(allocator: std.mem.Allocator) void {
    const config_dir = config.configPath(allocator, "dev") catch return;
    const toml_path = std.fs.path.join(allocator, &.{ config_dir, "lcl.toml" }) catch return;
    const toml_data = std.fs.cwd().readFileAlloc(allocator, toml_path, 1024 * 1024) catch return;
    var parsed = toml.parse(allocator, toml_data) catch return;
    defer parsed.deinit();

    // Redirect serial console to ~/Library/Logs/LCL/<env>-console.log so
    // the user can `tail -f` it. The GUI process has no usable stdout when
    // launched from Finder.
    const log_path: ?[:0]u8 = ensureConsoleLogPath(allocator, "dev") catch null;
    defer if (log_path) |p| allocator.free(p);
    const log_path_z: ?[*:0]const u8 = if (log_path) |p| p.ptr else null;

    const vz_cfg = vm_config.buildVmConfig(parsed.config, config_dir, allocator, log_path_z) catch return;
    const machine = vz.VirtualMachine.initWithConfiguration(vz_cfg);
    global_machine = machine;

    if (vz.VirtioSocketDevice.fromVirtualMachine(machine)) |sd| {
        const bridge_listener = vz.createSocketListenerWithCallback(&onBridge, 5000);
        sd.setSocketListener(bridge_listener, 5000);

        const agent_listener = vz.createSocketListenerWithCallback(&onSshAgent, ssh_agent.ssh_agent_port);
        sd.setSocketListener(agent_listener, ssh_agent.ssh_agent_port);
    }

    startMachine(machine);
}

fn startMachine(machine: vz.VirtualMachine) void {
    machine.startWithCompletionHandler(@ptrCast(&start_block));
}

const StartFn = fn (*anyopaque, ?objc.id) callconv(.c) void;
const StartBlock = objc.Block(StartFn);
var start_desc = objc.blockDescriptor(StartBlock);
var start_block = StartBlock{ .invoke = &vmStarted, .descriptor = &start_desc };

fn vmStarted(_: *anyopaque, _: ?objc.id) callconv(.c) void {}

const StopFn = fn (*anyopaque, ?objc.id) callconv(.c) void;
const StopBlock = objc.Block(StopFn);
var force_stop_desc = objc.blockDescriptor(StopBlock);
var force_stop_block = StopBlock{ .invoke = &vmForceStopped, .descriptor = &force_stop_desc };

fn vmForceStopped(_: *anyopaque, _: ?objc.id) callconv(.c) void {}

var restart_stop_desc = objc.blockDescriptor(StopBlock);
var restart_stop_block = StopBlock{ .invoke = &vmStoppedForRestart, .descriptor = &restart_stop_desc };

fn vmStoppedForRestart(_: *anyopaque, _: ?objc.id) callconv(.c) void {
    const m = global_machine orelse return;
    if (m.canStart()) startMachine(m);
}

var quit_stop_desc = objc.blockDescriptor(StopBlock);
var quit_stop_block = StopBlock{ .invoke = &vmStoppedForQuit, .descriptor = &quit_stop_desc };

fn vmStoppedForQuit(_: *anyopaque, _: ?objc.id) callconv(.c) void {
    const NSApp = objc.getClass("NSApplication") orelse return;
    const app = objc.msgSend(objc.id, NSApp, objc.sel("sharedApplication"), .{});
    objc.msgSend(void, app, objc.sel("replyToApplicationShouldTerminate:"), .{objc.YES});
}

// ── Menu actions ────────────────────────────────────────────────────

fn vmStartAction(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) void {
    if (global_machine) |m| {
        if (m.canStart()) startMachine(m);
    } else {
        bootVm(gpa.allocator());
    }
}

fn vmStopAction(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) void {
    const m = global_machine orelse return;
    if (!m.canRequestStop()) return;
    var err_out: ?objc.id = null;
    _ = m.requestStopWithError(&err_out);
}

fn vmForceStopAction(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) void {
    const m = global_machine orelse return;
    if (!m.canStop()) return;
    m.stopWithCompletionHandler(@ptrCast(&force_stop_block));
}

fn vmRestartAction(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) void {
    const m = global_machine orelse return;
    if (!m.canStop()) return;
    m.stopWithCompletionHandler(@ptrCast(&restart_stop_block));
}

fn validateMenuItem(_: *const anyopaque, _: objc.SEL, item: objc.id) callconv(.c) objc.BOOL {
    const action_sel = objc.msgSend(?objc.SEL, item, objc.sel("action"), .{}) orelse return objc.YES;
    const a = @intFromPtr(action_sel);

    const state: ?vz.VmState = if (global_machine) |m| m.state() else null;

    if (a == @intFromPtr(objc.sel("vmStart:"))) {
        if (state == null) return objc.YES;
        return if (state.? == .stopped or state.? == .err) objc.YES else objc.NO;
    }
    if (a == @intFromPtr(objc.sel("vmStop:"))) {
        if (global_machine) |m| return if (m.canRequestStop()) objc.YES else objc.NO;
        return objc.NO;
    }
    if (a == @intFromPtr(objc.sel("vmForceStop:")) or a == @intFromPtr(objc.sel("vmRestart:"))) {
        if (global_machine) |m| return if (m.canStop()) objc.YES else objc.NO;
        return objc.NO;
    }
    return objc.YES;
}

// ── New Tab ─────────────────────────────────────────────────────────

fn newTabAction(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) void {
    const allocator = gpa.allocator();
    const machine = global_machine orelse return;
    if (global_font == null) return;

    // Find the window to attach the new tab to. Prefer the key window so
    // Cmd+T attaches to the active tab group; fall back to the first window
    // we created.
    const NSApp = objc.getClass("NSApplication") orelse return;
    const ns_app = objc.msgSend(objc.id, NSApp, objc.sel("sharedApplication"), .{});
    const key_win_opt = objc.msgSend(?objc.id, ns_app, objc.sel("keyWindow"), .{});
    const existing = key_win_opt orelse primary_window orelse return;

    // Size the new session's grid to match the existing window's content.
    const existing_session = session_mod.byWindow(existing);
    const cols: u16 = if (existing_session) |s| s.grid.cols else 80;
    const rows: u16 = if (existing_session) |s| s.grid.rows else 24;

    const session = session_mod.create(allocator, cols, rows, machine) catch return;
    applyScrollbackToSession(session, readAppearance(allocator));

    const view = terminal_view.createTerminalView(&session.grid, &global_font.?);
    session_mod.bindView(session, view) catch return;

    const new_win = tabs.newTab(existing, view, "LCL Terminal");
    session_mod.bindWindow(session, new_win) catch return;
    terminal_view.applyBackgroundToWindow(new_win);

    session_mod.beginConnect(session, 0);
}

// ── Title polling ───────────────────────────────────────────────────

const PollFn = fn (*anyopaque) callconv(.c) void;
const PollBlock = objc.Block(PollFn);
var poll_desc = objc.blockDescriptor(PollBlock);
var poll_block = PollBlock{ .invoke = &doPoll, .descriptor = &poll_desc };

fn schedulePoll() void {
    dispatch_after(dispatch_time(0, 1_000_000_000), mainQueue(), @ptrCast(&poll_block));
}

fn doPoll(_: *anyopaque) callconv(.c) void {
    updateTitle();
    schedulePoll();
}

fn updateTitle() void {
    const state: vz.VmState = if (global_machine) |m| m.state() else .stopped;
    const label = switch (state) {
        .stopped => "Stopped",
        .running => "Running",
        .paused => "Paused",
        .err => "Error",
        .starting => "Starting",
        .stopping => "Stopping",
        .saving => "Saving",
        .restoring => "Restoring",
    };
    var buf: [128]u8 = undefined;
    const title = std.fmt.bufPrintZ(&buf, "LCL Terminal — {s}", .{label}) catch return;
    const ns_str = objc.nsString(title.ptr);

    var it = session_mod.iterator() orelse return;
    while (it.next()) |s_ptr| {
        const s = s_ptr.*;
        if (s.window) |w| objc.msgSend(void, w, objc.sel("setTitle:"), .{ns_str});
    }
}

// ── Bridge / shell connection ───────────────────────────────────────

fn onBridge(conn: vz.VirtioSocketConnection) void {
    const fd = conn.readFd();
    _ = std.Thread.spawn(.{}, bridgeThread, .{fd}) catch {
        std.posix.close(fd);
    };
}

fn bridgeThread(fd: std.posix.fd_t) void {
    bridge_handler.handleConnection(fd, fd, .{});
    std.posix.close(fd);
}

fn onSshAgent(conn: vz.VirtioSocketConnection) void {
    ssh_agent.handleConnection(conn.readFd());
}

// ── Termination ─────────────────────────────────────────────────────

fn shouldTerminate(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) objc.BOOL {
    return objc.YES;
}

const NSTerminateCancel: objc.NSUInteger = 0;
const NSTerminateNow: objc.NSUInteger = 1;
const NSTerminateLater: objc.NSUInteger = 2;

fn shouldTerminateApp(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) objc.NSUInteger {
    const m = global_machine orelse return NSTerminateNow;
    if (!m.canStop()) return NSTerminateNow;
    m.stopWithCompletionHandler(@ptrCast(&quit_stop_block));
    return NSTerminateLater;
}

// ── Settings ────────────────────────────────────────────────────────

fn openSettingsAction(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) void {
    settings.show();
}

/// Read appearance from disk, returning defaults if anything goes wrong.
fn readAppearance(allocator: std.mem.Allocator) config.LclConfig.Appearance {
    const dir = config.configPath(allocator, "dev") catch return .{};
    defer allocator.free(dir);
    const path = std.fs.path.join(allocator, &.{ dir, "lcl.toml" }) catch return .{};
    defer allocator.free(path);
    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return .{};
    defer allocator.free(data);
    var parsed = toml.parse(allocator, data) catch return .{};
    defer parsed.deinit();
    // Duplicate the font + theme names so they survive parsed.deinit().
    const font_dup = allocator.dupe(u8, parsed.config.appearance.font) catch return .{};
    const theme_dup: ?[]const u8 = if (parsed.config.appearance.theme) |t|
        (allocator.dupe(u8, t) catch null)
    else
        null;
    return .{
        .font = font_dup,
        .font_size = parsed.config.appearance.font_size,
        .fg_r = parsed.config.appearance.fg_r,
        .fg_g = parsed.config.appearance.fg_g,
        .fg_b = parsed.config.appearance.fg_b,
        .bg_r = parsed.config.appearance.bg_r,
        .bg_g = parsed.config.appearance.bg_g,
        .bg_b = parsed.config.appearance.bg_b,
        .theme = theme_dup,
        .scrollback_lines = parsed.config.appearance.scrollback_lines,
        .scrollback_unlimited = parsed.config.appearance.scrollback_unlimited,
    };
}

fn applyAppearance(a: config.LclConfig.Appearance) void {
    // Rebuild font with new name + size; update cached pointer used by views.
    var name_buf: [256:0]u8 = undefined;
    const len = @min(a.font.len, name_buf.len);
    @memcpy(name_buf[0..len], a.font[0..len]);
    name_buf[len] = 0;

    global_font = coretext.createFont(@ptrCast(&name_buf), a.font_size);
    terminal_view.setFont(&global_font.?);
    applyColors(gpa.allocator(), a);
    applyScrollbackToAll(a);

    var it = session_mod.iterator() orelse return;
    while (it.next()) |s_ptr| {
        const s = s_ptr.*;
        if (s.window) |w| terminal_view.applyBackgroundToWindow(w);
        if (s.view) |v| terminal_view.setNeedsDisplay(v);
    }
}

fn applyScrollbackToSession(s: *session_mod.Session, a: config.LclConfig.Appearance) void {
    const target: u32 = if (a.scrollback_unlimited)
        config.scrollback_unlimited_cap
    else
        a.scrollback_lines;
    s.grid.setScrollbackCapacity(target) catch {};
}

fn applyScrollbackToAll(a: config.LclConfig.Appearance) void {
    var it = session_mod.iterator() orelse return;
    while (it.next()) |s_ptr| applyScrollbackToSession(s_ptr.*, a);
}

/// Apply colors + palette + cursor color from the given appearance.
/// If a theme is set, it overrides the explicit fg_*/bg_* fields.
fn applyColors(allocator: std.mem.Allocator, a: config.LclConfig.Appearance) void {
    coretext.resetPalette();

    var fg = coretext.Rgb{ .r = a.fg_r, .g = a.fg_g, .b = a.fg_b };
    var bg = coretext.Rgb{ .r = a.bg_r, .g = a.bg_g, .b = a.bg_b };
    var cursor = fg; // default cursor follows foreground when a theme is loaded

    var theme_loaded = false;
    if (a.theme) |name| if (name.len > 0) {
        if (theme_mod.loadByName(allocator, name)) |t| {
            theme_loaded = true;
            for (t.palette, 0..) |maybe_rgb, i| {
                if (maybe_rgb) |c| coretext.setPaletteEntry(@intCast(i), c.r, c.g, c.b);
            }
            if (t.foreground) |c| fg = rgb8ToFloat(c);
            if (t.background) |c| bg = rgb8ToFloat(c);
            if (t.cursor_color) |c| cursor = rgb8ToFloat(c);
        }
    };

    terminal_view.setDefaultColors(fg, bg);
    if (theme_loaded) {
        terminal_view.setCursorColor(cursor);
    } else {
        // Restore the original light-gray cursor when no theme is active.
        terminal_view.setCursorColor(.{ .r = 0.8, .g = 0.8, .b = 0.8 });
    }
}

fn rgb8ToFloat(c: theme_mod.Rgb) coretext.Rgb {
    return .{
        .r = @as(objc.CGFloat, @floatFromInt(c.r)) / 255.0,
        .g = @as(objc.CGFloat, @floatFromInt(c.g)) / 255.0,
        .b = @as(objc.CGFloat, @floatFromInt(c.b)) / 255.0,
    };
}

/// Convert a Zig slice to a null-terminated C string in a static buffer.
/// Caller must use the returned pointer immediately (next call clobbers).
var c_string_buf: [256:0]u8 = undefined;
fn toCString(s: []const u8) [*:0]const u8 {
    const len = @min(s.len, c_string_buf.len);
    @memcpy(c_string_buf[0..len], s[0..len]);
    c_string_buf[len] = 0;
    return @ptrCast(&c_string_buf);
}
