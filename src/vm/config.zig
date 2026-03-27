/// VM configuration — builds a VZVirtualMachineConfiguration from LclConfig.

const std = @import("std");
const objc = @import("objc");
const vz = @import("vz");
const devices = @import("devices");
const config_types = @import("config");

pub const ConfigError = error{
    ValidationFailed,
    KernelNotFound,
    RootfsNotFound,
} || devices.DeviceError;

/// Build a validated VZVirtualMachineConfiguration from user config.
/// `config_dir` is the absolute path to ~/.config/lcl/<name>/.
pub fn buildVmConfig(
    lcl: config_types.LclConfig,
    config_dir: []const u8,
    allocator: std.mem.Allocator,
) ConfigError!vz.VirtualMachineConfiguration {
    const vm_config = vz.VirtualMachineConfiguration.init();

    // CPU + Memory
    vm_config.setCPUCount(@as(objc.NSUInteger, lcl.environment.cpu));
    vm_config.setMemorySize(@as(u64, lcl.environment.memory_mb) * 1024 * 1024);

    // Platform
    const platform = vz.GenericPlatformConfiguration.init();
    vm_config.setPlatform(platform.obj);

    // Boot loader
    const kernel_path = std.fs.path.joinZ(allocator, &.{ config_dir, lcl.environment.kernel }) catch
        return error.KernelNotFound;
    const kernel_url = objc.nsURL(kernel_path);
    var boot_loader = vz.LinuxBootLoader.initWithKernelURL(kernel_url);
    boot_loader.setCommandLine(allocator.dupeZ(u8, lcl.environment.cmdline) catch
        return error.KernelNotFound);

    if (lcl.environment.initrd) |initrd| {
        const initrd_path = std.fs.path.joinZ(allocator, &.{ config_dir, initrd }) catch
            return error.KernelNotFound;
        boot_loader.setInitialRamdiskURL(objc.nsURL(initrd_path));
    }

    vm_config.setBootLoader(boot_loader.obj);

    // Serial console (stdin/stdout)
    const console = devices.createSerialConsole();
    vm_config.setSerialPorts(devices.singletonArray(console.obj));

    // Block storage (rootfs)
    const rootfs_path = std.fs.path.joinZ(allocator, &.{ config_dir, lcl.environment.rootfs }) catch
        return error.RootfsNotFound;
    const block_dev = try devices.createBlockDevice(objc.nsURL(rootfs_path));
    vm_config.setStorageDevices(devices.singletonArray(block_dev.obj));

    // Network (NAT)
    const net = devices.createNATNetwork();
    vm_config.setNetworkDevices(devices.singletonArray(net.obj));

    // Vsock
    const vsock = devices.createVsock();
    vm_config.setSocketDevices(devices.singletonArray(vsock.obj));

    // VirtioFS home mount
    if (lcl.mounts.home) {
        const home = std.posix.getenv("HOME") orelse "/Users";
        const home_z: [*:0]const u8 = allocator.dupeZ(u8, home) catch
            return error.KernelNotFound;
        const fs = devices.createVirtioFS("homefs", home_z, false);
        vm_config.setDirectorySharingDevices(devices.singletonArray(fs.obj));
    }

    // Entropy
    const entropy = devices.createEntropy();
    vm_config.setEntropyDevices(devices.singletonArray(entropy.obj));

    // Validate
    var err: ?objc.id = null;
    if (!vm_config.validateWithError(&err)) {
        if (err) |e| {
            const desc = objc.errorDescription(e);
            std.log.err("VM configuration invalid: {s}", .{std.mem.span(desc)});
        }
        return error.ValidationFailed;
    }

    return vm_config;
}
