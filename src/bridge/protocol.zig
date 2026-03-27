/// LCL bridge wire protocol.
/// Simple binary messages over vsock. No protobuf, no gRPC.
///
/// Wire format:
///   [MessageHeader: 4 bytes] [payload: payload_len bytes]
///
/// Payload is zero or more TLV fields:
///   [tag: u8] [len: u16 LE] [value: len bytes]
///
/// Both host and guest are aarch64 (little-endian). All multi-byte
/// integers are little-endian on the wire.

const std = @import("std");

// ── Message types ───────────────────────────────────────────────────

pub const MessageType = enum(u8) {
    // Keychain
    keychain_get = 0x01,
    keychain_set = 0x02,
    keychain_delete = 0x03,

    // Clipboard
    clipboard_get = 0x10,
    clipboard_set = 0x11,

    // Open (URLs, files)
    open = 0x20,

    // Notifications
    notify = 0x30,

    // Okta
    okta_get_token = 0x40,

    // Responses
    response_ok = 0xF0,
    response_error = 0xFF,

    _,
};

// ── Header ──────────────────────────────────────────────────────────

pub const MessageHeader = extern struct {
    msg_type: MessageType,
    request_id: u8 = 0,
    payload_len: u16 = 0,
};

pub const header_size = @sizeOf(MessageHeader);
pub const max_payload_size = 64 * 1024; // 64 KiB

// ── TLV field tags ──────────────────────────────────────────────────

pub const FieldTag = enum(u8) {
    service = 0x01,
    account = 0x02,
    password = 0x03,
    text = 0x04,
    url = 0x05,
    title = 0x06,
    body = 0x07,
    _,
};

pub const field_header_size = 3; // tag(1) + len(2)

// ── Payload builder ─────────────────────────────────────────────────

pub const PayloadBuilder = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) PayloadBuilder {
        return .{ .buf = buf };
    }

    /// Append a TLV field. Returns error if buffer is too small.
    pub fn addField(self: *PayloadBuilder, tag: FieldTag, value: []const u8) !void {
        if (value.len > std.math.maxInt(u16))
            return error.FieldTooLarge;
        const needed = field_header_size + value.len;
        if (self.pos + needed > self.buf.len)
            return error.BufferTooSmall;

        self.buf[self.pos] = @intFromEnum(tag);
        std.mem.writeInt(u16, self.buf[self.pos + 1 ..][0..2], @intCast(value.len), .little);
        if (value.len > 0) {
            @memcpy(self.buf[self.pos + field_header_size ..][0..value.len], value);
        }
        self.pos += needed;
    }

    pub fn payload(self: *const PayloadBuilder) []const u8 {
        return self.buf[0..self.pos];
    }
};

// ── TLV field iterator ──────────────────────────────────────────────

pub const Field = struct {
    tag: FieldTag,
    value: []const u8,
};

pub const FieldIterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) FieldIterator {
        return .{ .data = data };
    }

    pub fn next(self: *FieldIterator) ?Field {
        if (self.pos + field_header_size > self.data.len)
            return null;

        const tag: FieldTag = @enumFromInt(self.data[self.pos]);
        const len = std.mem.readInt(u16, self.data[self.pos + 1 ..][0..2], .little);
        const value_start = self.pos + field_header_size;
        const value_end = value_start + len;

        if (value_end > self.data.len)
            return null;

        self.pos = value_end;
        return .{
            .tag = tag,
            .value = self.data[value_start..value_end],
        };
    }
};

/// Find the first field with the given tag, or null.
pub fn findField(payload_data: []const u8, tag: FieldTag) ?[]const u8 {
    var it = FieldIterator.init(payload_data);
    while (it.next()) |field| {
        if (field.tag == tag) return field.value;
    }
    return null;
}

// ── Read / write messages ───────────────────────────────────────────

pub const ProtocolError = error{
    PayloadTooLarge,
    InvalidMessageType,
    ConnectionClosed,
    Unexpected,
};

/// Read exactly `buf.len` bytes from a file descriptor.
fn readExact(fd: std.posix.fd_t, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return error.Unexpected,
        };
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
}

/// Write all bytes to a file descriptor.
fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var total: usize = 0;
    while (total < data.len) {
        const n = std.posix.write(fd, data[total..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return error.Unexpected,
        };
        total += n;
    }
}

/// Read a message header from a file descriptor.
pub fn readHeader(fd: std.posix.fd_t) !MessageHeader {
    var buf: [header_size]u8 = undefined;
    try readExact(fd, &buf);
    return @bitCast(buf);
}

/// Read the payload for a message (caller provides buffer).
/// Returns the slice of `buf` that was filled.
pub fn readPayload(fd: std.posix.fd_t, len: u16, buf: []u8) ![]const u8 {
    if (len == 0) return buf[0..0];
    if (len > max_payload_size or len > buf.len)
        return error.PayloadTooLarge;
    try readExact(fd, buf[0..len]);
    return buf[0..len];
}

/// Write a complete message (header + payload) to a file descriptor.
pub fn writeMessage(fd: std.posix.fd_t, msg_type: MessageType, request_id: u8, payload_data: []const u8) !void {
    if (payload_data.len > std.math.maxInt(u16) or payload_data.len > max_payload_size)
        return error.PayloadTooLarge;

    const header = MessageHeader{
        .msg_type = msg_type,
        .request_id = request_id,
        .payload_len = @intCast(payload_data.len),
    };
    const header_bytes: [header_size]u8 = @bitCast(header);
    try writeAll(fd, &header_bytes);
    if (payload_data.len > 0) {
        try writeAll(fd, payload_data);
    }
}

/// Write an error response.
pub fn writeError(fd: std.posix.fd_t, request_id: u8, msg: []const u8) !void {
    var buf: [max_payload_size]u8 = undefined;
    var builder = PayloadBuilder.init(&buf);
    builder.addField(.text, msg) catch {
        // If error message is too large, truncate
        builder.addField(.text, "internal error") catch unreachable;
    };
    try writeMessage(fd, .response_error, request_id, builder.payload());
}

/// Write a success response with a single text field.
pub fn writeOkText(fd: std.posix.fd_t, request_id: u8, text: []const u8) !void {
    var buf: [max_payload_size]u8 = undefined;
    var builder = PayloadBuilder.init(&buf);
    try builder.addField(.text, text);
    try writeMessage(fd, .response_ok, request_id, builder.payload());
}

/// Write a success response with raw payload bytes.
pub fn writeOk(fd: std.posix.fd_t, request_id: u8, payload_data: []const u8) !void {
    try writeMessage(fd, .response_ok, request_id, payload_data);
}

/// Write a success response with empty payload.
pub fn writeOkEmpty(fd: std.posix.fd_t, request_id: u8) !void {
    try writeMessage(fd, .response_ok, request_id, &.{});
}

// ── Tests ───────────────────────────────────────────────────────────

test "header size is 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), header_size);
}

test "PayloadBuilder + FieldIterator round-trip" {
    var buf: [256]u8 = undefined;
    var builder = PayloadBuilder.init(&buf);

    try builder.addField(.service, "my-vpn");
    try builder.addField(.account, "adam");
    try builder.addField(.password, "secret123");

    const data = builder.payload();

    var it = FieldIterator.init(data);

    const f1 = it.next().?;
    try std.testing.expectEqual(FieldTag.service, f1.tag);
    try std.testing.expectEqualStrings("my-vpn", f1.value);

    const f2 = it.next().?;
    try std.testing.expectEqual(FieldTag.account, f2.tag);
    try std.testing.expectEqualStrings("adam", f2.value);

    const f3 = it.next().?;
    try std.testing.expectEqual(FieldTag.password, f3.tag);
    try std.testing.expectEqualStrings("secret123", f3.value);

    try std.testing.expect(it.next() == null);
}

test "findField returns correct value" {
    var buf: [128]u8 = undefined;
    var builder = PayloadBuilder.init(&buf);

    try builder.addField(.title, "Build Done");
    try builder.addField(.body, "All tests passed");

    const data = builder.payload();

    const title = findField(data, .title).?;
    try std.testing.expectEqualStrings("Build Done", title);

    const body = findField(data, .body).?;
    try std.testing.expectEqualStrings("All tests passed", body);

    try std.testing.expect(findField(data, .service) == null);
}

test "findField empty payload" {
    try std.testing.expect(findField(&.{}, .service) == null);
}

test "PayloadBuilder overflow" {
    var buf: [4]u8 = undefined;
    var builder = PayloadBuilder.init(&buf);
    // field_header_size(3) + 5 bytes = 8, doesn't fit in 4
    try std.testing.expectError(error.BufferTooSmall, builder.addField(.text, "hello"));
}

test "empty field value" {
    var buf: [32]u8 = undefined;
    var builder = PayloadBuilder.init(&buf);
    try builder.addField(.text, "");

    var it = FieldIterator.init(builder.payload());
    const f = it.next().?;
    try std.testing.expectEqual(FieldTag.text, f.tag);
    try std.testing.expectEqualStrings("", f.value);
}

test "MessageHeader bitcast round-trip" {
    const header = MessageHeader{
        .msg_type = .keychain_get,
        .request_id = 42,
        .payload_len = 1234,
    };
    const bytes: [header_size]u8 = @bitCast(header);
    const restored: MessageHeader = @bitCast(bytes);
    try std.testing.expectEqual(header.msg_type, restored.msg_type);
    try std.testing.expectEqual(header.request_id, restored.request_id);
    try std.testing.expectEqual(header.payload_len, restored.payload_len);
}
