/// VM device setup — helpers for composing VZ device configurations.

const std = @import("std");
const objc = @import("objc");
const vz = @import("vz");

pub const DeviceError = error{
    DiskImageFailed,
};

/// Serial console: stdin/stdout attached to VirtIO console port.
/// Used by the CLI (`lcl start`) where the user *wants* the kernel + systemd
/// output on their terminal.
pub fn createSerialConsole() vz.VirtioConsoleDeviceSerialPortConfiguration {
    const stdin_fh = objc.fileHandleWithDescriptor(0);
    const stdout_fh = objc.fileHandleWithDescriptor(1);
    const attachment = vz.FileHandleSerialPortAttachment.initWithFileHandles(stdin_fh, stdout_fh);

    var console = vz.VirtioConsoleDeviceSerialPortConfiguration.init();
    console.setAttachment(attachment.obj);
    return console;
}

/// Serial console redirected to a log file. Used by the GUI app where
/// stdout typically goes nowhere (Finder launch). Opens `log_path` in
/// append mode (O_CREAT|O_WRONLY|O_APPEND) so the user can `tail -f` it.
/// Stdin is wired to /dev/null — nothing in the guest reads it anyway.
/// Returns null if the log file can't be opened so the caller can fall
/// back to the stdin/stdout attachment.
pub fn createSerialConsoleToFile(log_path: [*:0]const u8) ?vz.VirtioConsoleDeviceSerialPortConfiguration {
    const O = std.posix.O;
    const log_fd = std.posix.openZ(log_path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, 0o644) catch return null;
    const null_fd = std.posix.openZ("/dev/null", .{ .ACCMODE = .RDONLY }, 0) catch {
        std.posix.close(log_fd);
        return null;
    };
    _ = O;

    const stdin_fh = objc.fileHandleWithDescriptor(@intCast(null_fd));
    const stdout_fh = objc.fileHandleWithDescriptor(@intCast(log_fd));
    const attachment = vz.FileHandleSerialPortAttachment.initWithFileHandles(stdin_fh, stdout_fh);

    var console = vz.VirtioConsoleDeviceSerialPortConfiguration.init();
    console.setAttachment(attachment.obj);
    return console;
}

/// Block storage: rootfs disk image.
pub fn createBlockDevice(rootfs_url: objc.id) DeviceError!vz.VirtioBlockDeviceConfiguration {
    var err: ?objc.id = null;
    const attachment = vz.DiskImageStorageDeviceAttachment.initWithURL(rootfs_url, false, &err) orelse {
        if (err) |e| {
            const desc = objc.errorDescription(e);
            std.log.err("Failed to create disk image attachment: {s}", .{std.mem.span(desc)});
        }
        return error.DiskImageFailed;
    };
    return vz.VirtioBlockDeviceConfiguration.initWithAttachment(attachment);
}

/// NAT networking.
pub fn createNATNetwork() vz.VirtioNetworkDeviceConfiguration {
    const nat = vz.NATNetworkDeviceAttachment.init();
    var net = vz.VirtioNetworkDeviceConfiguration.init();
    net.setAttachment(nat.obj);
    return net;
}

/// VirtioFS: mount a host directory into the guest.
pub fn createVirtioFS(tag: [*:0]const u8, host_path: [*:0]const u8, read_only: bool) vz.VirtioFileSystemDeviceConfiguration {
    const url = objc.nsURL(host_path);
    const dir = vz.SharedDirectory.initWithURL(url, read_only);
    const share = vz.SingleDirectoryShare.initWithDirectory(dir);

    var fs = vz.VirtioFileSystemDeviceConfiguration.initWithTag(tag);
    fs.setShare(share.obj);
    return fs;
}

/// Vsock for bridge communication.
pub fn createVsock() vz.VirtioSocketDeviceConfiguration {
    return vz.VirtioSocketDeviceConfiguration.init();
}

/// Entropy device (/dev/random in guest).
pub fn createEntropy() vz.VirtioEntropyDeviceConfiguration {
    return vz.VirtioEntropyDeviceConfiguration.init();
}

/// Wrap a single item into an NSArray (for setSerialPorts, etc.)
pub fn singletonArray(item: objc.id) objc.id {
    const arr = objc.nsMutableArray();
    objc.arrayAddObject(arr, item);
    return arr;
}

/// Wrap multiple items into an NSArray.
pub fn arrayOf(items: []const objc.id) objc.id {
    const arr = objc.nsMutableArray();
    for (items) |item| objc.arrayAddObject(arr, item);
    return arr;
}
