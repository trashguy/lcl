/// Image builder orchestrator — top-level module for `lcl build`.
/// Downloads distro files, creates ext4 rootfs, populates from tarball.

const std = @import("std");
const ext4 = @import("ext4");
const config = @import("config");

pub const download = @import("download.zig");
pub const kernel = @import("kernel.zig");
pub const distro = @import("distro.zig");

pub const BuildError = error{
    UnsupportedDistro,
    DownloadFailed,
    KernelError,
    Ext4Error,
    ConfigError,
    FileError,
    OutOfMemory,
};

/// Build a complete VM image for the given environment.
pub fn buildImage(
    allocator: std.mem.Allocator,
    env_name: []const u8,
    dist: distro.Distro,
) BuildError!void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Resolve paths
    const config_dir = config.configPath(allocator, env_name) catch return error.ConfigError;
    defer allocator.free(config_dir);

    const home = std.posix.getenv("HOME") orelse return error.ConfigError;
    const cache_dir = std.fs.path.join(allocator, &.{ home, ".cache", "lcl" }) catch return error.OutOfMemory;
    defer allocator.free(cache_dir);

    // Ensure cache directory exists
    std.fs.makeDirAbsolute(cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.FileError,
    };

    stderr.print("Building {s} image for '{s}'...\n", .{ @tagName(dist), env_name }) catch {};

    // 1. Download rootfs tarball
    const rootfs_cache = std.fs.path.join(allocator, &.{ cache_dir, dist.rootfsCacheFilename() }) catch return error.OutOfMemory;
    defer allocator.free(rootfs_cache);

    stderr.writeAll("Downloading rootfs tarball...\n") catch {};
    download.downloadToCache(allocator, dist.rootfsUrl(), rootfs_cache, "rootfs") catch return error.DownloadFailed;

    // 2. Download/extract kernel and initrd
    if (dist.hasExternalKernel()) {
        // Alpine: separate kernel and initrd downloads
        if (dist.kernelUrl()) |kurl| {
            const kernel_compressed = std.fs.path.join(allocator, &.{ config_dir, "vmlinuz.compressed" }) catch return error.OutOfMemory;
            defer allocator.free(kernel_compressed);
            const kernel_path = std.fs.path.join(allocator, &.{ config_dir, "vmlinuz" }) catch return error.OutOfMemory;
            defer allocator.free(kernel_path);

            stderr.writeAll("Downloading kernel...\n") catch {};
            download.downloadToCache(allocator, kurl, kernel_compressed, "kernel") catch return error.DownloadFailed;

            if (dist.needsKernelDecompress()) {
                stderr.writeAll("Decompressing kernel...\n") catch {};
                kernel.decompressKernel(allocator, kernel_compressed, kernel_path) catch return error.KernelError;
            }
        }

        if (dist.initrdUrl()) |iurl| {
            const initrd_path = std.fs.path.join(allocator, &.{ config_dir, "initrd" }) catch return error.OutOfMemory;
            defer allocator.free(initrd_path);

            stderr.writeAll("Downloading initrd...\n") catch {};
            download.downloadToCache(allocator, iurl, initrd_path, "initrd") catch return error.DownloadFailed;
        }
    }
    // For Arch, kernel/initrd will be extracted from rootfs after population

    // 3. Create ext4 rootfs image
    const rootfs_path = std.fs.path.join(allocator, &.{ config_dir, "rootfs.raw" }) catch return error.OutOfMemory;
    defer allocator.free(rootfs_path);

    stderr.writeAll("Creating ext4 filesystem...\n") catch {};
    ext4.blockdev.init(rootfs_path, dist.imageSizeBytes()) catch return error.Ext4Error;
    defer ext4.blockdev.deinit();

    ext4.mkfs(ext4.blockdev.getDevice(), .ext3) catch return error.Ext4Error;

    // 4. Mount and populate from tarball
    ext4.deviceRegister(ext4.blockdev.getDevice(), "lcl") catch return error.Ext4Error;
    defer ext4.deviceUnregister("lcl") catch {};

    ext4.mount("lcl", "/mp/") catch return error.Ext4Error;
    defer ext4.umount("/mp/") catch {};

    ext4.recover("/mp/") catch return error.Ext4Error;
    ext4.journalStart("/mp/") catch return error.Ext4Error;
    defer ext4.journalStop("/mp/") catch {};

    ext4.cacheWriteBack("/mp/", true) catch return error.Ext4Error;
    defer ext4.cacheWriteBack("/mp/", false) catch {};

    stderr.writeAll("Populating filesystem from tarball...\n") catch {};
    ext4.populate.fromTarGz(allocator, rootfs_cache, "/mp/") catch return error.Ext4Error;

    // 5. Install LCL bridge guest binary + shell service
    stderr.writeAll("Installing bridge guest...\n") catch {};
    installGuestBinary(allocator, "/mp/") catch |err| {
        stderr.print("Warning: failed to install guest binary: {s}\n", .{@errorName(err)}) catch {};
    };

    // 6. For Arch, extract kernel + initrd from the populated rootfs
    if (!dist.hasExternalKernel()) {
        stderr.writeAll("Extracting kernel from rootfs...\n") catch {};
        extractFileFromExt4(allocator, "/mp/boot/Image", config_dir, "vmlinuz") catch |err| {
            // Also try vmlinuz-linux (some Arch versions)
            extractFileFromExt4(allocator, "/mp/boot/vmlinuz-linux", config_dir, "vmlinuz") catch {
                stderr.print("Warning: failed to extract kernel: {s}\n", .{@errorName(err)}) catch {};
            };
        };
        extractFileFromExt4(allocator, "/mp/boot/initramfs-linux.img", config_dir, "initrd") catch |err| {
            stderr.print("Warning: failed to extract initrd: {s}\n", .{@errorName(err)}) catch {};
        };
    }

    stderr.writeAll("Updating config...\n") catch {};

    // 5. Update lcl.toml cmdline
    updateCmdline(allocator, config_dir, dist.cmdline()) catch {};

    stderr.writeAll("Done!\n") catch {};
}

/// Extract a file from the mounted ext4 filesystem to the host.
fn extractFileFromExt4(allocator: std.mem.Allocator, ext4_path: [*:0]const u8, dest_dir: []const u8, dest_name: []const u8) !void {
    var f: ext4.c.ext4_file = std.mem.zeroes(ext4.c.ext4_file);
    ext4.fopen(&f, ext4_path, "rb") catch return error.Ext4Error;
    defer ext4.fclose(&f) catch {};

    const size = ext4.fsize(&f);
    if (size == 0 or size > 256 * 1024 * 1024) return error.FileError; // sanity check

    const data = allocator.alloc(u8, @intCast(size)) catch return error.OutOfMemory;
    defer allocator.free(data);

    var total: usize = 0;
    while (total < data.len) {
        const n = ext4.fread(&f, data[total..]) catch return error.Ext4Error;
        if (n == 0) break;
        total += n;
    }

    const dest_path = std.fs.path.join(allocator, &.{ dest_dir, dest_name }) catch return error.OutOfMemory;
    defer allocator.free(dest_path);

    const out_file = std.fs.createFileAbsolute(dest_path, .{}) catch return error.FileError;
    defer out_file.close();
    out_file.writeAll(data[0..total]) catch return error.FileError;
}

/// Install the lcl-bridge-guest binary and shell service into the rootfs.
fn installGuestBinary(allocator: std.mem.Allocator, mount_point: []const u8) !void {
    // Find the guest binary — look relative to the lcl executable
    const guest_binary_paths = [_][]const u8{
        "zig-out/bin/lcl-bridge-guest",
        "/usr/local/bin/lcl-bridge-guest",
    };

    var guest_data: ?[]u8 = null;
    defer if (guest_data) |d| allocator.free(d);

    for (guest_binary_paths) |path| {
        guest_data = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024) catch continue;
        break;
    }

    if (guest_data == null) return error.FileError;

    // Ensure /usr/local/bin exists
    var dir_buf: [512]u8 = undefined;
    for ([_][]const u8{ "usr", "usr/local", "usr/local/bin" }) |dir| {
        const full_dir = std.fmt.bufPrintZ(&dir_buf, "{s}{s}", .{ mount_point, dir }) catch continue;
        ext4.dirMk(full_dir) catch {};
    }

    // Write the binary
    var path_buf: [512]u8 = undefined;
    const bin_path = std.fmt.bufPrintZ(&path_buf, "{s}usr/local/bin/lcl-bridge-guest", .{mount_point}) catch return error.FileError;
    ext4.writeFile(bin_path, guest_data.?) catch return error.Ext4Error;
    ext4.modeSet(bin_path, 0o755) catch {};

    // Create symlinks for convenience commands
    const link_names = [_][]const u8{ "macos-clipboard", "macos-keychain", "macos-open", "macos-notify" };
    for (link_names) |link_name| {
        const link_path = std.fmt.bufPrintZ(&path_buf, "{s}usr/local/bin/{s}", .{ mount_point, link_name }) catch continue;
        ext4.symlink("lcl-bridge-guest", link_path) catch {};
    }

    // Write init script to start the shell service on boot
    // Works for both Alpine (OpenRC) and Arch (systemd)
    writeShellServiceInit(mount_point) catch {};
}

fn writeShellServiceInit(mount_point: []const u8) !void {
    var path_buf: [512]u8 = undefined;

    // OpenRC init script (Alpine)
    const openrc_dir = std.fmt.bufPrintZ(&path_buf, "{s}etc/init.d", .{mount_point}) catch return;
    ext4.dirMk(openrc_dir) catch {};

    const openrc_script =
        \\#!/sbin/openrc-run
        \\name="lcl-shell-service"
        \\description="LCL shell service (vsock PTY)"
        \\command="/usr/local/bin/lcl-bridge-guest"
        \\command_args="shell-service"
        \\command_background=true
        \\pidfile="/run/${RC_SVCNAME}.pid"
        \\
    ;
    const openrc_path = std.fmt.bufPrintZ(&path_buf, "{s}etc/init.d/lcl-shell", .{mount_point}) catch return;
    ext4.writeFile(openrc_path, openrc_script) catch {};
    ext4.modeSet(openrc_path, 0o755) catch {};

    // Symlink to default runlevel
    const runlevel_dir = std.fmt.bufPrintZ(&path_buf, "{s}etc/runlevels/default", .{mount_point}) catch return;
    ext4.dirMk(runlevel_dir) catch {};
    const runlevel_link = std.fmt.bufPrintZ(&path_buf, "{s}etc/runlevels/default/lcl-shell", .{mount_point}) catch return;
    ext4.symlink("/etc/init.d/lcl-shell", runlevel_link) catch {};

    // Systemd unit (Arch)
    const systemd_dir = std.fmt.bufPrintZ(&path_buf, "{s}etc/systemd/system", .{mount_point}) catch return;
    ext4.dirMk(systemd_dir) catch {};

    const systemd_unit =
        \\[Unit]
        \\Description=LCL Shell Service
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart=/usr/local/bin/lcl-bridge-guest shell-service
        \\Restart=always
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    ;
    const unit_path = std.fmt.bufPrintZ(&path_buf, "{s}etc/systemd/system/lcl-shell.service", .{mount_point}) catch return;
    ext4.writeFile(unit_path, systemd_unit) catch {};
    ext4.modeSet(unit_path, 0o644) catch {};

    // Enable the systemd service (symlink to wants)
    const wants_dir = std.fmt.bufPrintZ(&path_buf, "{s}etc/systemd/system/multi-user.target.wants", .{mount_point}) catch return;
    ext4.dirMk(wants_dir) catch {};
    const wants_link = std.fmt.bufPrintZ(&path_buf, "{s}etc/systemd/system/multi-user.target.wants/lcl-shell.service", .{mount_point}) catch return;
    ext4.symlink("/etc/systemd/system/lcl-shell.service", wants_link) catch {};
}

/// Update the cmdline in lcl.toml.
fn updateCmdline(allocator: std.mem.Allocator, config_dir: []const u8, new_cmdline: []const u8) !void {
    const toml_path = std.fs.path.join(allocator, &.{ config_dir, "lcl.toml" }) catch return;
    defer allocator.free(toml_path);

    const content = std.fs.cwd().readFileAlloc(allocator, toml_path, 1024 * 1024) catch return;
    defer allocator.free(content);

    // Simple string replacement: find cmdline = "..." and replace
    const needle = "cmdline = \"";
    if (std.mem.indexOf(u8, content, needle)) |start| {
        const value_start = start + needle.len;
        if (std.mem.indexOf(u8, content[value_start..], "\"")) |end| {
            // Build new content using concat
            const prefix = content[0..value_start];
            const suffix = content[value_start + end ..];
            const total_len = prefix.len + new_cmdline.len + suffix.len;

            const new_content = allocator.alloc(u8, total_len) catch return;
            defer allocator.free(new_content);

            @memcpy(new_content[0..prefix.len], prefix);
            @memcpy(new_content[prefix.len..][0..new_cmdline.len], new_cmdline);
            @memcpy(new_content[prefix.len + new_cmdline.len ..], suffix);

            std.fs.cwd().writeFile(.{
                .sub_path = toml_path,
                .data = new_content,
            }) catch return;
        }
    }
}
