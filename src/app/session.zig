/// Terminal session — a single shell connection with its own grid, parser, and vsock fd.
/// Multiple sessions can exist simultaneously (one per split pane).

const std = @import("std");
const cell_mod = @import("cell");
const parser_mod = @import("parser");
const shell_protocol = @import("shell_protocol");
const vz = @import("vz");
const objc = @import("objc");

pub const max_sessions = 16;

pub const Session = struct {
    allocator: std.mem.Allocator,
    grid: cell_mod.CellGrid,
    parser: parser_mod.Parser,
    shell_fd: ?std.posix.fd_t = null,
    read_thread: ?std.Thread = null,
    view: ?objc.id = null,
    active: bool = false,
    index: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, idx: u8) !Session {
        var grid = try cell_mod.CellGrid.init(allocator, cols, rows);
        return .{
            .allocator = allocator,
            .grid = grid,
            .parser = .{ .grid = &grid },
            .index = idx,
            .active = true,
        };
    }

    pub fn deinit(self: *Session) void {
        self.active = false;
        if (self.shell_fd) |fd| std.posix.close(fd);
        self.grid.deinit();
    }

    /// Connect this session to the guest shell service via vsock.
    pub fn connectShell(self: *Session, machine: vz.VirtualMachine) void {
        const socket_device = vz.VirtioSocketDevice.fromVirtualMachine(machine) orelse return;

        // Use static blocks indexed by session
        const idx = self.index;
        session_connect_idx = idx;

        socket_device.connectToPort(shell_protocol.shell_port, @ptrCast(&session_connect_block));
    }

    pub fn sendInput(self: *Session, data: []const u8) void {
        if (self.shell_fd) |fd| {
            shell_protocol.writeData(fd, data) catch {};
        }
    }

    pub fn sendResize(self: *Session, cols: u16, rows: u16) void {
        if (self.shell_fd) |fd| {
            shell_protocol.writeResize(fd, cols, rows) catch {};
        }
    }
};

// ── Session registry ────────────────────────────────────────────────

var sessions: [max_sessions]?Session = [_]?Session{null} ** max_sessions;
var session_count: u8 = 0;

pub fn createSession(allocator: std.mem.Allocator, cols: u16, rows: u16) ?*Session {
    for (&sessions, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = Session.init(allocator, cols, rows, @intCast(i)) catch return null;
            // Fix parser grid pointer (points into the optional, need to point into the session)
            slot.*.?.parser.grid = &slot.*.?.grid;
            session_count += 1;
            return &slot.*.?;
        }
    }
    return null;
}

pub fn getSession(idx: u8) ?*Session {
    if (idx >= max_sessions) return null;
    if (sessions[idx]) |*s| {
        if (s.active) return s;
    }
    return null;
}

// ── Connection completion (shared across sessions) ──────────────────

var session_connect_idx: u8 = 0;

const ConnectCompletionFn = fn (*anyopaque, ?objc.id, ?objc.id) callconv(.c) void;
const ConnectCompletionBlock = objc.Block(ConnectCompletionFn);
var session_connect_desc = objc.blockDescriptor(ConnectCompletionBlock);
var session_connect_block = ConnectCompletionBlock{
    .invoke = &sessionConnectCompletion,
    .descriptor = &session_connect_desc,
};

fn sessionConnectCompletion(_: *anyopaque, connection: ?objc.id, err: ?objc.id) callconv(.c) void {
    if (err != null or connection == null) return;

    if (connection) |conn_obj| {
        _ = objc.retain(conn_obj);
        const conn = vz.VirtioSocketConnection{ .obj = conn_obj };
        const fd = conn.readFd();

        const idx = session_connect_idx;
        if (getSession(idx)) |s| {
            s.shell_fd = fd;
            shell_protocol.writeResize(fd, s.grid.cols, s.grid.rows) catch {};
            s.read_thread = std.Thread.spawn(.{}, sessionReadThread, .{idx}) catch null;
        }
    }
}

fn sessionReadThread(idx: u8) void {
    const s = getSession(idx) orelse return;
    const fd = s.shell_fd orelse return;
    var frame_buf: [shell_protocol.max_frame_size]u8 = undefined;

    while (s.active) {
        const frame = shell_protocol.readFrame(fd, &frame_buf) catch break;
        if (frame == null) break;

        if (frame.?.frame_type == .data) {
            s.parser.feed(frame.?.payload);
            // Trigger redraw of this session's view
            if (s.view) |view| {
                scheduleViewRedraw(view);
            }
        }
    }
}

// GCD for scheduling redraws
extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_async(queue: *anyopaque, block: *const anyopaque) void;

// We need a way to schedule redraws for specific views.
// Use a simple approach: set a global "needs redraw" view and dispatch.
var pending_redraw_view: ?objc.id = null;

const RedrawFn = fn (*anyopaque) callconv(.c) void;
const RedrawBlock = objc.Block(RedrawFn);
var redraw_desc = objc.blockDescriptor(RedrawBlock);
var redraw_blk = RedrawBlock{
    .invoke = &doViewRedraw,
    .descriptor = &redraw_desc,
};

fn scheduleViewRedraw(view: objc.id) void {
    pending_redraw_view = view;
    dispatch_async(&_dispatch_main_q, @ptrCast(&redraw_blk));
}

fn doViewRedraw(_: *anyopaque) callconv(.c) void {
    if (pending_redraw_view) |view| {
        objc.msgSend(void, view, objc.sel("setNeedsDisplay:"), .{objc.YES});
    }
}
