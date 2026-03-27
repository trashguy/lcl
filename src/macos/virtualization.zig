/// Virtualization.framework bindings.
/// Wraps VZ* ObjC classes via objc_msgSend. Only the subset we need.
/// Reference: Code-Hex/vz (Go) for selector mapping.

const std = @import("std");
const objc = @import("objc");

// ── VM State ─────────────────────────────────────────────────────────

pub const VmState = enum(objc.NSInteger) {
    stopped = 0,
    running = 1,
    paused = 2,
    err = 3,
    starting = 4,
    stopping = 5,
    saving = 6,
    restoring = 7,
};

// ── VZVirtualMachineConfiguration ────────────────────────────────────

pub const VirtualMachineConfiguration = struct {
    obj: objc.id,

    pub fn init() VirtualMachineConfiguration {
        const cls = objc.getClass("VZVirtualMachineConfiguration") orelse
            @panic("VZVirtualMachineConfiguration class not found");
        return .{ .obj = objc.init(objc.alloc(cls)) };
    }

    pub fn setCPUCount(self: VirtualMachineConfiguration, count: objc.NSUInteger) void {
        objc.msgSend(void, self.obj, objc.sel("setCPUCount:"), .{count});
    }

    pub fn setMemorySize(self: VirtualMachineConfiguration, bytes: u64) void {
        objc.msgSend(void, self.obj, objc.sel("setMemorySize:"), .{bytes});
    }

    pub fn setBootLoader(self: VirtualMachineConfiguration, boot_loader: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setBootLoader:"), .{boot_loader});
    }

    pub fn setPlatform(self: VirtualMachineConfiguration, platform: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setPlatform:"), .{platform});
    }

    pub fn setSerialPorts(self: VirtualMachineConfiguration, ports: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setSerialPorts:"), .{ports});
    }

    pub fn setNetworkDevices(self: VirtualMachineConfiguration, devices: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setNetworkDevices:"), .{devices});
    }

    pub fn setSocketDevices(self: VirtualMachineConfiguration, devices: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setSocketDevices:"), .{devices});
    }

    pub fn setDirectorySharingDevices(self: VirtualMachineConfiguration, devices: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setDirectorySharingDevices:"), .{devices});
    }

    pub fn setStorageDevices(self: VirtualMachineConfiguration, devices: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setStorageDevices:"), .{devices});
    }

    pub fn setEntropyDevices(self: VirtualMachineConfiguration, devices: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setEntropyDevices:"), .{devices});
    }

    pub fn setMemoryBalloonDevices(self: VirtualMachineConfiguration, devices: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setMemoryBalloonDevices:"), .{devices});
    }

    /// Returns true if valid. On failure, err_out is set to the NSError.
    pub fn validateWithError(self: VirtualMachineConfiguration, err_out: *?objc.id) bool {
        const result = objc.msgSend(objc.BOOL, self.obj, objc.sel("validateWithError:"), .{err_out});
        return result != objc.NO;
    }
};

// ── VZLinuxBootLoader ────────────────────────────────────────────────

pub const LinuxBootLoader = struct {
    obj: objc.id,

    pub fn initWithKernelURL(kernel_url: objc.id) LinuxBootLoader {
        const cls = objc.getClass("VZLinuxBootLoader") orelse
            @panic("VZLinuxBootLoader class not found");
        const raw = objc.alloc(cls);
        const obj = objc.msgSend(objc.id, raw, objc.sel("initWithKernelURL:"), .{kernel_url});
        return .{ .obj = obj };
    }

    pub fn setCommandLine(self: LinuxBootLoader, cmdline: [*:0]const u8) void {
        objc.msgSend(void, self.obj, objc.sel("setCommandLine:"), .{objc.nsString(cmdline)});
    }

    pub fn setInitialRamdiskURL(self: LinuxBootLoader, url: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setInitialRamdiskURL:"), .{url});
    }
};

// ── VZGenericPlatformConfiguration ───────────────────────────────────

pub const GenericPlatformConfiguration = struct {
    obj: objc.id,

    pub fn init() GenericPlatformConfiguration {
        const cls = objc.getClass("VZGenericPlatformConfiguration") orelse
            @panic("VZGenericPlatformConfiguration class not found");
        return .{ .obj = objc.init(objc.alloc(cls)) };
    }
};

// ── VZVirtioConsoleDeviceSerialPortConfiguration ─────────────────────

pub const VirtioConsoleDeviceSerialPortConfiguration = struct {
    obj: objc.id,

    pub fn init() VirtioConsoleDeviceSerialPortConfiguration {
        const cls = objc.getClass("VZVirtioConsoleDeviceSerialPortConfiguration") orelse
            @panic("VZVirtioConsoleDeviceSerialPortConfiguration class not found");
        return .{ .obj = objc.init(objc.alloc(cls)) };
    }

    pub fn setAttachment(self: VirtioConsoleDeviceSerialPortConfiguration, attachment: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setAttachment:"), .{attachment});
    }
};

// ── VZFileHandleSerialPortAttachment ─────────────────────────────────

pub const FileHandleSerialPortAttachment = struct {
    obj: objc.id,

    pub fn initWithFileHandles(read_fh: objc.id, write_fh: objc.id) FileHandleSerialPortAttachment {
        const cls = objc.getClass("VZFileHandleSerialPortAttachment") orelse
            @panic("VZFileHandleSerialPortAttachment class not found");
        const raw = objc.alloc(cls);
        const obj = objc.msgSend(objc.id, raw, objc.sel("initWithFileHandleForReading:fileHandleForWriting:"), .{ read_fh, write_fh });
        return .{ .obj = obj };
    }
};

// ── VZVirtioNetworkDeviceConfiguration ───────────────────────────────

pub const VirtioNetworkDeviceConfiguration = struct {
    obj: objc.id,

    pub fn init() VirtioNetworkDeviceConfiguration {
        const cls = objc.getClass("VZVirtioNetworkDeviceConfiguration") orelse
            @panic("VZVirtioNetworkDeviceConfiguration class not found");
        return .{ .obj = objc.init(objc.alloc(cls)) };
    }

    pub fn setAttachment(self: VirtioNetworkDeviceConfiguration, attachment: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setAttachment:"), .{attachment});
    }
};

// ── VZNATNetworkDeviceAttachment ─────────────────────────────────────

pub const NATNetworkDeviceAttachment = struct {
    obj: objc.id,

    pub fn init() NATNetworkDeviceAttachment {
        const cls = objc.getClass("VZNATNetworkDeviceAttachment") orelse
            @panic("VZNATNetworkDeviceAttachment class not found");
        return .{ .obj = objc.init(objc.alloc(cls)) };
    }
};

// ── VZVirtioSocketDeviceConfiguration ────────────────────────────────

pub const VirtioSocketDeviceConfiguration = struct {
    obj: objc.id,

    pub fn init() VirtioSocketDeviceConfiguration {
        const cls = objc.getClass("VZVirtioSocketDeviceConfiguration") orelse
            @panic("VZVirtioSocketDeviceConfiguration class not found");
        return .{ .obj = objc.init(objc.alloc(cls)) };
    }
};

// ── VZVirtioFileSystemDeviceConfiguration ────────────────────────────

pub const VirtioFileSystemDeviceConfiguration = struct {
    obj: objc.id,

    pub fn initWithTag(tag: [*:0]const u8) VirtioFileSystemDeviceConfiguration {
        const cls = objc.getClass("VZVirtioFileSystemDeviceConfiguration") orelse
            @panic("VZVirtioFileSystemDeviceConfiguration class not found");
        const raw = objc.alloc(cls);
        const obj = objc.msgSend(objc.id, raw, objc.sel("initWithTag:"), .{objc.nsString(tag)});
        return .{ .obj = obj };
    }

    pub fn setShare(self: VirtioFileSystemDeviceConfiguration, share: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setShare:"), .{share});
    }
};

// ── VZSharedDirectory ────────────────────────────────────────────────

pub const SharedDirectory = struct {
    obj: objc.id,

    pub fn initWithURL(url: objc.id, read_only: bool) SharedDirectory {
        const cls = objc.getClass("VZSharedDirectory") orelse
            @panic("VZSharedDirectory class not found");
        const raw = objc.alloc(cls);
        const ro: objc.BOOL = if (read_only) objc.YES else objc.NO;
        const obj = objc.msgSend(objc.id, raw, objc.sel("initWithURL:readOnly:"), .{ url, ro });
        return .{ .obj = obj };
    }
};

// ── VZSingleDirectoryShare ───────────────────────────────────────────

pub const SingleDirectoryShare = struct {
    obj: objc.id,

    pub fn initWithDirectory(dir: SharedDirectory) SingleDirectoryShare {
        const cls = objc.getClass("VZSingleDirectoryShare") orelse
            @panic("VZSingleDirectoryShare class not found");
        const raw = objc.alloc(cls);
        const obj = objc.msgSend(objc.id, raw, objc.sel("initWithDirectory:"), .{dir.obj});
        return .{ .obj = obj };
    }
};

// ── VZDiskImageStorageDeviceAttachment ───────────────────────────────

pub const DiskImageStorageDeviceAttachment = struct {
    obj: objc.id,

    /// Create a disk image attachment. Returns null on error (err_out will be set).
    pub fn initWithURL(url: objc.id, read_only: bool, err_out: *?objc.id) ?DiskImageStorageDeviceAttachment {
        const cls = objc.getClass("VZDiskImageStorageDeviceAttachment") orelse
            @panic("VZDiskImageStorageDeviceAttachment class not found");
        const raw = objc.alloc(cls);
        const ro: objc.BOOL = if (read_only) objc.YES else objc.NO;
        const result = objc.msgSend(?objc.id, raw, objc.sel("initWithURL:readOnly:error:"), .{ url, ro, err_out });
        if (result) |obj| {
            return .{ .obj = obj };
        }
        return null;
    }
};

// ── VZVirtioBlockDeviceConfiguration ─────────────────────────────────

pub const VirtioBlockDeviceConfiguration = struct {
    obj: objc.id,

    pub fn initWithAttachment(attachment: DiskImageStorageDeviceAttachment) VirtioBlockDeviceConfiguration {
        const cls = objc.getClass("VZVirtioBlockDeviceConfiguration") orelse
            @panic("VZVirtioBlockDeviceConfiguration class not found");
        const raw = objc.alloc(cls);
        const obj = objc.msgSend(objc.id, raw, objc.sel("initWithAttachment:"), .{attachment.obj});
        return .{ .obj = obj };
    }
};

// ── VZVirtioEntropyDeviceConfiguration ───────────────────────────────

pub const VirtioEntropyDeviceConfiguration = struct {
    obj: objc.id,

    pub fn init() VirtioEntropyDeviceConfiguration {
        const cls = objc.getClass("VZVirtioEntropyDeviceConfiguration") orelse
            @panic("VZVirtioEntropyDeviceConfiguration class not found");
        return .{ .obj = objc.init(objc.alloc(cls)) };
    }
};

// ── VZVirtualMachine ─────────────────────────────────────────────────

pub const VirtualMachine = struct {
    obj: objc.id,

    pub fn initWithConfiguration(config: VirtualMachineConfiguration) VirtualMachine {
        const cls = objc.getClass("VZVirtualMachine") orelse
            @panic("VZVirtualMachine class not found");
        const raw = objc.alloc(cls);
        const obj = objc.msgSend(objc.id, raw, objc.sel("initWithConfiguration:"), .{config.obj});
        return .{ .obj = obj };
    }

    pub fn startWithCompletionHandler(self: VirtualMachine, block: *const anyopaque) void {
        objc.msgSend(void, self.obj, objc.sel("startWithCompletionHandler:"), .{block});
    }

    pub fn stopWithCompletionHandler(self: VirtualMachine, block: *const anyopaque) void {
        objc.msgSend(void, self.obj, objc.sel("stopWithCompletionHandler:"), .{block});
    }

    pub fn requestStopWithError(self: VirtualMachine, err_out: *?objc.id) bool {
        const result = objc.msgSend(objc.BOOL, self.obj, objc.sel("requestStopWithError:"), .{err_out});
        return result != objc.NO;
    }

    pub fn state(self: VirtualMachine) VmState {
        const raw = objc.msgSend(objc.NSInteger, self.obj, objc.sel("state"), .{});
        return @enumFromInt(raw);
    }

    pub fn canStart(self: VirtualMachine) bool {
        return objc.msgSend(objc.BOOL, self.obj, objc.sel("canStart"), .{}) != objc.NO;
    }

    pub fn canStop(self: VirtualMachine) bool {
        return objc.msgSend(objc.BOOL, self.obj, objc.sel("canStop"), .{}) != objc.NO;
    }

    pub fn canRequestStop(self: VirtualMachine) bool {
        return objc.msgSend(objc.BOOL, self.obj, objc.sel("canRequestStop"), .{}) != objc.NO;
    }

    /// -[VZVirtualMachine socketDevices] -> NSArray<VZVirtioSocketDevice *>
    pub fn socketDevices(self: VirtualMachine) objc.id {
        return objc.msgSend(objc.id, self.obj, objc.sel("socketDevices"), .{});
    }
};

// ── VZVirtioSocketDevice (live device from running VM) ──────────────

pub const VirtioSocketDevice = struct {
    obj: objc.id,

    /// Extract the first socket device from a running VirtualMachine.
    pub fn fromVirtualMachine(vm: VirtualMachine) ?VirtioSocketDevice {
        const devices = vm.socketDevices();
        if (objc.arrayCount(devices) == 0) return null;
        return .{ .obj = objc.arrayObjectAtIndex(devices, 0) };
    }

    /// Register a listener on a vsock port.
    /// -[VZVirtioSocketDevice setSocketListener:forPort:]
    pub fn setSocketListener(self: VirtioSocketDevice, listener: VirtioSocketListener, port: u32) void {
        objc.msgSend(void, self.obj, objc.sel("setSocketListener:forPort:"), .{
            listener.obj,
            port,
        });
    }

    /// Remove listener for a port.
    /// -[VZVirtioSocketDevice removeSocketListenerForPort:]
    pub fn removeSocketListenerForPort(self: VirtioSocketDevice, port: u32) void {
        objc.msgSend(void, self.obj, objc.sel("removeSocketListenerForPort:"), .{port});
    }

    /// Connect to a port on the guest.
    /// -[VZVirtioSocketDevice connectToPort:completionHandler:]
    /// The completion handler receives (VZVirtioSocketConnection?, NSError?).
    pub fn connectToPort(self: VirtioSocketDevice, port: u32, handler: *const anyopaque) void {
        objc.msgSend(void, self.obj, objc.sel("connectToPort:completionHandler:"), .{
            port,
            handler,
        });
    }
};

// ── VZVirtioSocketListener ──────────────────────────────────────────

pub const VirtioSocketListener = struct {
    obj: objc.id,

    pub fn init() VirtioSocketListener {
        const cls = objc.getClass("VZVirtioSocketListener") orelse
            @panic("VZVirtioSocketListener class not found");
        return .{ .obj = objc.init(objc.alloc(cls)) };
    }

    pub fn setDelegate(self: VirtioSocketListener, delegate: objc.id) void {
        objc.msgSend(void, self.obj, objc.sel("setDelegate:"), .{delegate});
    }
};

// ── VZVirtioSocketConnection ────────────────────────────────────────

pub const VirtioSocketConnection = struct {
    obj: objc.id,

    /// -[VZVirtioSocketConnection fileDescriptor]
    /// macOS 26+: single fd for both reading and writing.
    pub fn fileDescriptorValue(self: VirtioSocketConnection) std.posix.fd_t {
        return objc.msgSend(i32, self.obj, objc.sel("fileDescriptor"), .{});
    }

    /// Get the raw file descriptor for reading (same fd on macOS 26+).
    pub fn readFd(self: VirtioSocketConnection) std.posix.fd_t {
        return self.fileDescriptorValue();
    }

    /// Get the raw file descriptor for writing (same fd on macOS 26+).
    pub fn writeFd(self: VirtioSocketConnection) std.posix.fd_t {
        return self.fileDescriptorValue();
    }

    /// -[VZVirtioSocketConnection close]
    pub fn close(self: VirtioSocketConnection) void {
        objc.msgSend(void, self.obj, objc.sel("close"), .{});
    }
};

// ── VZVirtioSocketListener delegate ─────────────────────────────────
//
// Creates an ObjC class at runtime that implements the
// VZVirtioSocketListenerDelegate protocol. Uses a global callback
// since there is one bridge listener per VM process.

pub const ConnectionCallback = *const fn (VirtioSocketConnection) void;

var global_connection_callback: ?ConnectionCallback = null;

/// The ObjC method implementation for
/// -[LCLSocketDelegate listener:shouldAcceptNewConnection:fromSocketDevice:]
fn socketDelegateShouldAccept(
    _: *const anyopaque, // self
    _: objc.SEL, // _cmd
    _: objc.id, // listener
    connection: objc.id, // VZVirtioSocketConnection
    _: objc.id, // socketDevice
) callconv(.c) objc.BOOL {
    if (global_connection_callback) |cb| {
        // Retain the connection so it stays alive after this callback returns
        _ = objc.retain(connection);
        cb(.{ .obj = connection });
    }
    return objc.YES;
}

var delegate_class_registered: bool = false;

/// Create a VZVirtioSocketListener with a Zig callback for incoming connections.
/// The callback is invoked on the CFRunLoop (main) thread.
pub fn createSocketListenerWithCallback(callback: ConnectionCallback) VirtioSocketListener {
    global_connection_callback = callback;

    // Register the delegate class once
    if (!delegate_class_registered) {
        const cls = objc.createClass("LCLSocketDelegate") orelse
            @panic("Failed to create LCLSocketDelegate class");

        // listener:shouldAcceptNewConnection:fromSocketDevice: -> BOOL
        // Type encoding: c = BOOL return, @ = id, : = SEL, @@@ = three id args
        _ = objc.addMethod(
            cls,
            objc.sel("listener:shouldAcceptNewConnection:fromSocketDevice:"),
            @ptrCast(&socketDelegateShouldAccept),
            "c@:@@@",
        );

        objc.registerClass(cls);
        delegate_class_registered = true;
    }

    const delegate_cls = objc.getClass("LCLSocketDelegate") orelse
        @panic("LCLSocketDelegate class not found after registration");
    const delegate = objc.init(objc.alloc(delegate_cls));

    var listener = VirtioSocketListener.init();
    listener.setDelegate(delegate);
    return listener;
}

// ── Tests ────────────────────────────────────────────────────────────

test "VZVirtualMachineConfiguration class exists" {
    try std.testing.expect(objc.getClass("VZVirtualMachineConfiguration") != null);
}

test "VZLinuxBootLoader class exists" {
    try std.testing.expect(objc.getClass("VZLinuxBootLoader") != null);
}

test "VZVirtualMachine class exists" {
    try std.testing.expect(objc.getClass("VZVirtualMachine") != null);
}

test "VZVirtioSocketDeviceConfiguration class exists" {
    try std.testing.expect(objc.getClass("VZVirtioSocketDeviceConfiguration") != null);
}

test "VZNATNetworkDeviceAttachment class exists" {
    try std.testing.expect(objc.getClass("VZNATNetworkDeviceAttachment") != null);
}

test "VZVirtioFileSystemDeviceConfiguration class exists" {
    try std.testing.expect(objc.getClass("VZVirtioFileSystemDeviceConfiguration") != null);
}

test "VZVirtioSocketListener class exists" {
    try std.testing.expect(objc.getClass("VZVirtioSocketListener") != null);
}

test "LCLSocketDelegate can be created" {
    const listener = createSocketListenerWithCallback(&struct {
        fn cb(_: VirtioSocketConnection) void {}
    }.cb);
    try std.testing.expect(listener.obj != @as(?objc.id, null));
}
