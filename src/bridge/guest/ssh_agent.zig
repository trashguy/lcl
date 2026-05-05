/// Guest-side SSH agent forwarder.
///
/// Binds a unix domain socket at /run/lcl/ssh-agent.sock. For each
/// accepted connection, opens a vsock link to host:5002 and byte-relays
/// in both directions. Combined with `SSH_AUTH_SOCK=/run/lcl/ssh-agent.sock`
/// in the user's shell environment, this lets guest ssh clients use
/// the macOS host's ssh-agent (Keychain-backed) to authenticate.

const std = @import("std");

const AF_VSOCK = 40;
const VMADDR_CID_HOST: u32 = 2;
const ssh_agent_port: u32 = 5002;

const sockaddr_vm = extern struct {
    svm_family: u16 = AF_VSOCK,
    svm_reserved1: u16 = 0,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [4]u8 = .{ 0, 0, 0, 0 },
};

pub const socket_dir = "/run/lcl";
pub const socket_path = "/run/lcl/ssh-agent.sock";

pub fn run() !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.writeAll("lcl-ssh-agent: starting\n") catch {};

    // Make sure /run/lcl exists. mkdir is idempotent here via try-or-EEXIST.
    std.fs.cwd().makePath(socket_dir) catch {};

    // Remove stale socket file from a previous run.
    std.posix.unlink(socket_path) catch {};

    const listen_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(listen_fd);

    var addr = std.posix.sockaddr.un{
        .family = std.posix.AF.UNIX,
        .path = undefined,
    };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try std.posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    // Allow non-root users to use the agent (the user's shell is /root by default
    // today, but make the socket world-RW so that doesn't matter for future setups).
    std.posix.fchmodat(std.posix.AT.FDCWD, socket_path, 0o666, 0) catch {};
    try std.posix.listen(listen_fd, 8);

    stderr.writeAll("lcl-ssh-agent: listening on " ++ socket_path ++ "\n") catch {};

    while (true) {
        const conn_fd = std.posix.accept(listen_fd, null, null, 0) catch |err| {
            stderr.print("accept error: {s}\n", .{@errorName(err)}) catch {};
            continue;
        };

        const pid = std.posix.fork() catch {
            std.posix.close(conn_fd);
            continue;
        };

        if (pid == 0) {
            std.posix.close(listen_fd);
            handleConnection(conn_fd) catch {};
            std.process.exit(0);
        } else {
            std.posix.close(conn_fd);
            _ = std.posix.waitpid(-1, std.posix.W.NOHANG);
        }
    }
}

fn handleConnection(unix_fd: std.posix.fd_t) !void {
    defer std.posix.close(unix_fd);

    const vsock_fd = connectHost() catch return;
    defer std.posix.close(vsock_fd);

    relayLoop(unix_fd, vsock_fd);
}

fn connectHost() !std.posix.fd_t {
    const fd = try std.posix.socket(AF_VSOCK, std.posix.SOCK.STREAM, 0);
    errdefer std.posix.close(fd);

    var addr = sockaddr_vm{
        .svm_port = ssh_agent_port,
        .svm_cid = VMADDR_CID_HOST,
    };
    try std.posix.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_vm));
    return fd;
}

fn relayLoop(a: std.posix.fd_t, b: std.posix.fd_t) void {
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = a, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = b, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var buf: [8192]u8 = undefined;
    while (true) {
        _ = std.posix.poll(&poll_fds, -1) catch return;

        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const n = std.posix.read(a, &buf) catch return;
            if (n == 0) return;
            writeAll(b, buf[0..n]) catch return;
        }
        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            const n = std.posix.read(b, &buf) catch return;
            if (n == 0) return;
            writeAll(a, buf[0..n]) catch return;
        }

        const hup = std.posix.POLL.HUP | std.posix.POLL.ERR;
        if (poll_fds[0].revents & hup != 0) return;
        if (poll_fds[1].revents & hup != 0) return;
    }
}

fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = std.posix.write(fd, data[written..]) catch return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}
