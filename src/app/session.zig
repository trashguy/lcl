/// Terminal session — one shell connection with its own grid, parser, view, and window.
/// Multiple sessions run concurrently against the same VM, one per tab.

const std = @import("std");
const objc = @import("objc");
const cell_mod = @import("cell");
const parser_mod = @import("parser");
const shell_protocol = @import("shell_protocol");
const vz = @import("vz");

extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_async(queue: *anyopaque, block: *const anyopaque) void;
extern "c" fn dispatch_after(when: u64, queue: *anyopaque, block: *const anyopaque) void;
extern "c" fn dispatch_time(base: u64, delta: i64) u64;

fn mainQueue() *anyopaque {
    return &_dispatch_main_q;
}

// ── Block ABI types ─────────────────────────────────────────────────

const ConnectFn = fn (*anyopaque, ?objc.id, ?objc.id) callconv(.c) void;
const ConnectBlock = objc.Block(ConnectFn);

const RetryFn = fn (*anyopaque) callconv(.c) void;
const RetryBlock = objc.Block(RetryFn);

const RedrawFn = fn (*anyopaque) callconv(.c) void;
const RedrawBlock = objc.Block(RedrawFn);

// ── Session ─────────────────────────────────────────────────────────

pub const Session = struct {
    allocator: std.mem.Allocator,
    grid: cell_mod.CellGrid,
    parser: parser_mod.Parser,
    view: ?objc.id = null,
    window: ?objc.id = null,
    machine: vz.VirtualMachine,
    shell_fd: ?std.posix.fd_t = null,
    read_thread: ?std.Thread = null,
    connect_attempts: u32 = 0,
    cancelled: std.atomic.Value(bool) = .init(false),

    // Blocks live inside the session so the invoke callbacks can recover
    // the *Session via @fieldParentPtr.
    connect_desc: objc.BlockDescriptor,
    connect_block: ConnectBlock,
    retry_desc: objc.BlockDescriptor,
    retry_block: RetryBlock,
    redraw_desc: objc.BlockDescriptor,
    redraw_block: RedrawBlock,
};

pub fn create(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    machine: vz.VirtualMachine,
) !*Session {
    const s = try allocator.create(Session);
    errdefer allocator.destroy(s);

    s.* = .{
        .allocator = allocator,
        .grid = try cell_mod.CellGrid.init(allocator, cols, rows),
        .parser = undefined,
        .machine = machine,
        .connect_desc = objc.blockDescriptor(ConnectBlock),
        .connect_block = undefined,
        .retry_desc = objc.blockDescriptor(RetryBlock),
        .retry_block = undefined,
        .redraw_desc = objc.blockDescriptor(RedrawBlock),
        .redraw_block = undefined,
    };
    s.parser = .{ .grid = &s.grid };
    s.connect_block = .{ .invoke = &onConnected, .descriptor = &s.connect_desc };
    s.retry_block = .{ .invoke = &onRetry, .descriptor = &s.retry_desc };
    s.redraw_block = .{ .invoke = &onRedraw, .descriptor = &s.redraw_desc };

    return s;
}

pub fn bindView(s: *Session, view: objc.id) !void {
    s.view = view;
    try by_view.put(@intFromPtr(view), s);
}

pub fn bindWindow(s: *Session, window: objc.id) !void {
    s.window = window;
    try by_window.put(@intFromPtr(window), s);
}

/// Tear down the session's runtime resources: close the shell socket
/// (which kills the guest shell via SIGHUP), wait for the read thread to
/// exit, free the grid, and remove the session from the lookup tables.
///
/// We deliberately do NOT free the Session struct itself — pending GCD
/// blocks (retry, redraw, connect-completion) may still reference it. The
/// struct is small (~250 B) so leaking one per closed tab is acceptable
/// and avoids a use-after-free if a delayed retry block fires post-close.
pub fn destroy(s: *Session) void {
    if (s.cancelled.swap(true, .seq_cst)) return; // already destroyed

    if (s.view) |v| _ = by_view.remove(@intFromPtr(v));
    if (s.window) |w| _ = by_window.remove(@intFromPtr(w));
    s.view = null;
    s.window = null;

    // Closing the fd interrupts any blocking read in the loop thread, so
    // the thread exits and we can safely free the grid below.
    if (s.shell_fd) |fd| {
        std.posix.close(fd);
        s.shell_fd = null;
    }
    if (s.read_thread) |t| {
        t.join();
        s.read_thread = null;
    }

    s.grid.deinit();
}

pub fn sendInput(s: *Session, data: []const u8) void {
    if (s.shell_fd) |fd| shell_protocol.writeData(fd, data) catch {};
}

pub fn sendResize(s: *Session, cols: u16, rows: u16) void {
    if (s.shell_fd) |fd| shell_protocol.writeResize(fd, cols, rows) catch {};
}

// ── Registry ────────────────────────────────────────────────────────
//
// Two maps: by view pointer (for ObjC view callbacks) and by window
// pointer (for window-delegate callbacks like windowDidResize).

var by_view: std.AutoHashMap(usize, *Session) = undefined;
var by_window: std.AutoHashMap(usize, *Session) = undefined;
var registry_initialized: bool = false;

pub fn initRegistry(allocator: std.mem.Allocator) void {
    if (registry_initialized) return;
    by_view = std.AutoHashMap(usize, *Session).init(allocator);
    by_window = std.AutoHashMap(usize, *Session).init(allocator);
    registry_initialized = true;
}

pub fn byView(view: objc.id) ?*Session {
    if (!registry_initialized) return null;
    return by_view.get(@intFromPtr(view));
}

pub fn byWindow(win: objc.id) ?*Session {
    if (!registry_initialized) return null;
    return by_window.get(@intFromPtr(win));
}

pub fn iterator() ?std.AutoHashMap(usize, *Session).ValueIterator {
    if (!registry_initialized) return null;
    return by_view.valueIterator();
}

// ── Shell connect / retry ───────────────────────────────────────────

/// Begin connecting this session to the guest shell service. Schedules
/// the first attempt after `initial_delay_secs` to give the VM time to
/// finish booting.
pub fn beginConnect(s: *Session, initial_delay_secs: u32) void {
    s.connect_attempts = 0;
    scheduleRetry(s, initial_delay_secs);
}

fn scheduleRetry(s: *Session, secs: u32) void {
    const ns: i64 = @as(i64, secs) * 1_000_000_000;
    dispatch_after(dispatch_time(0, ns), mainQueue(), @ptrCast(&s.retry_block));
}

fn onRetry(blk: *anyopaque) callconv(.c) void {
    const block: *RetryBlock = @ptrCast(@alignCast(blk));
    const s: *Session = @fieldParentPtr("retry_block", block);
    if (s.cancelled.load(.seq_cst)) return;

    s.connect_attempts += 1;
    const stderr = std.fs.File.stderr().deprecatedWriter();
    if (s.connect_attempts > 600) {
        stderr.writeAll("[lcl] giving up on shell connect after 600 attempts\n") catch {};
        return;
    }

    if (s.machine.state() != .running) {
        if (s.connect_attempts <= 3 or s.connect_attempts % 10 == 0) {
            stderr.print("[lcl] attempt {d}: VM not running yet (state={d})\n", .{ s.connect_attempts, @intFromEnum(s.machine.state()) }) catch {};
        }
        scheduleRetry(s, 2);
        return;
    }

    const sd = vz.VirtioSocketDevice.fromVirtualMachine(s.machine) orelse return;
    stderr.print("[lcl] attempt {d}: connecting to vsock port {d}\n", .{ s.connect_attempts, shell_protocol.shell_port }) catch {};
    sd.connectToPort(shell_protocol.shell_port, @ptrCast(&s.connect_block));
}

fn onConnected(blk: *anyopaque, conn: ?objc.id, err: ?objc.id) callconv(.c) void {
    const block: *ConnectBlock = @ptrCast(@alignCast(blk));
    const s: *Session = @fieldParentPtr("connect_block", block);
    if (s.cancelled.load(.seq_cst)) return;
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (err != null or conn == null) {
        if (err) |e| {
            const desc = objc.errorDescription(e);
            stderr.print("[lcl] connect failed: {s}\n", .{std.mem.span(desc)}) catch {};
        } else {
            stderr.writeAll("[lcl] connect: nil connection\n") catch {};
        }
        scheduleRetry(s, 2);
        return;
    }
    stderr.writeAll("[lcl] shell connected\n") catch {};

    if (conn) |c| {
        _ = objc.retain(c);
        s.shell_fd = (vz.VirtioSocketConnection{ .obj = c }).readFd();
        s.grid.reset();
        if (s.shell_fd) |fd| {
            shell_protocol.writeResize(fd, s.grid.cols, s.grid.rows) catch {};
        }
        scheduleRedraw(s);
        s.read_thread = std.Thread.spawn(.{}, readLoop, .{s}) catch null;
    }
}

fn readLoop(s: *Session) void {
    const fd = s.shell_fd orelse return;
    var buf: [shell_protocol.max_frame_size]u8 = undefined;
    while (!s.cancelled.load(.seq_cst)) {
        const frame = shell_protocol.readFrame(fd, &buf) catch break;
        if (frame == null) break;
        if (frame.?.frame_type == .data) {
            s.parser.feed(frame.?.payload);
            scheduleRedraw(s);
        }
    }
}

// ── Redraw scheduling ───────────────────────────────────────────────

pub fn scheduleRedraw(s: *Session) void {
    dispatch_async(mainQueue(), @ptrCast(&s.redraw_block));
}

fn onRedraw(blk: *anyopaque) callconv(.c) void {
    const block: *RedrawBlock = @ptrCast(@alignCast(blk));
    const s: *Session = @fieldParentPtr("redraw_block", block);
    if (s.cancelled.load(.seq_cst)) return;
    if (s.view) |v| objc.msgSend(void, v, objc.sel("setNeedsDisplay:"), .{objc.YES});
}
