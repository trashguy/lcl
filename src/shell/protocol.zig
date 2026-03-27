/// Shell streaming protocol over vsock.
/// Minimal framing for continuous PTY I/O, separate from the
/// bridge RPC protocol on port 5000.
///
/// Frame format: type(u8) + length(u16 LE) + payload(length bytes)

const std = @import("std");

pub const shell_port: u32 = 5001;

// ── Frame types ─────────────────────────────────────────────────────

pub const FrameType = enum(u8) {
    data = 0x01, // terminal I/O bytes
    resize = 0x02, // 4 bytes: cols(u16 LE) + rows(u16 LE)
    close = 0x03, // clean shutdown, 0 bytes
    _,
};

pub const frame_header_size = 3; // type(1) + length(2)
pub const max_frame_size = 64 * 1024;

// ── Read / write ────────────────────────────────────────────────────

pub const Frame = struct {
    frame_type: FrameType,
    payload: []const u8,
};

pub const FrameError = error{
    ConnectionClosed,
    InvalidFrame,
    Unexpected,
};

fn readExact(fd: std.posix.fd_t, buf: []u8) FrameError!void {
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

fn writeAll(fd: std.posix.fd_t, data: []const u8) FrameError!void {
    var total: usize = 0;
    while (total < data.len) {
        const n = std.posix.write(fd, data[total..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return error.Unexpected,
        };
        total += n;
    }
}

/// Read a single frame. Returns null on clean close.
pub fn readFrame(fd: std.posix.fd_t, buf: []u8) FrameError!?Frame {
    var hdr: [frame_header_size]u8 = undefined;
    readExact(fd, &hdr) catch |err| switch (err) {
        error.ConnectionClosed => return null,
        else => return err,
    };

    const frame_type: FrameType = @enumFromInt(hdr[0]);
    const length = std.mem.readInt(u16, hdr[1..3], .little);

    if (length > buf.len) return error.InvalidFrame;

    if (length > 0) {
        try readExact(fd, buf[0..length]);
    }

    if (frame_type == .close) return null;

    return .{
        .frame_type = frame_type,
        .payload = buf[0..length],
    };
}

/// Write a data frame.
pub fn writeData(fd: std.posix.fd_t, payload: []const u8) FrameError!void {
    if (payload.len == 0) return;
    if (payload.len > std.math.maxInt(u16)) return error.InvalidFrame;

    var hdr: [frame_header_size]u8 = undefined;
    hdr[0] = @intFromEnum(FrameType.data);
    std.mem.writeInt(u16, hdr[1..3], @intCast(payload.len), .little);
    try writeAll(fd, &hdr);
    try writeAll(fd, payload);
}

/// Write a resize frame.
pub fn writeResize(fd: std.posix.fd_t, cols: u16, rows: u16) FrameError!void {
    var hdr: [frame_header_size]u8 = undefined;
    hdr[0] = @intFromEnum(FrameType.resize);
    std.mem.writeInt(u16, hdr[1..3], 4, .little); // payload is 4 bytes

    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], cols, .little);
    std.mem.writeInt(u16, payload[2..4], rows, .little);

    try writeAll(fd, &hdr);
    try writeAll(fd, &payload);
}

/// Write a close frame.
pub fn writeClose(fd: std.posix.fd_t) FrameError!void {
    var hdr: [frame_header_size]u8 = undefined;
    hdr[0] = @intFromEnum(FrameType.close);
    std.mem.writeInt(u16, hdr[1..3], 0, .little);
    try writeAll(fd, &hdr);
}

/// Parse a resize frame payload into cols + rows.
pub fn parseResize(payload: []const u8) ?struct { cols: u16, rows: u16 } {
    if (payload.len < 4) return null;
    return .{
        .cols = std.mem.readInt(u16, payload[0..2], .little),
        .rows = std.mem.readInt(u16, payload[2..4], .little),
    };
}

// ── Tests ───────────────────────────────────────────────────────────

test "frame header size" {
    try std.testing.expectEqual(@as(usize, 3), frame_header_size);
}

test "resize payload parse" {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 120, .little);
    std.mem.writeInt(u16, payload[2..4], 40, .little);
    const result = parseResize(&payload).?;
    try std.testing.expectEqual(@as(u16, 120), result.cols);
    try std.testing.expectEqual(@as(u16, 40), result.rows);
}
