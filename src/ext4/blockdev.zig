/// File-backed block device for lwext4.
/// Implements the ext4_blockdev_iface callbacks using Zig file I/O.

const std = @import("std");
const ext4 = @import("ext4.zig");
const c = ext4.c;

// ── Module state ────────────────────────────────────────────────────
// lwext4 only supports one mount at a time, so global state is fine.

var backing_file: ?std.fs.File = null;
var ph_buf: [4096]u8 align(16) = undefined;

var iface = c.ext4_blockdev_iface{
    .open = &bdOpen,
    .bread = &bdRead,
    .bwrite = &bdWrite,
    .close = &bdClose,
    .lock = null,
    .unlock = null,
    .ph_bsize = 4096,
    .ph_bcnt = 0,
    .ph_bbuf = &ph_buf,
    .ph_refctr = 0,
    .bread_ctr = 0,
    .bwrite_ctr = 0,
    .p_user = null,
};

var bdev = c.ext4_blockdev{
    .bdif = &iface,
    .part_offset = 0,
    .part_size = 0,
    .bc = null,
    .lg_bsize = 0,
    .lg_bcnt = 0,
    .cache_write_back = 0,
    .fs = null,
    .journal = null,
};

// ── Public API ──────────────────────────────────────────────────────

/// Initialize the block device backed by a file.
/// Creates a sparse file of the given size if it doesn't exist,
/// or opens an existing one.
pub fn init(path: []const u8, total_size: u64) !void {
    // Create or open the backing file
    const file = try std.fs.createFileAbsolute(path, .{
        .read = true,
        .truncate = false,
    });
    errdefer file.close();

    // Set file to exact size (truncate if exists, extend if new)
    try file.setEndPos(total_size);

    backing_file = file;

    // Configure the block device
    const block_count = total_size / 4096;
    iface.ph_bcnt = block_count;
    bdev.part_size = total_size;
}

/// Clean up the block device.
pub fn deinit() void {
    if (backing_file) |file| {
        file.close();
        backing_file = null;
    }
}

/// Get a pointer to the ext4_blockdev for use with lwext4 functions.
pub fn getDevice() *c.ext4_blockdev {
    return &bdev;
}

// ── C callbacks ─────────────────────────────────────────────────────

fn bdOpen(_: [*c]c.ext4_blockdev) callconv(.c) c_int {
    // Already opened in init()
    return 0;
}

fn bdRead(_: [*c]c.ext4_blockdev, buf: ?*anyopaque, blk_id: u64, blk_cnt: u32) callconv(.c) c_int {
    const file = backing_file orelse return 5; // EIO
    const dst: [*]u8 = @ptrCast(buf orelse return 22); // EINVAL
    const offset = blk_id * 4096;
    const size = @as(usize, blk_cnt) * 4096;

    const bytes_read = file.pread(dst[0..size], offset) catch return 5;
    if (bytes_read < size) {
        // Zero-fill remainder (sparse file)
        @memset(dst[bytes_read..size], 0);
    }
    return 0;
}

fn bdWrite(_: [*c]c.ext4_blockdev, buf: ?*const anyopaque, blk_id: u64, blk_cnt: u32) callconv(.c) c_int {
    const file = backing_file orelse return 5; // EIO
    const src: [*]const u8 = @ptrCast(buf orelse return 22); // EINVAL
    const offset = blk_id * 4096;
    const size = @as(usize, blk_cnt) * 4096;

    file.pwriteAll(src[0..size], offset) catch return 5;
    return 0;
}

fn bdClose(_: [*c]c.ext4_blockdev) callconv(.c) c_int {
    // Don't close the file here — deinit() handles that
    return 0;
}

// ── Tests ───────────────────────────────────────────────────────────

test "blockdev init and deinit" {
    const tmp_path = "/tmp/lcl-test-blockdev.img";
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    try init(tmp_path, 64 * 1024 * 1024); // 64 MB
    defer deinit();

    const dev = getDevice();
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), dev.part_size);
}
