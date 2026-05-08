/// Image builder orchestrator — top-level module for `lcl build`.
/// Downloads distro files, creates ext4 rootfs, populates from tarball.

const std = @import("std");
const ext4 = @import("ext4");
const config = @import("config");

pub const download = @import("download.zig");
pub const kernel = @import("kernel.zig");
pub const distro = @import("distro.zig");

/// Optional progress reporter. UI hosts can register a callback here to
/// surface each milestone in `buildImage` as it happens (downloading,
/// populating, installing services, etc.). Called from the same thread that
/// drives the build, so callers must marshal to the UI thread themselves.
pub var progress_callback: ?*const fn ([]const u8) void = null;

fn report(msg: []const u8) void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.print("{s}\n", .{msg}) catch {};
    if (progress_callback) |cb| cb(msg);
}

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
/// `packages` is the user's [setup].packages list; on Arch it's appended to
/// the curated baseline that lcl-firstboot installs on first boot.
pub fn buildImage(
    allocator: std.mem.Allocator,
    env_name: []const u8,
    dist: distro.Distro,
    packages: []const []const u8,
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

    var build_msg_buf: [128]u8 = undefined;
    const build_msg = std.fmt.bufPrint(&build_msg_buf, "Building {s} image for '{s}'...", .{ @tagName(dist), env_name }) catch "Building image...";
    report(build_msg);

    // 1. Download rootfs tarball
    const rootfs_cache = std.fs.path.join(allocator, &.{ cache_dir, dist.rootfsCacheFilename() }) catch return error.OutOfMemory;
    defer allocator.free(rootfs_cache);

    report("Downloading rootfs tarball...");
    download.downloadToCache(allocator, dist.rootfsUrl(), rootfs_cache, "rootfs") catch return error.DownloadFailed;

    // 2. Download/extract kernel and initrd
    if (dist.hasExternalKernel()) {
        // Alpine: separate kernel and initrd downloads
        if (dist.kernelUrl()) |kurl| {
            const kernel_compressed = std.fs.path.join(allocator, &.{ config_dir, "vmlinuz.compressed" }) catch return error.OutOfMemory;
            defer allocator.free(kernel_compressed);
            const kernel_path = std.fs.path.join(allocator, &.{ config_dir, "vmlinuz" }) catch return error.OutOfMemory;
            defer allocator.free(kernel_path);

            report("Downloading kernel...");
            download.downloadToCache(allocator, kurl, kernel_compressed, "kernel") catch return error.DownloadFailed;

            if (dist.needsKernelDecompress()) {
                report("Decompressing kernel...");
                kernel.decompressKernel(allocator, kernel_compressed, kernel_path) catch return error.KernelError;
            }
        }

        if (dist.initrdUrl()) |iurl| {
            const initrd_path = std.fs.path.join(allocator, &.{ config_dir, "initrd" }) catch return error.OutOfMemory;
            defer allocator.free(initrd_path);

            report("Downloading initrd...");
            download.downloadToCache(allocator, iurl, initrd_path, "initrd") catch return error.DownloadFailed;
        }
    }
    // For Arch, kernel/initrd will be extracted from rootfs after population

    // 3. Create ext4 rootfs image
    const rootfs_path = std.fs.path.join(allocator, &.{ config_dir, "rootfs.raw" }) catch return error.OutOfMemory;
    defer allocator.free(rootfs_path);

    report("Creating ext4 filesystem...");
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

    report("Populating filesystem from tarball...");
    ext4.populate.fromTarGz(allocator, rootfs_cache, "/mp/") catch return error.Ext4Error;

    // 5. Install LCL bridge guest binary + shell service. Failure here is
    // fatal — a rootfs without the guest binary boots but never starts the
    // shell service, leaving the app stuck at "Booting VM...".
    report("Installing bridge guest...");
    installGuestBinary(allocator, "/mp/") catch |err| {
        stderr.print("Failed to install guest binary: {s}\n", .{@errorName(err)}) catch {};
        return error.FileError;
    };

    // Arch first-boot: trust keyring + install curated package set + user packages.
    if (dist == .arch) {
        report("Installing first-boot service...");
        writeFirstbootService("/mp/", packages) catch |err| {
            stderr.print("Warning: failed to install firstboot service: {s}\n", .{@errorName(err)}) catch {};
        };
    }

    // 6. For Arch, extract kernel + initrd from the populated rootfs
    if (!dist.hasExternalKernel()) {
        report("Extracting kernel from rootfs...");
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

    report("Updating config...");

    // 5. Update lcl.toml cmdline
    updateCmdline(allocator, config_dir, dist.cmdline()) catch {};

    report("Done!");
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
    var guest_data: ?[]u8 = null;
    defer if (guest_data) |d| allocator.free(d);

    // Look adjacent to the running executable first — `lcl` and `lcl-app`
    // both ship in the same bin dir as `lcl-bridge-guest`, so this works
    // regardless of the cwd the caller was launched with.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExePath(&exe_buf)) |exe_path| {
        if (std.fs.path.dirname(exe_path)) |dir| {
            const path = std.fs.path.join(allocator, &.{ dir, "lcl-bridge-guest" }) catch null;
            if (path) |p| {
                defer allocator.free(p);
                guest_data = std.fs.cwd().readFileAlloc(allocator, p, 64 * 1024 * 1024) catch null;
            }
        }
    } else |_| {}

    if (guest_data == null) {
        // cwd-relative + system fallbacks for the CLI invoked from elsewhere.
        const fallbacks = [_][]const u8{
            "zig-out/bin/lcl-bridge-guest",
            "/usr/local/bin/lcl-bridge-guest",
        };
        for (fallbacks) |path| {
            guest_data = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024) catch continue;
            break;
        }
    }

    if (guest_data == null) return error.FileError;

    var size_msg: [96]u8 = undefined;
    if (std.fmt.bufPrint(&size_msg, "  guest binary read ({d} bytes)", .{guest_data.?.len})) |m| report(m) else |_| {}

    // Ensure /usr/local/bin exists
    var dir_buf: [512]u8 = undefined;
    for ([_][]const u8{ "usr", "usr/local", "usr/local/bin" }) |dir| {
        const full_dir = std.fmt.bufPrintZ(&dir_buf, "{s}{s}", .{ mount_point, dir }) catch continue;
        ext4.dirMk(full_dir) catch {};
    }
    report("  /usr/local/bin ready");

    // Write the binary
    var path_buf: [512]u8 = undefined;
    const bin_path = std.fmt.bufPrintZ(&path_buf, "{s}usr/local/bin/lcl-bridge-guest", .{mount_point}) catch return error.FileError;
    report("  writing lcl-bridge-guest...");
    ext4.writeFile(bin_path, guest_data.?) catch return error.Ext4Error;
    ext4.modeSet(bin_path, 0o755) catch {};
    report("  lcl-bridge-guest written");

    // Create symlinks for convenience commands
    const link_names = [_][]const u8{ "macos-clipboard", "macos-keychain", "macos-open", "macos-notify" };
    for (link_names) |link_name| {
        const link_path = std.fmt.bufPrintZ(&path_buf, "{s}usr/local/bin/{s}", .{ mount_point, link_name }) catch continue;
        ext4.symlink("lcl-bridge-guest", link_path) catch {};
    }
    report("  helper symlinks created");

    // Write init script to start the shell service on boot
    // Works for both Alpine (OpenRC) and Arch (systemd)
    writeShellServiceInit(mount_point) catch {};
    report("  shell-service init written");
    writeVsockModulesConfig(mount_point) catch {};
    report("  vsock modules-load.d written");
    writeSshAgentInit(mount_point) catch {};
    writeSshAgentEnv(mount_point) catch {};
    writeSshConfigMount(mount_point) catch {};
    writeLclUser(mount_point) catch {};
    report("  ssh-agent + user files written");
}

/// Drop a /etc/modules-load.d/lcl.conf so systemd-modules-load.service
/// modprobes the vsock stack at boot. Without this, lcl-shell.service
/// fails with `AddressFamilyNotSupported` on its socket(AF_VSOCK, ...)
/// call — the modules ship with the kernel but nothing requests them
/// implicitly on a clean Arch image.
fn writeVsockModulesConfig(mount_point: []const u8) !void {
    var path_buf: [512]u8 = undefined;

    const dir = std.fmt.bufPrintZ(&path_buf, "{s}etc/modules-load.d", .{mount_point}) catch return;
    ext4.dirMk(dir) catch {};

    const path = std.fmt.bufPrintZ(&path_buf, "{s}etc/modules-load.d/lcl.conf", .{mount_point}) catch return;
    const content =
        \\# Loaded by systemd-modules-load.service on boot. lcl-shell.service
        \\# binds AF_VSOCK; the virtio transport is what the host (Apple
        \\# Virtualization.framework) actually speaks.
        \\vsock
        \\vmw_vsock_virtio_transport
        \\
    ;
    ext4.writeFile(path, content) catch {};
    ext4.modeSet(path, 0o644) catch {};
}

/// Write the host's macOS username into /etc/lcl/user inside the rootfs,
/// after sanitizing it to satisfy shadow-utils NAME_REGEX
/// (`^[a-z_][a-z0-9_-]*\$?$`). macOS allows dots and uppercase
/// (e.g. `adam.vondersaar`) which Linux `useradd` rejects by default,
/// so we lowercase, swap `.` for `_`, and prepend `_` if the first char
/// isn't a letter.
///
/// firstboot picks this up to create a matching Linux user with passwordless
/// sudo, and shell-service uses it to drop privileges from root on connect.
fn writeLclUser(mount_point: []const u8) !void {
    const raw = std.posix.getenv("USER") orelse return;
    if (raw.len == 0 or raw.len > 32) return;

    var name_buf: [33]u8 = undefined;
    var n: usize = 0;
    for (raw) |c| {
        const out: u8 = if (c >= 'A' and c <= 'Z')
            c + 32
        else if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-')
            c
        else if (c == '.')
            '_'
        else
            return; // unsupported char — bail out, shell-service will run as root
        if (n >= name_buf.len) return;
        name_buf[n] = out;
        n += 1;
    }
    if (n == 0) return;

    // First char must be a letter or underscore.
    const first = name_buf[0];
    const first_ok = (first >= 'a' and first <= 'z') or first == '_';
    var sanitized: []const u8 = name_buf[0..n];
    if (!first_ok) {
        if (n + 1 > name_buf.len) return;
        std.mem.copyBackwards(u8, name_buf[1 .. n + 1], name_buf[0..n]);
        name_buf[0] = '_';
        sanitized = name_buf[0 .. n + 1];
    }

    var path_buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&path_buf, "{s}etc/lcl", .{mount_point}) catch return;
    ext4.dirMk(dir) catch {};

    const path = std.fmt.bufPrintZ(&path_buf, "{s}etc/lcl/user", .{mount_point}) catch return;
    ext4.writeFile(path, sanitized) catch {};
    ext4.modeSet(path, 0o644) catch {};
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
        \\After=network.target systemd-modules-load.service
        \\Wants=systemd-modules-load.service
        \\
        \\[Service]
        \\Type=simple
        \\# Belt-and-suspenders: even if /etc/modules-load.d/lcl.conf hasn't
        \\# been processed yet, force-load the vsock stack so socket(AF_VSOCK)
        \\# works. The `-` prefix means systemd ignores a non-zero exit (the
        \\# modules may already be loaded, in which case modprobe is a no-op).
        \\ExecStartPre=-/usr/bin/modprobe vsock
        \\ExecStartPre=-/usr/bin/modprobe vmw_vsock_virtio_transport
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

fn writeSshAgentInit(mount_point: []const u8) !void {
    var path_buf: [512]u8 = undefined;

    // OpenRC init script (Alpine)
    const openrc_script =
        \\#!/sbin/openrc-run
        \\name="lcl-ssh-agent"
        \\description="LCL SSH agent forwarder (vsock 5002 -> /run/lcl/ssh-agent.sock)"
        \\command="/usr/local/bin/lcl-bridge-guest"
        \\command_args="ssh-agent"
        \\command_background=true
        \\pidfile="/run/${RC_SVCNAME}.pid"
        \\
    ;
    const openrc_path = std.fmt.bufPrintZ(&path_buf, "{s}etc/init.d/lcl-ssh-agent", .{mount_point}) catch return;
    ext4.writeFile(openrc_path, openrc_script) catch {};
    ext4.modeSet(openrc_path, 0o755) catch {};

    const runlevel_link = std.fmt.bufPrintZ(&path_buf, "{s}etc/runlevels/default/lcl-ssh-agent", .{mount_point}) catch return;
    ext4.symlink("/etc/init.d/lcl-ssh-agent", runlevel_link) catch {};

    // Systemd unit (Arch)
    const systemd_unit =
        \\[Unit]
        \\Description=LCL SSH Agent Forwarder
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart=/usr/local/bin/lcl-bridge-guest ssh-agent
        \\Restart=always
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    ;
    const unit_path = std.fmt.bufPrintZ(&path_buf, "{s}etc/systemd/system/lcl-ssh-agent.service", .{mount_point}) catch return;
    ext4.writeFile(unit_path, systemd_unit) catch {};
    ext4.modeSet(unit_path, 0o644) catch {};

    const wants_link = std.fmt.bufPrintZ(&path_buf, "{s}etc/systemd/system/multi-user.target.wants/lcl-ssh-agent.service", .{mount_point}) catch return;
    ext4.symlink("/etc/systemd/system/lcl-ssh-agent.service", wants_link) catch {};
}

fn writeSshConfigMount(mount_point: []const u8) !void {
    var path_buf: [512]u8 = undefined;

    // Make sure /root/.ssh exists as a mount point. If the dir already
    // exists ext4.dirMk silently no-ops.
    const root_dir = std.fmt.bufPrintZ(&path_buf, "{s}root", .{mount_point}) catch return;
    ext4.dirMk(root_dir) catch {};
    const ssh_dir = std.fmt.bufPrintZ(&path_buf, "{s}root/.ssh", .{mount_point}) catch return;
    ext4.dirMk(ssh_dir) catch {};
    ext4.modeSet(ssh_dir, 0o700) catch {};

    // OpenRC init script (Alpine) — mount before lcl-shell starts.
    const openrc_script =
        \\#!/sbin/openrc-run
        \\name="lcl-ssh-mount"
        \\description="Mount host ~/.ssh via virtiofs"
        \\depend() { before lcl-shell; }
        \\start() {
        \\    mkdir -p /root/.ssh
        \\    mount -t virtiofs ssh-config /root/.ssh -o ro 2>/dev/null
        \\}
        \\stop() { umount /root/.ssh 2>/dev/null; }
        \\
    ;
    const openrc_path = std.fmt.bufPrintZ(&path_buf, "{s}etc/init.d/lcl-ssh-mount", .{mount_point}) catch return;
    ext4.writeFile(openrc_path, openrc_script) catch {};
    ext4.modeSet(openrc_path, 0o755) catch {};

    const runlevel_link = std.fmt.bufPrintZ(&path_buf, "{s}etc/runlevels/default/lcl-ssh-mount", .{mount_point}) catch return;
    ext4.symlink("/etc/init.d/lcl-ssh-mount", runlevel_link) catch {};

    // Systemd unit (Arch) — oneshot mount, runs before multi-user.target.
    const systemd_unit =
        \\[Unit]
        \\Description=Mount host ~/.ssh via virtiofs
        \\Before=lcl-shell.service lcl-ssh-agent.service
        \\
        \\[Service]
        \\Type=oneshot
        \\RemainAfterExit=yes
        \\ExecStartPre=/bin/mkdir -p /root/.ssh
        \\ExecStart=/bin/mount -t virtiofs ssh-config /root/.ssh -o ro
        \\ExecStop=/bin/umount /root/.ssh
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    ;
    const unit_path = std.fmt.bufPrintZ(&path_buf, "{s}etc/systemd/system/lcl-ssh-mount.service", .{mount_point}) catch return;
    ext4.writeFile(unit_path, systemd_unit) catch {};
    ext4.modeSet(unit_path, 0o644) catch {};

    const wants_link = std.fmt.bufPrintZ(&path_buf, "{s}etc/systemd/system/multi-user.target.wants/lcl-ssh-mount.service", .{mount_point}) catch return;
    ext4.symlink("/etc/systemd/system/lcl-ssh-mount.service", wants_link) catch {};
}

fn writeSshAgentEnv(mount_point: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const profile_dir = std.fmt.bufPrintZ(&path_buf, "{s}etc/profile.d", .{mount_point}) catch return;
    ext4.dirMk(profile_dir) catch {};

    const env_script =
        \\# Auto-generated by LCL image builder.
        \\# Routes guest SSH agent requests to the macOS host's ssh-agent.
        \\export SSH_AUTH_SOCK=/run/lcl/ssh-agent.sock
        \\
    ;
    const env_path = std.fmt.bufPrintZ(&path_buf, "{s}etc/profile.d/lcl.sh", .{mount_point}) catch return;
    ext4.writeFile(env_path, env_script) catch {};
    ext4.modeSet(env_path, 0o644) catch {};
}

/// Curated package set installed on first boot for Arch VMs. Picked to give
/// new VMs the things you'd expect from a usable dev shell — compiler chain,
/// editors, ssh, manpages, htop/tmux, zsh (matches the default shell).
const firstboot_baseline = [_][]const u8{
    "base-devel",
    "git",
    "vim",
    "sudo",
    "openssh",
    "man-db",
    "man-pages",
    "which",
    "less",
    "htop",
    "tmux",
    "zsh",
    "curl",
    "wget",
};

const firstboot_script =
    \\#!/bin/bash
    \\# Auto-generated by LCL image builder. Runs once on first boot to
    \\# trust the Arch Linux ARM keyring, install a baseline package set,
    \\# and create the per-user account that mirrors the macOS user.
    \\#
    \\# Output flows to the systemd journal AND /dev/console (the unit sets
    \\# StandardOutput=journal+console) so progress is visible in the host's
    \\# console log — no in-script `exec` redirect needed.
    \\set -u
    \\set -x
    \\
    \\mkdir -p /var/lib/lcl
    \\
    \\echo "[lcl-firstboot] $(date) starting"
    \\
    \\# Wait up to 60s for network reachability before touching pacman.
    \\for i in $(seq 1 30); do
    \\    if getent hosts mirror.archlinuxarm.org >/dev/null 2>&1; then break; fi
    \\    sleep 2
    \\done
    \\
    \\pacman-key --init
    \\pacman-key --populate archlinuxarm
    \\
    \\pacman -Syu --noconfirm || true
    \\
    \\PACKAGES=()
    \\if [ -f /etc/lcl/firstboot-packages ]; then
    \\    while IFS= read -r line; do
    \\        [ -n "$line" ] && PACKAGES+=("$line")
    \\    done < /etc/lcl/firstboot-packages
    \\fi
    \\
    \\if [ ${#PACKAGES[@]} -gt 0 ]; then
    \\    pacman -S --noconfirm --needed "${PACKAGES[@]}" || true
    \\fi
    \\
    \\# Create the per-user account that mirrors the macOS user, with
    \\# passwordless sudo via a drop-in file (avoids editing /etc/sudoers).
    \\if [ -f /etc/lcl/user ]; then
    \\    LCL_USERNAME=$(tr -d '[:space:]' < /etc/lcl/user)
    \\    if [ -n "$LCL_USERNAME" ]; then
    \\        if ! id "$LCL_USERNAME" >/dev/null 2>&1; then
    \\            useradd -m -G wheel -s /bin/bash "$LCL_USERNAME" || true
    \\        fi
    \\        mkdir -p /etc/sudoers.d
    \\        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$LCL_USERNAME" > /etc/sudoers.d/lcl-user
    \\        chmod 0440 /etc/sudoers.d/lcl-user
    \\
    \\        # Install yay (AUR helper). yay-bin ships an aarch64 binary,
    \\        # so makepkg has nothing to compile — it just installs the
    \\        # prebuilt artifact. Must run as the unprivileged user; -E
    \\        # preserves $HOME so makepkg can use ~/.cache/yay.
    \\        if ! command -v yay >/dev/null 2>&1; then
    \\            su - "$LCL_USERNAME" -c '
    \\                set -e
    \\                tmp=$(mktemp -d)
    \\                trap "rm -rf $tmp" EXIT
    \\                cd "$tmp"
    \\                git clone --depth=1 https://aur.archlinux.org/yay-bin.git
    \\                cd yay-bin
    \\                makepkg -si --noconfirm
    \\            ' || echo "[lcl-firstboot] yay install failed, continuing"
    \\        fi
    \\    fi
    \\fi
    \\
    \\systemctl disable lcl-firstboot.service || true
    \\touch /var/lib/lcl/firstboot-done
    \\echo "[lcl-firstboot] $(date) done"
    \\
;

const firstboot_unit =
    \\[Unit]
    \\Description=LCL first-boot package install
    \\After=network-online.target
    \\Wants=network-online.target
    \\Before=lcl-shell.service
    \\ConditionPathExists=!/var/lib/lcl/firstboot-done
    \\
    \\[Service]
    \\Type=oneshot
    \\ExecStart=/usr/local/bin/lcl-firstboot
    \\RemainAfterExit=yes
    \\TimeoutStartSec=900
    \\StandardOutput=journal+console
    \\StandardError=journal+console
    \\
    \\[Install]
    \\WantedBy=multi-user.target
    \\
;

fn writeFirstbootService(mount_point: []const u8, user_packages: []const []const u8) !void {
    var path_buf: [512]u8 = undefined;

    // /etc/lcl/firstboot-packages — one package per line: baseline + user list.
    const etc_lcl = std.fmt.bufPrintZ(&path_buf, "{s}etc/lcl", .{mount_point}) catch return;
    ext4.dirMk(etc_lcl) catch {};

    // Build the package list as a single buffer. 8 KiB is plenty for any
    // sane setup; if someone exceeds it we just drop the overflow rather
    // than fail the whole build.
    var pkg_buf: [8192]u8 = undefined;
    var pkg_len: usize = 0;
    inline for (firstboot_baseline) |p| {
        if (pkg_len + p.len + 1 < pkg_buf.len) {
            @memcpy(pkg_buf[pkg_len..][0..p.len], p);
            pkg_len += p.len;
            pkg_buf[pkg_len] = '\n';
            pkg_len += 1;
        }
    }
    for (user_packages) |p| {
        if (pkg_len + p.len + 1 < pkg_buf.len) {
            @memcpy(pkg_buf[pkg_len..][0..p.len], p);
            pkg_len += p.len;
            pkg_buf[pkg_len] = '\n';
            pkg_len += 1;
        }
    }

    const pkg_path = std.fmt.bufPrintZ(&path_buf, "{s}etc/lcl/firstboot-packages", .{mount_point}) catch return;
    ext4.writeFile(pkg_path, pkg_buf[0..pkg_len]) catch {};
    ext4.modeSet(pkg_path, 0o644) catch {};

    // /usr/local/bin/lcl-firstboot
    const script_path = std.fmt.bufPrintZ(&path_buf, "{s}usr/local/bin/lcl-firstboot", .{mount_point}) catch return;
    ext4.writeFile(script_path, firstboot_script) catch {};
    ext4.modeSet(script_path, 0o755) catch {};

    // /etc/systemd/system/lcl-firstboot.service
    const unit_path = std.fmt.bufPrintZ(&path_buf, "{s}etc/systemd/system/lcl-firstboot.service", .{mount_point}) catch return;
    ext4.writeFile(unit_path, firstboot_unit) catch {};
    ext4.modeSet(unit_path, 0o644) catch {};

    // Enable: symlink into multi-user.target.wants
    const wants_link = std.fmt.bufPrintZ(&path_buf, "{s}etc/systemd/system/multi-user.target.wants/lcl-firstboot.service", .{mount_point}) catch return;
    ext4.symlink("/etc/systemd/system/lcl-firstboot.service", wants_link) catch {};
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
