/// Host-side SSH agent forwarder.
///
/// Each connection from the guest on vsock port 5002 is paired with
/// a unix socket connection to $SSH_AUTH_SOCK on the macOS host. We
/// then byte-relay between the two until either side closes — same
/// idea as `ssh -A`, but routing the guest's agent traffic to the
/// host's user agent (Keychain-backed launchd ssh-agent).

const std = @import("std");

pub const ssh_agent_port: u32 = 5002;

/// Spawn relay threads for a freshly accepted vsock connection.
/// On error, closes the vsock fd. Caller must have set vsock fd to
/// non-blocking off / blocking I/O — VZ gives us blocking fds.
pub fn handleConnection(vsock_fd: std.posix.fd_t) void {
    const auth_sock = std.posix.getenv("SSH_AUTH_SOCK") orelse {
        logErr("SSH_AUTH_SOCK not set — cannot forward agent");
        std.posix.close(vsock_fd);
        return;
    };

    const unix_fd = connectUnix(auth_sock) catch {
        logErr("failed to connect to SSH_AUTH_SOCK");
        std.posix.close(vsock_fd);
        return;
    };

    // Two threads: one each direction. When either copy ends, both
    // sides are torn down via shutdown() so the partner thread
    // unblocks and exits.
    const ctx = Context{ .vsock_fd = vsock_fd, .unix_fd = unix_fd };
    const ctx_ptr = global_alloc.create(Context) catch {
        std.posix.close(vsock_fd);
        std.posix.close(unix_fd);
        return;
    };
    ctx_ptr.* = ctx;

    _ = std.Thread.spawn(.{}, relayVsockToUnix, .{ctx_ptr}) catch {
        std.posix.close(vsock_fd);
        std.posix.close(unix_fd);
        global_alloc.destroy(ctx_ptr);
        return;
    };
    _ = std.Thread.spawn(.{}, relayUnixToVsock, .{ctx_ptr}) catch {
        // First thread will eventually close fds when its copy ends.
        return;
    };
}

const Context = struct {
    vsock_fd: std.posix.fd_t,
    unix_fd: std.posix.fd_t,
    refs: std.atomic.Value(u8) = .init(2),
};

fn release(ctx: *Context) void {
    if (ctx.refs.fetchSub(1, .acq_rel) == 1) {
        std.posix.close(ctx.vsock_fd);
        std.posix.close(ctx.unix_fd);
        global_alloc.destroy(ctx);
    }
}

fn relayVsockToUnix(ctx: *Context) void {
    defer release(ctx);
    copyLoop(ctx.vsock_fd, ctx.unix_fd);
    std.posix.shutdown(ctx.unix_fd, .send) catch {};
    std.posix.shutdown(ctx.vsock_fd, .recv) catch {};
}

fn relayUnixToVsock(ctx: *Context) void {
    defer release(ctx);
    copyLoop(ctx.unix_fd, ctx.vsock_fd);
    std.posix.shutdown(ctx.vsock_fd, .send) catch {};
    std.posix.shutdown(ctx.unix_fd, .recv) catch {};
}

fn copyLoop(src: std.posix.fd_t, dst: std.posix.fd_t) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.posix.read(src, &buf) catch return;
        if (n == 0) return;
        var written: usize = 0;
        while (written < n) {
            const w = std.posix.write(dst, buf[written..n]) catch return;
            if (w == 0) return;
            written += w;
        }
    }
}

fn connectUnix(path: []const u8) !std.posix.fd_t {
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    errdefer std.posix.close(fd);

    var addr = std.posix.sockaddr.un{
        .family = std.posix.AF.UNIX,
        .path = undefined,
    };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);

    try std.posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    return fd;
}

// Internal allocator for tiny per-connection state. Using
// page_allocator is fine — we allocate a Context struct only.
const global_alloc = std.heap.page_allocator;

fn logErr(msg: []const u8) void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll("lcl ssh-agent: ") catch {};
    stderr.writeAll(msg) catch {};
    stderr.writeAll("\n") catch {};
}
