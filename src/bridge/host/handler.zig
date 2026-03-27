/// Bridge host handler — dispatches incoming requests from the guest
/// to the appropriate macOS API bindings and sends responses back.

const std = @import("std");
const protocol = @import("protocol");
const security = @import("security");
const pasteboard = @import("pasteboard");
const workspace = @import("workspace");
const notifications = @import("notifications");

pub const BridgeConfig = struct {
    keychain: bool = true,
    clipboard: bool = true,
    open: bool = true,
    notify: bool = true,
};

/// Handle a single bridge connection. Reads messages in a loop until
/// the connection is closed. Runs on the calling thread.
pub fn handleConnection(read_fd: std.posix.fd_t, write_fd: std.posix.fd_t, config: BridgeConfig) void {
    var payload_buf: [protocol.max_payload_size]u8 = undefined;

    while (true) {
        const header = protocol.readHeader(read_fd) catch |err| {
            switch (err) {
                error.ConnectionClosed => return,
                else => {
                    logErr("failed to read message header");
                    return;
                },
            }
        };

        const payload = protocol.readPayload(read_fd, header.payload_len, &payload_buf) catch |err| {
            switch (err) {
                error.PayloadTooLarge => {
                    protocol.writeError(write_fd, header.request_id, "payload too large") catch return;
                    continue;
                },
                else => return,
            }
        };

        dispatch(write_fd, header, payload, config);
    }
}

fn dispatch(write_fd: std.posix.fd_t, header: protocol.MessageHeader, payload: []const u8, config: BridgeConfig) void {
    switch (header.msg_type) {
        .keychain_get => if (config.keychain) handleKeychainGet(write_fd, header.request_id, payload) else writeDisabled(write_fd, header.request_id),
        .keychain_set => if (config.keychain) handleKeychainSet(write_fd, header.request_id, payload) else writeDisabled(write_fd, header.request_id),
        .keychain_delete => if (config.keychain) handleKeychainDelete(write_fd, header.request_id, payload) else writeDisabled(write_fd, header.request_id),
        .clipboard_get => if (config.clipboard) handleClipboardGet(write_fd, header.request_id) else writeDisabled(write_fd, header.request_id),
        .clipboard_set => if (config.clipboard) handleClipboardSet(write_fd, header.request_id, payload) else writeDisabled(write_fd, header.request_id),
        .open => if (config.open) handleOpen(write_fd, header.request_id, payload) else writeDisabled(write_fd, header.request_id),
        .notify => if (config.notify) handleNotify(write_fd, header.request_id, payload) else writeDisabled(write_fd, header.request_id),
        else => {
            protocol.writeError(write_fd, header.request_id, "unknown message type") catch {};
        },
    }
}

fn writeDisabled(fd: std.posix.fd_t, req_id: u8) void {
    protocol.writeError(fd, req_id, "feature disabled") catch {};
}

// ── Keychain handlers ───────────────────────────────────────────────

fn handleKeychainGet(fd: std.posix.fd_t, req_id: u8, payload: []const u8) void {
    const svc = protocol.findField(payload, .service) orelse {
        protocol.writeError(fd, req_id, "missing service field") catch {};
        return;
    };
    const acct = protocol.findField(payload, .account) orelse {
        protocol.writeError(fd, req_id, "missing account field") catch {};
        return;
    };

    // Use a fixed-size buffer to avoid allocator dependency
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const pw = security.getPassword(allocator, svc, acct) catch {
        protocol.writeError(fd, req_id, "keychain error") catch {};
        return;
    };

    if (pw) |password| {
        defer allocator.free(password);
        // Send password back as a password field
        var resp_buf: [protocol.max_payload_size]u8 = undefined;
        var builder = protocol.PayloadBuilder.init(&resp_buf);
        builder.addField(.password, password) catch {
            protocol.writeError(fd, req_id, "password too large") catch {};
            return;
        };
        protocol.writeOk(fd, req_id, builder.payload()) catch {};
    } else {
        protocol.writeError(fd, req_id, "not found") catch {};
    }
}

fn handleKeychainSet(fd: std.posix.fd_t, req_id: u8, payload: []const u8) void {
    const svc = protocol.findField(payload, .service) orelse {
        protocol.writeError(fd, req_id, "missing service field") catch {};
        return;
    };
    const acct = protocol.findField(payload, .account) orelse {
        protocol.writeError(fd, req_id, "missing account field") catch {};
        return;
    };
    const pw = protocol.findField(payload, .password) orelse {
        protocol.writeError(fd, req_id, "missing password field") catch {};
        return;
    };

    security.setPassword(svc, acct, pw) catch {
        protocol.writeError(fd, req_id, "keychain set failed") catch {};
        return;
    };
    protocol.writeOkEmpty(fd, req_id) catch {};
}

fn handleKeychainDelete(fd: std.posix.fd_t, req_id: u8, payload: []const u8) void {
    const svc = protocol.findField(payload, .service) orelse {
        protocol.writeError(fd, req_id, "missing service field") catch {};
        return;
    };
    const acct = protocol.findField(payload, .account) orelse {
        protocol.writeError(fd, req_id, "missing account field") catch {};
        return;
    };

    security.deletePassword(svc, acct) catch |err| {
        switch (err) {
            error.NotFound => protocol.writeError(fd, req_id, "not found") catch {},
            else => protocol.writeError(fd, req_id, "keychain delete failed") catch {},
        }
        return;
    };
    protocol.writeOkEmpty(fd, req_id) catch {};
}

// ── Clipboard handlers ──────────────────────────────────────────────

fn handleClipboardGet(fd: std.posix.fd_t, req_id: u8) void {
    if (pasteboard.getString()) |text| {
        protocol.writeOkText(fd, req_id, text) catch {};
    } else {
        protocol.writeOkText(fd, req_id, "") catch {};
    }
}

fn handleClipboardSet(fd: std.posix.fd_t, req_id: u8, payload: []const u8) void {
    const text = protocol.findField(payload, .text) orelse {
        protocol.writeError(fd, req_id, "missing text field") catch {};
        return;
    };

    if (pasteboard.setString(text)) {
        protocol.writeOkEmpty(fd, req_id) catch {};
    } else {
        protocol.writeError(fd, req_id, "clipboard set failed") catch {};
    }
}

// ── Open handler ────────────────────────────────────────────────────

fn handleOpen(fd: std.posix.fd_t, req_id: u8, payload: []const u8) void {
    const url = protocol.findField(payload, .url) orelse {
        protocol.writeError(fd, req_id, "missing url field") catch {};
        return;
    };

    if (workspace.open(url)) {
        protocol.writeOkEmpty(fd, req_id) catch {};
    } else {
        protocol.writeError(fd, req_id, "open failed") catch {};
    }
}

// ── Notify handler ──────────────────────────────────────────────────

fn handleNotify(fd: std.posix.fd_t, req_id: u8, payload: []const u8) void {
    const title = protocol.findField(payload, .title) orelse "LCL";
    const body = protocol.findField(payload, .body) orelse "";

    notifications.postNotification(title, body);
    protocol.writeOkEmpty(fd, req_id) catch {};
}

// ── Logging ─────────────────────────────────────────────────────────

fn logErr(msg: []const u8) void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll("lcl-bridge: ") catch {};
    stderr.writeAll(msg) catch {};
    stderr.writeAll("\n") catch {};
}
