/// LCL Terminal App — entry point.
/// Boots a VM and connects a terminal via vsock shell protocol.

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
const devices = @import("devices");

// ── Global state ────────────────────────────────────────────────────

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var global_grid: ?cell_mod.CellGrid = null;
var global_parser: ?parser_mod.Parser = null;
var global_font: ?coretext.FontInfo = null;
var global_view: ?objc.id = null;
var global_shell_fd: ?std.posix.fd_t = null;
var global_machine: ?vz.VirtualMachine = null;
var read_thread: ?std.Thread = null;

var app_delegate_registered: bool = false;

// GCD externs
extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_async(queue: *anyopaque, block: *const anyopaque) void;
extern "c" fn dispatch_after(when: u64, queue: *anyopaque, block: *const anyopaque) void;
extern "c" fn dispatch_time(base: u64, delta: i64) u64;

fn mainQueue() *anyopaque {
    return &_dispatch_main_q;
}

pub fn main() void {
    const cls = registerAppDelegate();
    app_ui.runApp(cls);
}

fn registerAppDelegate() objc.Class {
    if (!app_delegate_registered) {
        const cls = objc.createClass("LCLAppDelegate") orelse
            @panic("Failed to create LCLAppDelegate class");
        _ = objc.addMethod(cls, objc.sel("applicationDidFinishLaunching:"), @ptrCast(&appDidFinishLaunching), "v@:@");
        _ = objc.addMethod(cls, objc.sel("applicationShouldTerminateAfterLastWindowClosed:"), @ptrCast(&shouldTerminateAfterLastWindowClosed), "c@:@");
        objc.registerClass(cls);
        app_delegate_registered = true;
    }
    return objc.getClass("LCLAppDelegate") orelse @panic("LCLAppDelegate not found");
}

fn appDidFinishLaunching(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) void {
    const allocator = gpa.allocator();

    // Create font and grid
    global_font = coretext.createFont("Menlo", 14.0);
    const font = &global_font.?;

    global_grid = cell_mod.CellGrid.init(allocator, 80, 24) catch return;
    const grid = &global_grid.?;

    global_parser = .{ .grid = grid };

    // Show "Booting..." in the grid
    const msg = "Booting VM...";
    for (msg) |ch| grid.putChar(ch);

    // Create terminal view and window
    const view = terminal_view.createTerminalView(grid, font, &onInput);
    global_view = view;

    const win = win_mod.createMainWindow(view, "LCL Terminal");
    objc.msgSend(void, win, objc.sel("makeKeyAndOrderFront:"), .{@as(?objc.id, null)});
    const NSApp = objc.getClass("NSApplication") orelse return;
    const ns_app = objc.msgSend(objc.id, NSApp, objc.sel("sharedApplication"), .{});
    objc.msgSend(void, ns_app, objc.sel("activateIgnoringOtherApps:"), .{objc.YES});

    // Boot the VM (non-blocking — uses NSApplication's run loop)
    bootVm(allocator);
}

// ── VM boot (runs on the main thread, non-blocking) ─────────────────

fn bootVm(allocator: std.mem.Allocator) void {
    const env_name = "dev";

    const config_dir = config.configPath(allocator, env_name) catch return;
    const toml_path = std.fs.path.join(allocator, &.{ config_dir, "lcl.toml" }) catch return;
    const toml_data = std.fs.cwd().readFileAlloc(allocator, toml_path, 1024 * 1024) catch return;

    var parsed = toml.parse(allocator, toml_data) catch return;
    defer parsed.deinit();

    const vz_cfg = vm_config.buildVmConfig(parsed.config, config_dir, allocator) catch return;

    // Create the VM
    const machine = vz.VirtualMachine.initWithConfiguration(vz_cfg);
    global_machine = machine;

    // Set up bridge listener (port 5000)
    if (vz.VirtioSocketDevice.fromVirtualMachine(machine)) |socket_device| {
        const listener = vz.createSocketListenerWithCallback(&onBridgeConnection);
        socket_device.setSocketListener(listener, 5000);
    }

    // Start the VM with a completion handler
    const CompletionFn = fn (*anyopaque, ?objc.id) callconv(.c) void;
    const CompletionBlock = objc.Block(CompletionFn);
    var desc = objc.blockDescriptor(CompletionBlock);
    var block = CompletionBlock{
        .invoke = &vmStartCompletion,
        .descriptor = &desc,
    };
    machine.startWithCompletionHandler(@ptrCast(&block));
}

fn onBridgeConnection(conn: vz.VirtioSocketConnection) void {
    // TODO: Handle bridge RPC (clipboard, keychain, etc.)
    _ = conn;
}

fn vmStartCompletion(_: *anyopaque, err: ?objc.id) callconv(.c) void {
    if (err) |e| {
        const desc = objc.errorDescription(e);
        // Show error in the grid
        if (global_parser) |*p| {
            p.feed("\r\nVM start failed: ");
            p.feed(std.mem.span(desc));
        }
        scheduleRedraw();
        return;
    }

    // VM started — show message and schedule shell connection
    if (global_parser) |*p| {
        p.feed("\r\nVM started. Connecting shell...\r\n");
    }
    scheduleRedraw();

    // Try connecting to shell service after 5 seconds
    scheduleShellConnect(5);
}

// ── Shell connection ────────────────────────────────────────────────

var shell_connect_attempts: u32 = 0;

const ConnectBlockFn = fn (*anyopaque) callconv(.c) void;
const ConnectBlock = objc.Block(ConnectBlockFn);
var connect_block_desc = objc.blockDescriptor(ConnectBlock);
var connect_block = ConnectBlock{
    .invoke = &tryShellConnect,
    .descriptor = &connect_block_desc,
};

const ShellCompletionFn = fn (*anyopaque, ?objc.id, ?objc.id) callconv(.c) void;
const ShellCompletionBlock = objc.Block(ShellCompletionFn);
var shell_completion_desc = objc.blockDescriptor(ShellCompletionBlock);
var shell_completion_block = ShellCompletionBlock{
    .invoke = &shellConnectCompletion,
    .descriptor = &shell_completion_desc,
};

fn scheduleShellConnect(delay_seconds: u32) void {
    const delay_ns = @as(i64, delay_seconds) * 1_000_000_000;
    const when = dispatch_time(0, delay_ns);
    dispatch_after(when, mainQueue(), @ptrCast(&connect_block));
}

fn tryShellConnect(_: *anyopaque) callconv(.c) void {
    shell_connect_attempts += 1;
    if (shell_connect_attempts > 30) {
        if (global_parser) |*p| p.feed("\r\nShell service not available.\r\n");
        scheduleRedraw();
        return;
    }

    const machine = global_machine orelse return;
    const socket_device = vz.VirtioSocketDevice.fromVirtualMachine(machine) orelse return;
    socket_device.connectToPort(shell_protocol.shell_port, @ptrCast(&shell_completion_block));
}

fn shellConnectCompletion(_: *anyopaque, connection: ?objc.id, err: ?objc.id) callconv(.c) void {
    if (err != null or connection == null) {
        // Retry after 2 seconds
        scheduleShellConnect(2);
        return;
    }

    if (connection) |conn_obj| {
        _ = objc.retain(conn_obj);
        const conn = vz.VirtioSocketConnection{ .obj = conn_obj };
        global_shell_fd = conn.readFd();

        // Clear the grid and start fresh
        if (global_grid) |*grid| {
            grid.reset();
        }
        scheduleRedraw();

        // Send initial resize
        shell_protocol.writeResize(global_shell_fd.?, 80, 24) catch {};

        // Start reading shell output on a background thread
        read_thread = std.Thread.spawn(.{}, shellReadThread, .{}) catch null;
    }
}

// ── Input handler (keyboard → vsock) ────────────────────────────────

fn onInput(data: []const u8) void {
    const fd = global_shell_fd orelse return;
    shell_protocol.writeData(fd, data) catch {};
}

// ── Shell output reader (background thread → VT parser → redraw) ────

fn shellReadThread() void {
    const fd = global_shell_fd orelse return;
    var frame_buf: [shell_protocol.max_frame_size]u8 = undefined;

    while (true) {
        const frame = shell_protocol.readFrame(fd, &frame_buf) catch break;
        if (frame == null) break;

        if (frame.?.frame_type == .data) {
            if (global_parser) |*p| {
                p.feed(frame.?.payload);
            }
            scheduleRedraw();
        }
    }
}

// ── Redraw scheduling ───────────────────────────────────────────────

const RedrawBlockFn = fn (*anyopaque) callconv(.c) void;
const RedrawBlock = objc.Block(RedrawBlockFn);
var redraw_block_desc = objc.blockDescriptor(RedrawBlock);
var redraw_block = RedrawBlock{
    .invoke = &doRedraw,
    .descriptor = &redraw_block_desc,
};

fn scheduleRedraw() void {
    dispatch_async(mainQueue(), @ptrCast(&redraw_block));
}

fn doRedraw(_: *anyopaque) callconv(.c) void {
    if (global_view) |view| {
        terminal_view.setNeedsDisplay(view);
    }
}

fn shouldTerminateAfterLastWindowClosed(_: *const anyopaque, _: objc.SEL, _: objc.id) callconv(.c) objc.BOOL {
    return objc.YES;
}
