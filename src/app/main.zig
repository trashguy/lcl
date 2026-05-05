/// LCL Terminal App — boots a VM and connects via vsock shell.

const std = @import("std");
const objc = @import("objc");
const app_ui = @import("app_mod");
const win_mod = @import("window");
const cell_mod = @import("cell");
const parser_mod = @import("parser");
const coretext = @import("coretext");
const terminal_view = @import("terminal_view");
const shell_protocol = @import("shell_protocol");
const vz = @import("vz");
const config = @import("config");
const toml = @import("toml");
const vm_config = @import("vm_config");
const bridge_handler = @import("bridge_handler");
const ssh_agent = @import("ssh_agent_host");
const settings = @import("settings");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var global_grid: ?cell_mod.CellGrid = null;
var global_parser: ?parser_mod.Parser = null;
var global_font: ?coretext.FontInfo = null;
var global_view: ?objc.id = null;
var global_window: ?objc.id = null;
var global_shell_fd: ?std.posix.fd_t = null;
var global_machine: ?vz.VirtualMachine = null;

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
    objc.registerClass(cls);
    return objc.getClass("LCLAppDelegate") orelse @panic("Not found");
}

fn appDidFinishLaunching(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) void {
    const allocator = gpa.allocator();

    settings.init(allocator, "dev");
    settings.on_appearance_changed = &applyAppearance;

    const initial_appearance = readAppearance(allocator);

    global_font = coretext.createFont(toCString(initial_appearance.font), initial_appearance.font_size);
    terminal_view.setDefaultColors(
        .{ .r = initial_appearance.fg_r, .g = initial_appearance.fg_g, .b = initial_appearance.fg_b },
        .{ .r = initial_appearance.bg_r, .g = initial_appearance.bg_g, .b = initial_appearance.bg_b },
    );

    global_grid = cell_mod.CellGrid.init(allocator, 80, 24) catch return;
    global_parser = .{ .grid = &global_grid.? };

    const font = &global_font.?;
    const grid = &global_grid.?;

    const msg = "Booting VM...\r\n";
    for (msg) |ch| grid.putChar(ch);

    const view = terminal_view.createTerminalView(grid, font, &onInput);
    global_view = view;

    const win = win_mod.createMainWindow(view, "LCL Terminal");
    global_window = win;
    objc.msgSend(void, win, objc.sel("center"), .{});
    objc.msgSend(void, win, objc.sel("orderFrontRegardless"), .{});
    objc.msgSend(void, win, objc.sel("makeKeyAndOrderFront:"), .{@as(?objc.id, null)});

    const NSApp = objc.getClass("NSApplication") orelse return;
    const ns_app = objc.msgSend(objc.id, NSApp, objc.sel("sharedApplication"), .{});
    objc.msgSend(void, ns_app, objc.sel("activateIgnoringOtherApps:"), .{objc.YES});

    bootVm(allocator);
    schedulePoll();
}

fn onInput(data: []const u8) void {
    if (global_shell_fd) |fd| shell_protocol.writeData(fd, data) catch {};
}

// ── VM lifecycle ────────────────────────────────────────────────────

fn bootVm(allocator: std.mem.Allocator) void {
    const config_dir = config.configPath(allocator, "dev") catch return;
    const toml_path = std.fs.path.join(allocator, &.{ config_dir, "lcl.toml" }) catch return;
    const toml_data = std.fs.cwd().readFileAlloc(allocator, toml_path, 1024 * 1024) catch return;
    var parsed = toml.parse(allocator, toml_data) catch return;
    defer parsed.deinit();

    const vz_cfg = vm_config.buildVmConfig(parsed.config, config_dir, allocator) catch return;
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

fn vmStarted(_: *anyopaque, err: ?objc.id) callconv(.c) void {
    if (err) |_| return;
    connect_attempts = 0;
    scheduleShellConnect(5);
}

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
    const win = global_window orelse return;
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
    objc.msgSend(void, win, objc.sel("setTitle:"), .{ns_str});
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

var connect_attempts: u32 = 0;
const CBFn = fn (*anyopaque) callconv(.c) void;
const CB = objc.Block(CBFn);
var cb_desc = objc.blockDescriptor(CB);
var cb_block = CB{ .invoke = &tryConnect, .descriptor = &cb_desc };

const SCFn = fn (*anyopaque, ?objc.id, ?objc.id) callconv(.c) void;
const SC = objc.Block(SCFn);
var sc_desc = objc.blockDescriptor(SC);
var sc_block = SC{ .invoke = &shellConnected, .descriptor = &sc_desc };

fn scheduleShellConnect(secs: u32) void {
    dispatch_after(dispatch_time(0, @as(i64, secs) * 1_000_000_000), mainQueue(), @ptrCast(&cb_block));
}

fn tryConnect(_: *anyopaque) callconv(.c) void {
    connect_attempts += 1;
    if (connect_attempts > 30) return;
    const m = global_machine orelse return;
    if (m.state() != .running) {
        scheduleShellConnect(2);
        return;
    }
    const sd = vz.VirtioSocketDevice.fromVirtualMachine(m) orelse return;
    sd.connectToPort(shell_protocol.shell_port, @ptrCast(&sc_block));
}

fn shellConnected(_: *anyopaque, conn: ?objc.id, err: ?objc.id) callconv(.c) void {
    if (err != null or conn == null) { scheduleShellConnect(2); return; }
    if (conn) |c| {
        _ = objc.retain(c);
        global_shell_fd = (vz.VirtioSocketConnection{ .obj = c }).readFd();
        if (global_grid) |*g| g.reset();
        shell_protocol.writeResize(global_shell_fd.?, 80, 24) catch {};
        scheduleRedraw();
        _ = std.Thread.spawn(.{}, readShell, .{}) catch {};
    }
}

fn readShell() void {
    const fd = global_shell_fd orelse return;
    var buf: [shell_protocol.max_frame_size]u8 = undefined;
    while (true) {
        const frame = shell_protocol.readFrame(fd, &buf) catch break;
        if (frame == null) break;
        if (frame.?.frame_type == .data) {
            if (global_parser) |*p| p.feed(frame.?.payload);
            scheduleRedraw();
        }
    }
    global_shell_fd = null;
}

const RFn = fn (*anyopaque) callconv(.c) void;
const RB = objc.Block(RFn);
var rb_desc = objc.blockDescriptor(RB);
var rb_block = RB{ .invoke = &doRedraw, .descriptor = &rb_desc };

fn scheduleRedraw() void { dispatch_async(mainQueue(), @ptrCast(&rb_block)); }

fn doRedraw(_: *anyopaque) callconv(.c) void {
    if (global_view) |v| terminal_view.setNeedsDisplay(v);
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
    // Duplicate the font name so it survives parsed.deinit().
    const font_dup = allocator.dupe(u8, parsed.config.appearance.font) catch return .{};
    return .{
        .font = font_dup,
        .font_size = parsed.config.appearance.font_size,
        .fg_r = parsed.config.appearance.fg_r,
        .fg_g = parsed.config.appearance.fg_g,
        .fg_b = parsed.config.appearance.fg_b,
        .bg_r = parsed.config.appearance.bg_r,
        .bg_g = parsed.config.appearance.bg_g,
        .bg_b = parsed.config.appearance.bg_b,
    };
}

fn applyAppearance(a: config.LclConfig.Appearance) void {
    // Rebuild font with new name + size; update cached pointer used by the view.
    var name_buf: [256:0]u8 = undefined;
    const len = @min(a.font.len, name_buf.len);
    @memcpy(name_buf[0..len], a.font[0..len]);
    name_buf[len] = 0;

    global_font = coretext.createFont(@ptrCast(&name_buf), a.font_size);
    terminal_view.setFont(&global_font.?);
    terminal_view.setDefaultColors(
        .{ .r = a.fg_r, .g = a.fg_g, .b = a.fg_b },
        .{ .r = a.bg_r, .g = a.bg_g, .b = a.bg_b },
    );
    if (global_view) |v| terminal_view.setNeedsDisplay(v);
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
