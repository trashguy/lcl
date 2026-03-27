/// Distro definitions — mirror URLs, image sizes, kernel cmdlines.

pub const Distro = enum {
    alpine,
    arch,

    pub fn imageSizeBytes(self: Distro) u64 {
        return switch (self) {
            .alpine => 512 * 1024 * 1024,
            .arch => 4096 * 1024 * 1024,
        };
    }

    pub fn cmdline(self: Distro) []const u8 {
        return switch (self) {
            .alpine => "console=hvc0 root=/dev/vda rw",
            .arch => "console=hvc0 root=/dev/vda rw fsck.mode=skip",
        };
    }

    pub fn needsKernelDecompress(self: Distro) bool {
        return switch (self) {
            .alpine => true,
            .arch => false,
        };
    }

    /// Whether kernel/initrd are separate downloads (true) or inside the rootfs tarball (false).
    pub fn hasExternalKernel(self: Distro) bool {
        return switch (self) {
            .alpine => true,
            .arch => false,
        };
    }

    pub fn rootfsUrl(self: Distro) []const u8 {
        return switch (self) {
            .alpine => "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.3-aarch64.tar.gz",
            .arch => "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz",
        };
    }

    pub fn kernelUrl(self: Distro) ?[]const u8 {
        return switch (self) {
            .alpine => "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot/vmlinuz-lts",
            .arch => null,
        };
    }

    pub fn initrdUrl(self: Distro) ?[]const u8 {
        return switch (self) {
            .alpine => "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot/initramfs-lts",
            .arch => null,
        };
    }

    /// Cache filename for the rootfs tarball.
    pub fn rootfsCacheFilename(self: Distro) []const u8 {
        return switch (self) {
            .alpine => "alpine-minirootfs-3.21.3-aarch64.tar.gz",
            .arch => "ArchLinuxARM-aarch64-latest.tar.gz",
        };
    }

    /// Parse a base distro string (from lcl.toml) into a Distro.
    pub fn fromBase(base: []const u8) ?Distro {
        if (containsIgnoreCase(base, "alpine")) return .alpine;
        if (containsIgnoreCase(base, "arch")) return .arch;
        return null;
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            const a = if (haystack[i + j] >= 'A' and haystack[i + j] <= 'Z') haystack[i + j] + 32 else haystack[i + j];
            const b = if (needle[j] >= 'A' and needle[j] <= 'Z') needle[j] + 32 else needle[j];
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
