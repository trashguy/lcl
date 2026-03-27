/// HTTP download module with caching and progress reporting.
/// Uses std.http.Client — no curl dependency.

const std = @import("std");

pub const DownloadError = error{
    HttpError,
    FileError,
    OutOfMemory,
};

/// Download a URL to a local cache path.
/// Skips download if the file already exists.
/// Reports progress to stderr.
pub fn downloadToCache(allocator: std.mem.Allocator, url: []const u8, cache_path: []const u8, label: []const u8) DownloadError!void {
    // Skip if already cached
    if (std.fs.accessAbsolute(cache_path, .{})) |_| {
        return;
    } else |_| {}

    // Ensure parent directory exists
    if (std.fs.path.dirname(cache_path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.FileError,
        };
    }

    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.print("  {s}: downloading...\n", .{label}) catch {};

    // Write to .tmp first, rename on success
    const tmp_path = allocator.alloc(u8, cache_path.len + 4) catch return error.OutOfMemory;
    defer allocator.free(tmp_path);
    @memcpy(tmp_path[0..cache_path.len], cache_path);
    @memcpy(tmp_path[cache_path.len..], ".tmp");

    const out_file = std.fs.createFileAbsolute(tmp_path, .{}) catch return error.FileError;
    errdefer {
        out_file.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
    }

    // Use fetch with a file writer
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var file_writer_buf: [65536]u8 = undefined;
    var file_writer = out_file.writer(&file_writer_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &file_writer.interface,
    }) catch {
        out_file.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return error.HttpError;
    };

    file_writer.interface.flush() catch {};
    out_file.close();

    if (result.status != .ok) {
        stderr.print("  {s}: HTTP {d}\n", .{ label, @intFromEnum(result.status) }) catch {};
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return error.HttpError;
    }

    stderr.print("  {s}: done\n", .{label}) catch {};

    // Rename .tmp to final path
    std.fs.renameAbsolute(tmp_path, cache_path) catch return error.FileError;
}
