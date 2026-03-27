/// Zig wrapper around lwext4 C library.
/// Provides idiomatic Zig API for ext4 filesystem operations.

const std = @import("std");

pub const c = @cImport({
    @cInclude("ext4.h");
    @cInclude("ext4_mkfs.h");
    @cInclude("ext4_blockdev.h");
});

pub const blockdev = @import("blockdev.zig");
pub const populate = @import("populate.zig");

// ── Error handling ──────────────────────────────────────────────────

pub const Ext4Error = error{
    Ext4Error,
    NotFound,
    NoSpace,
    PermissionDenied,
    IoError,
};

fn checkRc(rc: c_int) Ext4Error!void {
    if (rc == 0) return;
    return switch (rc) {
        2 => error.NotFound, // ENOENT
        13 => error.PermissionDenied, // EACCES
        28 => error.NoSpace, // ENOSPC
        else => error.Ext4Error,
    };
}

// ── Filesystem creation ─────────────────────────────────────────────

pub const FsType = enum(c_int) {
    ext2 = 2,
    ext3 = 3,
    ext4 = 4,
};

pub fn mkfs(bd: *c.ext4_blockdev, fs_type: FsType) Ext4Error!void {
    var fs: c.ext4_fs = std.mem.zeroes(c.ext4_fs);
    var info: c.ext4_mkfs_info = std.mem.zeroes(c.ext4_mkfs_info);
    info.block_size = 4096;
    info.journal = if (fs_type == .ext2) false else true;

    try checkRc(c.ext4_mkfs(&fs, bd, &info, @intFromEnum(fs_type)));
}

// ── Mount / unmount ─────────────────────────────────────────────────

pub fn deviceRegister(bd: *c.ext4_blockdev, name: [*:0]const u8) Ext4Error!void {
    try checkRc(c.ext4_device_register(bd, name));
}

pub fn mount(dev_name: [*:0]const u8, mount_point: [*:0]const u8) Ext4Error!void {
    try checkRc(c.ext4_mount(dev_name, mount_point, false));
}

pub fn recover(mount_point: [*:0]const u8) Ext4Error!void {
    try checkRc(c.ext4_recover(mount_point));
}

pub fn journalStart(mount_point: [*:0]const u8) Ext4Error!void {
    try checkRc(c.ext4_journal_start(mount_point));
}

pub fn journalStop(mount_point: [*:0]const u8) Ext4Error!void {
    try checkRc(c.ext4_journal_stop(mount_point));
}

pub fn cacheWriteBack(mount_point: [*:0]const u8, enable: bool) Ext4Error!void {
    try checkRc(c.ext4_cache_write_back(mount_point, enable));
}

pub fn umount(mount_point: [*:0]const u8) Ext4Error!void {
    try checkRc(c.ext4_umount(mount_point));
}

pub fn deviceUnregister(name: [*:0]const u8) Ext4Error!void {
    try checkRc(c.ext4_device_unregister(name));
}

// ── Directory operations ────────────────────────────────────────────

pub fn dirMk(path: [*:0]const u8) Ext4Error!void {
    try checkRc(c.ext4_dir_mk(path));
}

// ── File operations ─────────────────────────────────────────────────

pub fn fopen(f: *c.ext4_file, path: [*:0]const u8, flags: [*:0]const u8) Ext4Error!void {
    try checkRc(c.ext4_fopen(f, path, flags));
}

pub fn fwrite(f: *c.ext4_file, data: []const u8) Ext4Error!usize {
    var written: usize = 0;
    try checkRc(c.ext4_fwrite(f, data.ptr, data.len, &written));
    return written;
}

pub fn fread(f: *c.ext4_file, buf: []u8) Ext4Error!usize {
    var bytes_read: usize = 0;
    try checkRc(c.ext4_fread(f, buf.ptr, buf.len, &bytes_read));
    return bytes_read;
}

pub fn fclose(f: *c.ext4_file) Ext4Error!void {
    try checkRc(c.ext4_fclose(f));
}

pub fn fsize(f: *c.ext4_file) u64 {
    return c.ext4_fsize(f);
}

// ── Symlinks and special files ──────────────────────────────────────

pub fn symlink(target: [*:0]const u8, path: [*:0]const u8) Ext4Error!void {
    try checkRc(c.ext4_fsymlink(target, path));
}

pub fn hardlink(target: [*:0]const u8, path: [*:0]const u8) Ext4Error!void {
    try checkRc(c.ext4_flink(target, path));
}

pub fn mknod(path: [*:0]const u8, filetype: u32, dev: u32) Ext4Error!void {
    try checkRc(c.ext4_mknod(path, @intCast(filetype), @intCast(dev)));
}

// ── Metadata ────────────────────────────────────────────────────────

pub fn modeSet(path: [*:0]const u8, mode: u32) Ext4Error!void {
    try checkRc(c.ext4_mode_set(path, mode));
}

pub fn ownerSet(path: [*:0]const u8, uid: u32, gid: u32) Ext4Error!void {
    try checkRc(c.ext4_owner_set(path, uid, gid));
}

// ── High-level helpers ──────────────────────────────────────────────

/// Create a filesystem, mount it, run a callback, and unmount.
pub fn withMountedFs(
    bd: *c.ext4_blockdev,
    fs_type: FsType,
    comptime callback: fn (*c.ext4_blockdev) Ext4Error!void,
) Ext4Error!void {
    try mkfs(bd, fs_type);
    try deviceRegister(bd, "lcl");
    defer deviceUnregister("lcl") catch {};
    try mount("lcl", "/mp/");
    defer umount("/mp/") catch {};
    try recover("/mp/");
    try journalStart("/mp/");
    defer journalStop("/mp/") catch {};
    try cacheWriteBack("/mp/", true);
    defer cacheWriteBack("/mp/", false) catch {};

    try callback(bd);
}

/// Write a complete file from a byte slice.
pub fn writeFile(path: [*:0]const u8, data: []const u8) Ext4Error!void {
    var f: c.ext4_file = undefined;
    try fopen(&f, path, "wb");
    defer fclose(&f) catch {};

    var remaining = data;
    while (remaining.len > 0) {
        const written = try fwrite(&f, remaining);
        remaining = remaining[written..];
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "mkfs creates valid ext4 superblock" {
    const tmp_path = "/tmp/lcl-test-ext4.img";
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    try blockdev.init(tmp_path, 64 * 1024 * 1024);
    defer blockdev.deinit();

    try mkfs(blockdev.getDevice(), .ext3);

    // Read superblock magic at offset 0x438 (1080 bytes into the image)
    const file = try std.fs.openFileAbsolute(tmp_path, .{});
    defer file.close();
    var magic: [2]u8 = undefined;
    _ = try file.pread(&magic, 0x438);
    // ext4 superblock magic: 0xEF53 (little-endian)
    try std.testing.expectEqual(@as(u8, 0x53), magic[0]);
    try std.testing.expectEqual(@as(u8, 0xEF), magic[1]);
}

test "mkfs + mount + write file + umount" {
    const tmp_path = "/tmp/lcl-test-ext4-rw.img";
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    try blockdev.init(tmp_path, 64 * 1024 * 1024);
    defer blockdev.deinit();

    const bd = blockdev.getDevice();
    try mkfs(bd, .ext3);

    try deviceRegister(bd, "test");
    defer deviceUnregister("test") catch {};

    try mount("test", "/mp/");
    defer umount("/mp/") catch {};

    try recover("/mp/");
    try journalStart("/mp/");
    defer journalStop("/mp/") catch {};

    try cacheWriteBack("/mp/", true);
    defer cacheWriteBack("/mp/", false) catch {};

    // Create a directory and file
    try dirMk("/mp/etc");
    try writeFile("/mp/etc/hostname", "lcl-test\n");
    try modeSet("/mp/etc/hostname", 0o644);
    try ownerSet("/mp/etc/hostname", 0, 0);
}
