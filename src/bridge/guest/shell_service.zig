/// Guest shell service — listens on vsock port 5001, spawns PTY shells.
/// Each incoming connection gets a forked PTY with the user's shell.
/// Bidirectional relay: PTY output → vsock, vsock input → PTY.
///
/// Runs as a daemon inside the Linux guest.

const std = @import("std");
const shell_proto = @import("shell_protocol");

// ── Linux constants ─────────────────────────────────────────────────

const AF_VSOCK = 40;
const VMADDR_CID_ANY: u32 = 0xFFFFFFFF;

const sockaddr_vm = extern struct {
    svm_family: u16 = AF_VSOCK,
    svm_reserved1: u16 = 0,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [4]u8 = .{ 0, 0, 0, 0 },
};

// PTY ioctls
const TIOCSWINSZ = 0x5414;
const TIOCGPTN = 0x80045430;
const TIOCSPTLCK = 0x40045431;

// ── Entry point ─────────────────────────────────────────────────────

pub fn run() !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.writeAll("lcl-shell-service: starting on vsock port 5001\n") catch {};

    // Create vsock listening socket
    const listen_fd = try std.posix.socket(AF_VSOCK, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(listen_fd);

    var addr = sockaddr_vm{
        .svm_port = shell_proto.shell_port,
        .svm_cid = VMADDR_CID_ANY,
    };

    try std.posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(sockaddr_vm));
    try std.posix.listen(listen_fd, 4);

    stderr.writeAll("lcl-shell-service: listening\n") catch {};

    // Accept loop
    while (true) {
        const conn_fd = std.posix.accept(listen_fd, null, null, 0) catch |err| {
            stderr.print("accept error: {s}\n", .{@errorName(err)}) catch {};
            continue;
        };

        // Fork to handle each connection
        const pid = std.posix.fork() catch {
            std.posix.close(conn_fd);
            continue;
        };

        if (pid == 0) {
            // Child — handle the connection
            std.posix.close(listen_fd);
            handleConnection(conn_fd) catch {};
            std.process.exit(0);
        } else {
            // Parent — close our copy and continue accepting
            std.posix.close(conn_fd);
            // Reap zombies (non-blocking)
            _ = std.posix.waitpid(-1, std.posix.W.NOHANG);
        }
    }
}

// ── Connection handler ──────────────────────────────────────────────

fn handleConnection(conn_fd: std.posix.fd_t) !void {
    defer std.posix.close(conn_fd);

    // Open a PTY
    const pty = try openPty();
    defer std.posix.close(pty.master);

    // Set initial terminal size
    var ws = std.posix.winsize{
        .col = 80,
        .row = 24,
        .xpixel = 0,
        .ypixel = 0,
    };
    _ = std.posix.system.ioctl(pty.master, TIOCSWINSZ, @intFromPtr(&ws));

    // Fork the shell process
    const shell_pid = std.posix.fork() catch return;

    if (shell_pid == 0) {
        // Child — become session leader, set controlling terminal, exec shell
        std.posix.close(pty.master);
        std.posix.close(conn_fd);

        // setsid via raw syscall (avoids bitcast bug in std on aarch64)
        _ = std.posix.system.syscall1(.setsid, 0);

        // Set controlling terminal
        _ = std.posix.system.ioctl(pty.slave, std.posix.T.IOCSCTTY, 0);

        // Redirect stdio to the slave PTY
        std.posix.dup2(pty.slave, 0) catch {};
        std.posix.dup2(pty.slave, 1) catch {};
        std.posix.dup2(pty.slave, 2) catch {};
        if (pty.slave > 2) std.posix.close(pty.slave);

        // Set environment
        const env = [_:null]?[*:0]const u8{
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "LANG=en_US.UTF-8",
            "HOME=/root",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            null,
        };

        // Try shells in order
        const shells = [_][*:0]const u8{ "/bin/zsh", "/bin/bash", "/bin/sh" };
        for (shells) |shell| {
            const argv = [_:null]?[*:0]const u8{ shell, null };
            std.posix.execveZ(shell, &argv, &env) catch continue;
        }
        std.process.exit(1);
    }

    // Parent — relay between vsock and PTY master
    std.posix.close(pty.slave);

    relayLoop(conn_fd, pty.master) catch {};

    // Kill the shell when connection closes
    std.posix.kill(shell_pid, std.posix.SIG.HUP) catch {};
    _ = std.posix.waitpid(shell_pid, 0);
}

// ── PTY management ──────────────────────────────────────────────────

const Pty = struct { master: std.posix.fd_t, slave: std.posix.fd_t };

fn openPty() !Pty {
    // Open /dev/ptmx
    const master = try std.posix.openZ("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer std.posix.close(master);

    // Unlock the slave
    var unlock: c_int = 0;
    _ = std.posix.system.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock));

    // Get the slave PTY number
    var pty_num: c_int = 0;
    _ = std.posix.system.ioctl(master, TIOCGPTN, @intFromPtr(&pty_num));

    // Open the slave
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/dev/pts/{d}", .{pty_num}) catch return error.Unexpected;
    const slave = try std.posix.openZ(path, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);

    return .{ .master = master, .slave = slave };
}

// ── Relay loop ──────────────────────────────────────────────────────

fn relayLoop(conn_fd: std.posix.fd_t, master_fd: std.posix.fd_t) !void {
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = conn_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = master_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var frame_buf: [shell_proto.max_frame_size]u8 = undefined;
    var pty_buf: [4096]u8 = undefined;

    while (true) {
        _ = std.posix.poll(&poll_fds, -1) catch return;

        // Data from vsock (host input)
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const frame = shell_proto.readFrame(conn_fd, &frame_buf) catch return;
            if (frame == null) return; // connection closed

            switch (frame.?.frame_type) {
                .data => {
                    // Write input to PTY master
                    _ = std.posix.write(master_fd, frame.?.payload) catch return;
                },
                .resize => {
                    if (shell_proto.parseResize(frame.?.payload)) |sz| {
                        var winsize = std.posix.winsize{
                            .col = sz.cols,
                            .row = sz.rows,
                            .xpixel = 0,
                            .ypixel = 0,
                        };
                        _ = std.posix.system.ioctl(master_fd, TIOCSWINSZ, @intFromPtr(&winsize));
                    }
                },
                else => return,
            }
        }

        // Data from PTY (shell output)
        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            const n = std.posix.read(master_fd, &pty_buf) catch return;
            if (n == 0) return; // PTY closed (shell exited)
            shell_proto.writeData(conn_fd, pty_buf[0..n]) catch return;
        }

        // Check for hangup/error on either fd
        const hup_err = std.posix.POLL.HUP | std.posix.POLL.ERR;
        if (poll_fds[0].revents & hup_err != 0) return;
        if (poll_fds[1].revents & hup_err != 0) return;
    }
}
