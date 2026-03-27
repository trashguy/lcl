/// LCL bridge guest client — runs inside the Linux VM.
/// Connects to the host bridge daemon over vsock and exposes
/// macOS APIs as CLI commands.
///
/// Usage (via symlinks or subcommands):
///   lcl-bridge-guest clipboard get
///   lcl-bridge-guest clipboard set < text
///   lcl-bridge-guest keychain get --service vpn --account adam
///   lcl-bridge-guest keychain set --service vpn --account adam --password secret
///   lcl-bridge-guest keychain delete --service vpn --account adam
///   lcl-bridge-guest open https://example.com
///   lcl-bridge-guest notify --title "LCL" --body "Build done"

const std = @import("std");
const protocol = @import("protocol");
const shell_service = @import("shell_service");


// ── vsock constants (Linux) ─────────────────────────────────────────

const AF_VSOCK = 40;
const VMADDR_CID_HOST = 2;
const BRIDGE_PORT = 5000;

const sockaddr_vm = extern struct {
    svm_family: u16 = AF_VSOCK,
    svm_reserved1: u16 = 0,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [4]u8 = .{ 0, 0, 0, 0 },
};

// ── Entry point ─────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Determine command from argv[0] (busybox style) or argv[1] (subcommand)
    const prog_name = std.fs.path.basename(args[0]);
    const cmd_args = if (isBridgeMain(prog_name))
        args[1..] // lcl-bridge-guest <cmd> [args...]
    else
        args[0..]; // macos-clipboard [args...] (symlink)

    if (cmd_args.len == 0) {
        printUsage();
        return;
    }

    const command = resolveCommand(cmd_args[0]);
    if (command == null) {
        try stderrPrint("unknown command: {s}\n", .{cmd_args[0]});
        printUsage();
        std.process.exit(1);
    }

    command.?(allocator, cmd_args[1..]) catch |err| {
        try stderrPrint("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn isBridgeMain(name: []const u8) bool {
    return std.mem.eql(u8, name, "lcl-bridge-guest");
}

const CommandFn = *const fn (std.mem.Allocator, []const []const u8) anyerror!void;

fn resolveCommand(name: []const u8) ?CommandFn {
    if (std.mem.eql(u8, name, "clipboard") or std.mem.eql(u8, name, "macos-clipboard"))
        return &cmdClipboard;
    if (std.mem.eql(u8, name, "keychain") or std.mem.eql(u8, name, "macos-keychain"))
        return &cmdKeychain;
    if (std.mem.eql(u8, name, "open") or std.mem.eql(u8, name, "macos-open"))
        return &cmdOpen;
    if (std.mem.eql(u8, name, "notify") or std.mem.eql(u8, name, "macos-notify"))
        return &cmdNotify;
    if (std.mem.eql(u8, name, "shell-service"))
        return &cmdShellService;
    if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "--help"))
        return &cmdHelp;
    return null;
}

fn printUsage() void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.writeAll(
        \\Usage: lcl-bridge-guest <command> [args...]
        \\
        \\Commands:
        \\  clipboard get          Read macOS clipboard
        \\  clipboard set          Write stdin to macOS clipboard
        \\  keychain get           Read a Keychain password
        \\  keychain set           Store a Keychain password
        \\  keychain delete        Delete a Keychain password
        \\  open <url|path>        Open URL or file on macOS
        \\  notify                 Post a macOS notification
        \\  shell-service          Start PTY shell daemon (vsock port 5001)
        \\  help                   Show this help
        \\
    ) catch {};
}

fn stderrPrint(comptime fmt: []const u8, args: anytype) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.print(fmt, args);
}

fn cmdShellService(_: std.mem.Allocator, _: []const []const u8) !void {
    try shell_service.run();
}

fn cmdHelp(_: std.mem.Allocator, _: []const []const u8) !void {
    printUsage();
}

// ── vsock connection ────────────────────────────────────────────────

fn connectToHost() !std.posix.fd_t {
    const fd = try std.posix.socket(AF_VSOCK, std.posix.SOCK.STREAM, 0);
    errdefer std.posix.close(fd);

    var addr = sockaddr_vm{
        .svm_port = BRIDGE_PORT,
        .svm_cid = VMADDR_CID_HOST,
    };

    try std.posix.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_vm));
    return fd;
}

const Response = struct {
    fd: std.posix.fd_t,
    header: protocol.MessageHeader,
    buf: [protocol.max_payload_size]u8,
    len: u16,

    fn payload(self: *const Response) []const u8 {
        return self.buf[0..self.len];
    }

    fn close(self: *const Response) void {
        std.posix.close(self.fd);
    }
};

fn sendRequest(msg_type: protocol.MessageType, req_payload: []const u8) !Response {
    const fd = try connectToHost();
    errdefer std.posix.close(fd);

    try protocol.writeMessage(fd, msg_type, 0, req_payload);

    const resp_header = try protocol.readHeader(fd);
    var result = Response{
        .fd = fd,
        .header = resp_header,
        .buf = undefined,
        .len = resp_header.payload_len,
    };

    var tmp_buf: [protocol.max_payload_size]u8 = undefined;
    const resp_data = try protocol.readPayload(fd, resp_header.payload_len, &tmp_buf);
    @memcpy(result.buf[0..resp_data.len], resp_data);
    return result;
}

fn checkResponse(resp: *const Response) !void {
    if (resp.header.msg_type == .response_error) {
        const text = protocol.findField(resp.payload(), .text) orelse "unknown error";
        try stderrPrint("error: {s}\n", .{text});
        std.process.exit(1);
    }
}

// ── Clipboard commands ──────────────────────────────────────────────

fn cmdClipboard(_: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderrPrint("Usage: clipboard get|set\n", .{});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[0], "get") or std.mem.eql(u8, args[0], "paste")) {
        const resp = try sendRequest(.clipboard_get, &.{});
        defer resp.close();
        try checkResponse(&resp);

        const text = protocol.findField(resp.payload(), .text) orelse "";
        const stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll(text);
    } else if (std.mem.eql(u8, args[0], "set") or std.mem.eql(u8, args[0], "copy")) {
        // Read stdin
        const stdin = std.fs.File.stdin();
        var buf: [protocol.max_payload_size - 64]u8 = undefined;
        const len = try stdin.readAll(&buf);

        var payload_buf: [protocol.max_payload_size]u8 = undefined;
        var builder = protocol.PayloadBuilder.init(&payload_buf);
        try builder.addField(.text, buf[0..len]);

        const resp = try sendRequest(.clipboard_set, builder.payload());
        defer resp.close();
        try checkResponse(&resp);
    } else {
        try stderrPrint("unknown clipboard subcommand: {s}\n", .{args[0]});
        std.process.exit(1);
    }
}

// ── Keychain commands ───────────────────────────────────────────────

fn cmdKeychain(_: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderrPrint("Usage: keychain get|set|delete --service <svc> --account <acct> [--password <pw>]\n", .{});
        std.process.exit(1);
    }

    const subcmd = args[0];
    var service: ?[]const u8 = null;
    var account: ?[]const u8 = null;
    var password: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--service") or std.mem.eql(u8, args[i], "-s")) {
            i += 1;
            if (i < args.len) service = args[i];
        } else if (std.mem.eql(u8, args[i], "--account") or std.mem.eql(u8, args[i], "-a")) {
            i += 1;
            if (i < args.len) account = args[i];
        } else if (std.mem.eql(u8, args[i], "--password") or std.mem.eql(u8, args[i], "-p")) {
            i += 1;
            if (i < args.len) password = args[i];
        }
    }

    const svc = service orelse {
        try stderrPrint("--service is required\n", .{});
        std.process.exit(1);
    };
    const acct = account orelse {
        try stderrPrint("--account is required\n", .{});
        std.process.exit(1);
    };

    if (std.mem.eql(u8, subcmd, "get")) {
        var payload_buf: [protocol.max_payload_size]u8 = undefined;
        var builder = protocol.PayloadBuilder.init(&payload_buf);
        try builder.addField(.service, svc);
        try builder.addField(.account, acct);

        const resp = try sendRequest(.keychain_get, builder.payload());
        defer resp.close();
        try checkResponse(&resp);

        const pw = protocol.findField(resp.payload(), .password) orelse "";
        const stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll(pw);
        try stdout.writeAll("\n");
    } else if (std.mem.eql(u8, subcmd, "set")) {
        const pw = password orelse {
            try stderrPrint("--password is required for set\n", .{});
            std.process.exit(1);
        };

        var payload_buf: [protocol.max_payload_size]u8 = undefined;
        var builder = protocol.PayloadBuilder.init(&payload_buf);
        try builder.addField(.service, svc);
        try builder.addField(.account, acct);
        try builder.addField(.password, pw);

        const resp = try sendRequest(.keychain_set, builder.payload());
        defer resp.close();
        try checkResponse(&resp);
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        var payload_buf: [protocol.max_payload_size]u8 = undefined;
        var builder = protocol.PayloadBuilder.init(&payload_buf);
        try builder.addField(.service, svc);
        try builder.addField(.account, acct);

        const resp = try sendRequest(.keychain_delete, builder.payload());
        defer resp.close();
        try checkResponse(&resp);
    } else {
        try stderrPrint("unknown keychain subcommand: {s}\n", .{subcmd});
        std.process.exit(1);
    }
}

// ── Open command ────────────────────────────────────────────────────

fn cmdOpen(_: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderrPrint("Usage: open <url|path>\n", .{});
        std.process.exit(1);
    }

    var payload_buf: [protocol.max_payload_size]u8 = undefined;
    var builder = protocol.PayloadBuilder.init(&payload_buf);
    try builder.addField(.url, args[0]);

    const resp = try sendRequest(.open, builder.payload());
    defer resp.close();
    try checkResponse(&resp);
}

// ── Notify command ──────────────────────────────────────────────────

fn cmdNotify(_: std.mem.Allocator, args: []const []const u8) !void {
    var title: []const u8 = "LCL";
    var body: []const u8 = "";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--title") or std.mem.eql(u8, args[i], "-t")) {
            i += 1;
            if (i < args.len) title = args[i];
        } else if (std.mem.eql(u8, args[i], "--body") or std.mem.eql(u8, args[i], "-b")) {
            i += 1;
            if (i < args.len) body = args[i];
        } else {
            // Positional: treat as body
            body = args[i];
        }
    }

    var payload_buf: [protocol.max_payload_size]u8 = undefined;
    var builder = protocol.PayloadBuilder.init(&payload_buf);
    try builder.addField(.title, title);
    try builder.addField(.body, body);

    const resp = try sendRequest(.notify, builder.payload());
    defer resp.close();
    try checkResponse(&resp);
}
