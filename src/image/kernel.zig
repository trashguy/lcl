/// Kernel decompression — extracts raw ARM64 Image from PE/COFF stub.
/// Alpine vmlinuz is a PE stub with a gzip-compressed ARM64 kernel inside.
/// VZLinuxBootLoader requires the raw ARM64 Image format.

const std = @import("std");

pub const KernelError = error{
    FileError,
    NotArm64Image,
    DecompressError,
    OutOfMemory,
};

/// ARM64 kernel magic bytes "ARM\x64" at offset 0x38
const arm64_magic_offset = 0x38;
const arm64_magic = [_]u8{ 'A', 'R', 'M', 0x64 };

/// Gzip header magic
const gzip_magic = [_]u8{ 0x1f, 0x8b, 0x08 };

/// Check if data has ARM64 Image magic at the expected offset.
fn isArm64Image(data: []const u8) bool {
    if (data.len < arm64_magic_offset + arm64_magic.len) return false;
    return std.mem.eql(u8, data[arm64_magic_offset..][0..arm64_magic.len], &arm64_magic);
}

/// Decompress a PE/COFF vmlinuz to a raw ARM64 kernel Image.
/// If the source is already a raw ARM64 Image, copies as-is.
pub fn decompressKernel(allocator: std.mem.Allocator, src_path: []const u8, dest_path: []const u8) KernelError!void {
    // Read the vmlinuz file
    const src_data = std.fs.cwd().readFileAlloc(allocator, src_path, 64 * 1024 * 1024) catch return error.FileError;
    defer allocator.free(src_data);

    // Already a raw ARM64 Image?
    if (isArm64Image(src_data)) {
        std.fs.cwd().writeFile(.{ .sub_path = dest_path, .data = src_data }) catch return error.FileError;
        return;
    }

    // Scan for gzip headers and try to decompress each candidate
    var offset: usize = 0;
    while (offset + gzip_magic.len < src_data.len) : (offset += 1) {
        if (!std.mem.eql(u8, src_data[offset..][0..gzip_magic.len], &gzip_magic))
            continue;

        // Write the gzip portion to a temp file, then decompress via file reader
        if (tryDecompressFromOffset(allocator, src_data[offset..], dest_path)) |_| {
            return;
        }
    }

    return error.NotArm64Image;
}

fn tryDecompressFromOffset(allocator: std.mem.Allocator, data: []const u8, dest_path: []const u8) ?void {
    // Write compressed data to a temp file
    const tmp_path = "/tmp/lcl-kernel-decompress.tmp";
    std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = data }) catch return null;
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Open and decompress via file reader
    const file = std.fs.openFileAbsolute(tmp_path, .{}) catch return null;
    defer file.close();

    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(&read_buf);

    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &window_buf);

    // Read decompressed data
    var result = allocator.alloc(u8, 64 * 1024 * 1024) catch return null;
    defer allocator.free(result);

    var total: usize = 0;
    var chunk_buf: [65536]u8 = undefined;
    while (true) {
        const n = decompress.reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        if (total + n > result.len) break;
        @memcpy(result[total..][0..n], chunk_buf[0..n]);
        total += n;
    }

    if (total < arm64_magic_offset + arm64_magic.len) return null;
    if (!isArm64Image(result[0..total])) return null;

    std.fs.cwd().writeFile(.{ .sub_path = dest_path, .data = result[0..total] }) catch return null;
    return {};
}
