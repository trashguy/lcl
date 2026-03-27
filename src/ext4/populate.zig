/// Tar-to-ext4 pipeline.
/// Streams a .tar.gz archive into a mounted lwext4 filesystem.

const std = @import("std");
const ext4 = @import("ext4.zig");

pub const PopulateError = error{
    Ext4Error,
    NotFound,
    NoSpace,
    PermissionDenied,
    IoError,
    TarError,
    DecompressError,
    OutOfMemory,
};

/// Populate a mounted ext4 filesystem from a .tar.gz archive.
/// The filesystem must already be mounted at `mount_point`.
/// `tar_gz_path` is the absolute path to the .tar.gz file on the host.
pub fn fromTarGz(allocator: std.mem.Allocator, tar_gz_path: []const u8, mount_point: []const u8) PopulateError!void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Open the .tar.gz file
    const file = std.fs.openFileAbsolute(tar_gz_path, .{}) catch return error.NotFound;
    defer file.close();

    // Chain: file → gzip decompress → tar iterate
    var file_reader_buf: [8192]u8 = undefined;
    var file_reader = file.reader(&file_reader_buf);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &decompress_buf);

    var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Use Diagnostics so unsupported entry types (hard links, device nodes)
    // don't abort the entire extraction
    var diagnostics: std.tar.Diagnostics = .{ .allocator = allocator };
    defer diagnostics.deinit();

    var iter = std.tar.Iterator.init(&decompress.reader, .{
        .file_name_buffer = &file_name_buf,
        .link_name_buffer = &link_name_buf,
        .diagnostics = &diagnostics,
    });

    var path_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    var count: usize = 0;

    while (true) {
        const entry = iter.next() catch |err| {
            stderr.print("  tar error after {d} entries: {s}\n", .{ count, @errorName(err) }) catch {};
            // Don't abort on tar errors — we may have extracted enough
            break;
        };
        if (entry == null) break;
        const e = entry.?;

        count += 1;
        if (count % 1000 == 0) {
            stderr.print("  {d} entries...\r", .{count}) catch {};
        }

        // Build full path: mount_point + "/" + entry.name
        const full_path = buildPath(&path_buf, mount_point, e.name) orelse continue;

        switch (e.kind) {
            .directory => {
                ext4.dirMk(full_path) catch {};
            },
            .file => {
                writeFileFromTar(&iter, e, full_path) catch |err| switch (err) {
                    error.NotFound => {
                        // Parent directory missing — create it and retry
                        ensureParentDir(&path_buf, mount_point, e.name);
                        writeFileFromTar(&iter, e, full_path) catch {};
                    },
                    else => {},
                };
            },
            .sym_link => {
                if (e.link_name.len > 0) {
                    var link_buf_local: [std.fs.max_path_bytes]u8 = undefined;
                    const link_target = std.fmt.bufPrintZ(
                        &link_buf_local,
                        "{s}",
                        .{e.link_name},
                    ) catch continue;
                    ext4.symlink(link_target, full_path) catch {};
                }
            },
        }
    }

    stderr.print("  {d} entries extracted\n", .{count}) catch {};

    // Second pass: handle hard links (tar type '1')
    // Zig's tar iterator doesn't support hard links, so we parse raw headers
    stderr.writeAll("  Processing hard links...\n") catch {};
    const hard_links = processHardLinks(tar_gz_path, mount_point);
    stderr.print("  {d} hard links created\n", .{hard_links}) catch {};
}

/// Second pass over the tarball to extract hard links.
/// Parses raw 512-byte tar headers looking for type flag '1'.
fn processHardLinks(tar_gz_path: []const u8, mount_point: []const u8) usize {
    const file = std.fs.openFileAbsolute(tar_gz_path, .{}) catch return 0;
    defer file.close();

    var file_reader_buf: [8192]u8 = undefined;
    var file_reader = file.reader(&file_reader_buf);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &decompress_buf);

    var count: usize = 0;
    var header_buf: [512]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes + 32]u8 = undefined;

    while (true) {
        // Read 512-byte tar header
        decompress.reader.readSliceAll(&header_buf) catch break;

        // Check for end-of-archive (two zero blocks)
        if (header_buf[0] == 0) break;

        // Parse header fields
        const type_flag = header_buf[156];
        const name = extractTarString(header_buf[0..100]);
        const linkname = extractTarString(header_buf[157..257]);
        const size = parseTarOctal(header_buf[124..136]);

        // Check for UStar prefix
        var full_name_buf: [512]u8 = undefined;
        var full_name = name;
        if (std.mem.eql(u8, header_buf[257..262], "ustar")) {
            const prefix = extractTarString(header_buf[345..500]);
            if (prefix.len > 0) {
                const n = std.fmt.bufPrint(&full_name_buf, "{s}/{s}", .{ prefix, name }) catch name;
                full_name = n;
            }
        }

        if (type_flag == '1' and linkname.len > 0) {
            // Hard link: create it
            const target = buildPath(&link_buf, mount_point, linkname) orelse {
                skipTarData(&decompress.reader, size);
                continue;
            };
            const path = buildPath(&path_buf, mount_point, full_name) orelse {
                skipTarData(&decompress.reader, size);
                continue;
            };

            // Ensure parent directory exists
            ensureParentDir(&path_buf, mount_point, full_name);
            ext4.hardlink(target, path) catch {};
            count += 1;
        }

        // Skip data blocks (rounded up to 512 bytes)
        skipTarData(&decompress.reader, size);
    }

    return count;
}

fn extractTarString(field: []const u8) []const u8 {
    // Tar strings are null-terminated within the field
    for (field, 0..) |c, i| {
        if (c == 0) return field[0..i];
    }
    return field;
}

fn parseTarOctal(field: []const u8) u64 {
    const trimmed = std.mem.trimRight(u8, std.mem.trimLeft(u8, field, " \x00"), " \x00");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u64, trimmed, 8) catch 0;
}

fn skipTarData(reader: *std.Io.Reader, size: u64) void {
    if (size == 0) return;
    // Tar data is padded to 512-byte blocks
    const blocks = (size + 511) / 512;
    const skip_bytes = blocks * 512;
    var remaining = skip_bytes;
    var discard_buf: [512]u8 = undefined;
    while (remaining > 0) {
        const to_read: usize = @intCast(@min(remaining, discard_buf.len));
        reader.readSliceAll(discard_buf[0..to_read]) catch return;
        remaining -= to_read;
    }
}

fn writeFileFromTar(iter: *std.tar.Iterator, entry: std.tar.Iterator.File, path: [*:0]const u8) ext4.Ext4Error!void {
    var f: ext4.c.ext4_file = std.mem.zeroes(ext4.c.ext4_file);
    try ext4.fopen(&f, path, "wb");
    defer ext4.fclose(&f) catch {};

    // Read file content in chunks from the tar stream
    var remaining: u64 = entry.size;
    var chunk_buf: [65536]u8 = undefined;

    while (remaining > 0) {
        const to_read: usize = @intCast(@min(remaining, chunk_buf.len));
        iter.reader.readSliceAll(chunk_buf[0..to_read]) catch return error.IoError;
        _ = try ext4.fwrite(&f, chunk_buf[0..to_read]);
        remaining -= to_read;
    }

    // Tell the iterator we consumed the file content
    iter.unread_file_bytes = 0;

    // Set permissions
    ext4.modeSet(path, entry.mode) catch {};
    ext4.ownerSet(path, 0, 0) catch {};
}

fn buildPath(buf: []u8, mount_point: []const u8, name: []const u8) ?[*:0]const u8 {
    if (name.len == 0) return null;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "./")) return null;

    const clean_name = if (std.mem.startsWith(u8, name, "./"))
        name[2..]
    else
        name;

    if (clean_name.len == 0) return null;

    const trimmed = std.mem.trimRight(u8, clean_name, "/");
    if (trimmed.len == 0) return null;

    return std.fmt.bufPrintZ(buf, "{s}{s}", .{ mount_point, trimmed }) catch null;
}

fn ensureParentDir(buf: []u8, mount_point: []const u8, name: []const u8) void {
    const clean_name = if (std.mem.startsWith(u8, name, "./")) name[2..] else name;
    var i: usize = 0;
    while (i < clean_name.len) {
        if (std.mem.indexOfScalar(u8, clean_name[i..], '/')) |slash_offset| {
            const end = i + slash_offset;
            const dir_path = std.fmt.bufPrintZ(buf, "{s}{s}", .{
                mount_point,
                clean_name[0..end],
            }) catch return;
            ext4.dirMk(dir_path) catch {};
            i = end + 1;
        } else {
            break;
        }
    }
}
