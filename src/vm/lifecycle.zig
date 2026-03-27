/// VM lifecycle — start, stop, status via Virtualization.framework.

const std = @import("std");
const objc = @import("objc");
const vz = @import("vz");
const config_types = @import("config");
const bridge_handler = @import("bridge_handler");
const shell_protocol = @import("shell_protocol");

pub const BridgeConfig = bridge_handler.BridgeConfig;

// ── CoreFoundation externs ───────────────────────────────────────────

extern "c" fn CFRunLoopRun() void;
extern "c" fn CFRunLoopStop(rl: *anyopaque) void;
extern "c" fn CFRunLoopGetCurrent() *anyopaque;

// ── Global state for signal handler ──────────────────────────────────

var global_run_loop: ?*anyopaque = null;
var global_vm_started: bool = false;
var global_machine: ?vz.VirtualMachine = null;
var shell_thread: ?std.Thread = null;
var global_original_termios: ?std.posix.termios = null;

/// Bridge port for vsock communication.
pub const bridge_port: u32 = 5000;

// ── Start VM ─────────────────────────────────────────────────────────

pub const StartError = error{
    StartFailed,
};

/// Start a VM and block until it exits (via signal or guest shutdown).
/// The serial console is attached to stdin/stdout.
/// If bridge_config is provided, sets up the vsock bridge listener.
pub fn startVm(
    allocator: std.mem.Allocator,
    vm_config: vz.VirtualMachineConfiguration,
    config_name: []const u8,
    bridge_config: ?bridge_handler.BridgeConfig,
) !void {
    const machine = vz.VirtualMachine.initWithConfiguration(vm_config);
    global_machine = machine;

    // Set up bridge listener on vsock if configured
    if (bridge_config) |bc| {
        setupBridgeListener(machine, bc);
    }

    // Write PID file
    try writePidFile(allocator, config_name);
    defer removePidFile(allocator, config_name) catch {};

    // Install signal handlers before starting
    installSignalHandlers();

    // Capture the run loop reference for the signal handler
    global_run_loop = CFRunLoopGetCurrent();

    // Set terminal to raw mode so keystrokes pass through to guest
    if (setRawMode()) |orig| {
        global_original_termios = orig;
    }
    defer {
        if (global_original_termios) |orig| {
            restoreTerminal(orig);
            global_original_termios = null;
        }
    }

    // Build completion handler block
    const CompletionFn = fn (*anyopaque, ?objc.id) callconv(.c) void;
    const CompletionBlock = objc.Block(CompletionFn);

    var desc = objc.blockDescriptor(CompletionBlock);
    var block = CompletionBlock{
        .invoke = &startCompletion,
        .descriptor = &desc,
    };

    // Start the VM
    machine.startWithCompletionHandler(@ptrCast(&block));

    global_vm_started = true;

    // Run the main event loop — blocks until CFRunLoopStop is called
    CFRunLoopRun();

    global_vm_started = false;
    global_run_loop = null;
}

// ── Bridge vsock listener ───────────────────────────────────────────

/// Global bridge config, set before CFRunLoopRun so the connection
/// callback can access it.
var global_bridge_config: bridge_handler.BridgeConfig = .{};

fn setupBridgeListener(machine: vz.VirtualMachine, config: bridge_handler.BridgeConfig) void {
    global_bridge_config = config;

    const socket_device = vz.VirtioSocketDevice.fromVirtualMachine(machine) orelse {
        logErr("no vsock device found — bridge disabled");
        return;
    };

    const listener = vz.createSocketListenerWithCallback(&onBridgeConnection);
    socket_device.setSocketListener(listener, bridge_port);
}

fn onBridgeConnection(conn: vz.VirtioSocketConnection) void {
    const read_fd = conn.readFd();
    const write_fd = conn.writeFd();

    // Handle the connection synchronously on the main thread.
    // Bridge requests are fast (keychain lookup, clipboard read) so
    // blocking is acceptable. The guest CLI tools make one request
    // per invocation and exit.
    bridge_handler.handleConnection(read_fd, write_fd, global_bridge_config);

    conn.close();
}

// ── Start completion handler ────────────────────────────────────────

fn startCompletion(_: *anyopaque, err: ?objc.id) callconv(.c) void {
    if (err) |e| {
        const desc = objc.errorDescription(e);
        const stderr_file = std.fs.File.stderr();
        stderr_file.writeAll("VM start failed: ") catch {};
        stderr_file.writeAll(std.mem.span(desc)) catch {};
        stderr_file.writeAll("\n") catch {};
        if (global_run_loop) |rl| {
            CFRunLoopStop(rl);
        }
        return;
    }

    // VM started successfully — schedule shell connection from the main thread.
    // Use dispatch_after to delay, giving the guest time to boot.
    scheduleShellConnect(5); // try after 5 seconds
}

// ── Shell connection over vsock ──────────────────────────────────────

// GCD externs for dispatching to the main queue
// mainQueue() is a macro; the actual symbol is _dispatch_main_q
extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_after(when: u64, queue: *anyopaque, block: *const anyopaque) void;
extern "c" fn dispatch_time(base: u64, delta: i64) u64;
const DISPATCH_TIME_NOW: u64 = 0;

fn mainQueue() *anyopaque {
    return &_dispatch_main_q;
}

var global_shell_read_fd: ?std.posix.fd_t = null;
var global_shell_write_fd: ?std.posix.fd_t = null;
var shell_connect_attempts: u32 = 0;

// Static block for dispatch_after (must be persistent, not stack-allocated)
const ConnectBlockFn = fn (*anyopaque) callconv(.c) void;
const ConnectBlock = objc.Block(ConnectBlockFn);
var connect_block_desc = objc.blockDescriptor(ConnectBlock);
var connect_block = ConnectBlock{
    .invoke = &tryShellConnect,
    .descriptor = &connect_block_desc,
};

// Static block for connectToPort completion
const ShellCompletionFn = fn (*anyopaque, ?objc.id, ?objc.id) callconv(.c) void;
const ShellCompletionBlock = objc.Block(ShellCompletionFn);
var shell_completion_desc = objc.blockDescriptor(ShellCompletionBlock);
var shell_completion_block = ShellCompletionBlock{
    .invoke = &shellConnectCompletion,
    .descriptor = &shell_completion_desc,
};

fn scheduleShellConnect(delay_seconds: u32) void {
    shell_connect_attempts = 0;
    const delay_ns = @as(i64, delay_seconds) * 1_000_000_000;
    const when = dispatch_time(DISPATCH_TIME_NOW, delay_ns);
    dispatch_after(when, mainQueue(), @ptrCast(&connect_block));
}

fn tryShellConnect(_: *anyopaque) callconv(.c) void {
    shell_connect_attempts += 1;

    if (shell_connect_attempts > 30) {
        const stderr_file = std.fs.File.stderr();
        stderr_file.writeAll("\r\nShell service not available (serial console active)\r\n") catch {};
        return;
    }

    const machine = global_machine orelse return;
    const socket_device = vz.VirtioSocketDevice.fromVirtualMachine(machine) orelse return;

    // connectToPort runs on the main thread — safe for Virtualization.framework
    socket_device.connectToPort(shell_protocol.shell_port, @ptrCast(&shell_completion_block));
}

fn shellConnectCompletion(_: *anyopaque, connection: ?objc.id, err: ?objc.id) callconv(.c) void {
    if (err != null or connection == null) {
        // Retry after 2 seconds
        const when = dispatch_time(DISPATCH_TIME_NOW, 2 * 1_000_000_000);
        dispatch_after(when, mainQueue(), @ptrCast(&connect_block));
        return;
    }

    if (connection) |conn_obj| {
        _ = objc.retain(conn_obj);
        const conn = vz.VirtioSocketConnection{ .obj = conn_obj };
        global_shell_read_fd = conn.readFd();
        global_shell_write_fd = conn.writeFd();

        const stderr_file = std.fs.File.stderr();
        stderr_file.writeAll("\r\nShell connected!\r\n") catch {};

        // Start proxy on a background thread (reads stdin, can't block main thread)
        shell_thread = std.Thread.spawn(.{}, shellProxyLoop, .{}) catch null;
    }
}

fn shellProxyLoop() void {
    const read_fd = global_shell_read_fd orelse return;
    const write_fd = global_shell_write_fd orelse return;

    // Send initial resize based on current terminal size
    var ws: std.posix.winsize = undefined;
    if (std.posix.system.ioctl(std.posix.STDIN_FILENO, 0x40087468, @intFromPtr(&ws)) == 0) {
        shell_protocol.writeResize(write_fd, ws.col, ws.row) catch {};
    }

    // Proxy loop: stdin → vsock, vsock → stdout
    var buf: [4096]u8 = undefined;
    var frame_buf: [shell_protocol.max_frame_size]u8 = undefined;

    // Use poll to multiplex stdin and vsock
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = read_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (global_vm_started) {
        _ = std.posix.poll(&poll_fds, 100) catch continue;

        // stdin → vsock (as data frames)
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch break;
            if (n == 0) break;
            shell_protocol.writeData(write_fd, buf[0..n]) catch break;
        }

        // vsock → stdout (extract data from frames)
        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            const frame = shell_protocol.readFrame(read_fd, &frame_buf) catch break;
            if (frame == null) break;
            if (frame.?.frame_type == .data) {
                _ = std.posix.write(std.posix.STDOUT_FILENO, frame.?.payload) catch break;
            }
        }

        const hup = std.posix.POLL.HUP | std.posix.POLL.ERR;
        if (poll_fds[1].revents & hup != 0) break;
    }

    // Shell disconnected — stop the VM
    if (global_run_loop) |rl| {
        CFRunLoopStop(rl);
    }
}

// ── Signal handling ──────────────────────────────────────────────────

fn installSignalHandlers() void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.TRAP, &action, null);
}

fn signalHandler(_: c_int) callconv(.c) void {
    // Restore terminal FIRST so it's not stuck in raw mode if we crash
    if (global_original_termios) |orig| {
        restoreTerminal(orig);
    }
    // Stop the run loop — actual VM cleanup happens on main thread
    if (global_run_loop) |rl| {
        CFRunLoopStop(rl);
    }
}

// ── Terminal raw mode ────────────────────────────────────────────────

fn setRawMode() ?std.posix.termios {
    var termios = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch {
        return null;
    };
    const original = termios;

    // Disable canonical mode, echo, and signal chars
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;
    termios.lflag.ISIG = false;

    // Disable input processing
    termios.iflag.ICRNL = false;
    termios.iflag.IXON = false;

    // Read returns immediately with available bytes
    termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;

    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, termios) catch return null;
    return original;
}

fn restoreTerminal(original: std.posix.termios) void {
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original) catch {};
}

// ── PID file management ──────────────────────────────────────────────

pub fn writePidFile(allocator: std.mem.Allocator, config_name: []const u8) !void {
    const pid_path = try pidFilePath(allocator, config_name);
    defer allocator.free(pid_path);

    const file = try std.fs.createFileAbsolute(pid_path, .{});
    defer file.close();
    try file.deprecatedWriter().print("{d}", .{std.posix.system.getpid()});
}

pub fn readPidFile(allocator: std.mem.Allocator, config_name: []const u8) !?std.posix.pid_t {
    const pid_path = try pidFilePath(allocator, config_name);
    defer allocator.free(pid_path);

    const file = std.fs.openFileAbsolute(pid_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    var buf: [32]u8 = undefined;
    const len = file.readAll(&buf) catch return null;
    if (len == 0) return null;

    const pid_str = std.mem.trim(u8, buf[0..len], " \n\r\t");
    const pid = std.fmt.parseInt(i32, pid_str, 10) catch return null;
    return @intCast(pid);
}

pub fn removePidFile(allocator: std.mem.Allocator, config_name: []const u8) !void {
    const pid_path = try pidFilePath(allocator, config_name);
    defer allocator.free(pid_path);
    std.fs.deleteFileAbsolute(pid_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn isProcessAlive(pid: std.posix.pid_t) bool {
    const result = std.posix.kill(pid, 0);
    if (result) |_| return true else |_| return false;
}

fn pidFilePath(allocator: std.mem.Allocator, config_name: []const u8) ![]const u8 {
    const config_dir = try config_types.configPath(allocator, config_name);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, "vm.pid" });
}

// ── Logging ─────────────────────────────────────────────────────────

fn logErr(msg: []const u8) void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll("lcl: ") catch {};
    stderr.writeAll(msg) catch {};
    stderr.writeAll("\n") catch {};
}
