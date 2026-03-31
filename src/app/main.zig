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

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var global_grid: ?cell_mod.CellGrid = null;
var global_parser: ?parser_mod.Parser = null;
var global_font: ?coretext.FontInfo = null;
var global_view: ?objc.id = null;
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
    objc.registerClass(cls);
    return objc.getClass("LCLAppDelegate") orelse @panic("Not found");
}

fn appDidFinishLaunching(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) void {
    const allocator = gpa.allocator();

    global_font = coretext.createFont("Menlo", 14.0);
    global_grid = cell_mod.CellGrid.init(allocator, 80, 24) catch return;
    global_parser = .{ .grid = &global_grid.? };

    const font = &global_font.?;
    const grid = &global_grid.?;

    const msg = "Booting VM...\r\n";
    for (msg) |ch| grid.putChar(ch);

    const view = terminal_view.createTerminalView(grid, font, &onInput);
    global_view = view;

    const win = win_mod.createMainWindow(view, "LCL Terminal");
    objc.msgSend(void, win, objc.sel("center"), .{});
    objc.msgSend(void, win, objc.sel("orderFrontRegardless"), .{});
    objc.msgSend(void, win, objc.sel("makeKeyAndOrderFront:"), .{@as(?objc.id, null)});

    const NSApp = objc.getClass("NSApplication") orelse return;
    const ns_app = objc.msgSend(objc.id, NSApp, objc.sel("sharedApplication"), .{});
    objc.msgSend(void, ns_app, objc.sel("activateIgnoringOtherApps:"), .{objc.YES});

    bootVm(allocator);
}

fn onInput(data: []const u8) void {
    if (global_shell_fd) |fd| shell_protocol.writeData(fd, data) catch {};
}

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
        const listener = vz.createSocketListenerWithCallback(&onBridge);
        sd.setSocketListener(listener, 5000);
    }

    const CompFn = fn (*anyopaque, ?objc.id) callconv(.c) void;
    const CompBlock = objc.Block(CompFn);
    var desc = objc.blockDescriptor(CompBlock);
    var block = CompBlock{ .invoke = &vmStarted, .descriptor = &desc };
    machine.startWithCompletionHandler(@ptrCast(&block));
}

fn onBridge(conn: vz.VirtioSocketConnection) void { _ = conn; }

fn vmStarted(_: *anyopaque, err: ?objc.id) callconv(.c) void {
    if (err) |_| return;
    scheduleShellConnect(5);
}

// Shell connection
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
}

const RFn = fn (*anyopaque) callconv(.c) void;
const RB = objc.Block(RFn);
var rb_desc = objc.blockDescriptor(RB);
var rb_block = RB{ .invoke = &doRedraw, .descriptor = &rb_desc };

fn scheduleRedraw() void { dispatch_async(mainQueue(), @ptrCast(&rb_block)); }

fn doRedraw(_: *anyopaque) callconv(.c) void {
    if (global_view) |v| terminal_view.setNeedsDisplay(v);
}

fn shouldTerminate(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) objc.BOOL {
    return objc.YES;
}
