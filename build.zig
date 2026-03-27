const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Shared modules ──────────────────────────────────────────────

    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const toml_mod = b.createModule(.{
        .root_source_file = b.path("src/config/toml.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = config_mod },
        },
    });

    const objc_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/objc.zig"),
        .target = target,
        .optimize = optimize,
    });
    objc_mod.linkFramework("Foundation", .{});

    const vz_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/virtualization.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    vz_mod.linkFramework("Foundation", .{});
    vz_mod.linkFramework("Virtualization", .{});

    const devices_mod = b.createModule(.{
        .root_source_file = b.path("src/vm/devices.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
            .{ .name = "vz", .module = vz_mod },
        },
    });
    devices_mod.linkFramework("Foundation", .{});

    const vm_config_mod = b.createModule(.{
        .root_source_file = b.path("src/vm/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
            .{ .name = "vz", .module = vz_mod },
            .{ .name = "devices", .module = devices_mod },
            .{ .name = "config", .module = config_mod },
        },
    });
    vm_config_mod.linkFramework("Foundation", .{});

    // Note: lifecycle_mod depends on bridge_handler_mod, which is defined below.
    // We create it here but add the bridge_handler import after bridge_handler_mod exists.
    const lifecycle_mod = b.createModule(.{
        .root_source_file = b.path("src/vm/lifecycle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
            .{ .name = "vz", .module = vz_mod },
            .{ .name = "config", .module = config_mod },
        },
    });
    lifecycle_mod.linkFramework("Foundation", .{});
    lifecycle_mod.linkFramework("CoreFoundation", .{});

    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const security_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/security.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    security_mod.linkFramework("Foundation", .{});
    security_mod.linkFramework("Security", .{});

    const pasteboard_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/pasteboard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    pasteboard_mod.linkFramework("AppKit", .{});

    const workspace_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/workspace.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    workspace_mod.linkFramework("AppKit", .{});

    const notifications_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/notifications.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    notifications_mod.linkFramework("Foundation", .{});

    const bridge_handler_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge/host/handler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "security", .module = security_mod },
            .{ .name = "pasteboard", .module = pasteboard_mod },
            .{ .name = "workspace", .module = workspace_mod },
            .{ .name = "notifications", .module = notifications_mod },
        },
    });

    // Now that bridge_handler_mod exists, add it to lifecycle_mod
    lifecycle_mod.addImport("bridge_handler", bridge_handler_mod);

    const shell_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/shell/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    lifecycle_mod.addImport("shell_protocol", shell_protocol_mod);

    // ── lwext4 (vendored C library) + ext4 Zig wrapper ─────────────

    const lwext4_c_flags: []const []const u8 = &.{
        "-DCONFIG_USE_DEFAULT_CFG=1",
        "-DCONFIG_EXTENTS_ENABLE=0",
        "-DCONFIG_XATTR_ENABLE=0",
        "-DCONFIG_DEBUG_PRINTF=0",
        "-DCONFIG_DEBUG_ASSERT=0",
        "-DCONFIG_HAVE_OWN_ASSERT=1",
        "-DCONFIG_HAVE_OWN_OFLAGS=1",
        "-DCONFIG_BLOCK_DEV_CACHE_SIZE=16",
        "-DCONFIG_BLOCK_DEV_ENABLE_STATS=0",
    };

    const lwext4_c_files: []const []const u8 = &.{
        "ext4.c",
        "ext4_balloc.c",
        "ext4_bcache.c",
        "ext4_bitmap.c",
        "ext4_block_group.c",
        "ext4_blockdev.c",
        "ext4_crc32.c",
        "ext4_debug.c",
        "ext4_dir.c",
        "ext4_dir_idx.c",
        "ext4_fs.c",
        "ext4_hash.c",
        "ext4_ialloc.c",
        "ext4_inode.c",
        "ext4_journal.c",
        "ext4_mbr.c",
        "ext4_mkfs.c",
        "ext4_super.c",
        "ext4_trans.c",
        "ext4_xattr_stub.c",
    };

    const ext4_mod = b.createModule(.{
        .root_source_file = b.path("src/ext4/ext4.zig"),
        .target = target,
        .optimize = optimize,
    });
    ext4_mod.addCSourceFiles(.{
        .root = b.path("src/ext4/lwext4/src"),
        .files = lwext4_c_files,
        .flags = lwext4_c_flags,
    });
    ext4_mod.addIncludePath(b.path("src/ext4/lwext4/include"));
    ext4_mod.link_libc = true;
    // Pass config defines to @cImport as well
    ext4_mod.addCMacro("CONFIG_USE_DEFAULT_CFG", "1");
    ext4_mod.addCMacro("CONFIG_EXTENTS_ENABLE", "0");
    ext4_mod.addCMacro("CONFIG_XATTR_ENABLE", "0");
    ext4_mod.addCMacro("CONFIG_DEBUG_PRINTF", "0");
    ext4_mod.addCMacro("CONFIG_DEBUG_ASSERT", "0");
    ext4_mod.addCMacro("CONFIG_HAVE_OWN_ASSERT", "1");
    ext4_mod.addCMacro("CONFIG_HAVE_OWN_OFLAGS", "1");
    ext4_mod.addCMacro("CONFIG_BLOCK_DEV_CACHE_SIZE", "16");
    ext4_mod.addCMacro("CONFIG_BLOCK_DEV_ENABLE_STATS", "0");

    const image_mod = b.createModule(.{
        .root_source_file = b.path("src/image/builder.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ext4", .module = ext4_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "toml", .module = toml_mod },
        },
    });

    // ── LCL CLI (host) ─────────────────────────────────────────────

    const lcl_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
            .{ .name = "toml", .module = toml_mod },
            .{ .name = "objc", .module = objc_mod },
            .{ .name = "vz", .module = vz_mod },
            .{ .name = "devices", .module = devices_mod },
            .{ .name = "vm_config", .module = vm_config_mod },
            .{ .name = "lifecycle", .module = lifecycle_mod },
            .{ .name = "image", .module = image_mod },
        },
    });
    lcl_mod.linkFramework("Foundation", .{});
    lcl_mod.linkFramework("Virtualization", .{});
    lcl_mod.linkFramework("Security", .{});
    lcl_mod.linkFramework("CoreFoundation", .{});

    const lcl = b.addExecutable(.{
        .name = "lcl",
        .root_module = lcl_mod,
    });
    b.installArtifact(lcl);

    // ── Codesign with entitlements (runs automatically on build) ───

    // Codesign lcl after it's compiled (virtualization entitlement required)
    const codesign_lcl = b.addSystemCommand(&.{
        "codesign", "--sign", "-", "--force", "--entitlements",
    });
    codesign_lcl.addFileArg(b.path("macos/lcl.entitlements"));
    codesign_lcl.addArg("zig-out/bin/lcl");
    codesign_lcl.step.dependOn(&lcl.step);

    // Hook codesign into the install step so `zig build` always codesigns
    b.getInstallStep().dependOn(&codesign_lcl.step);

    // Keep "sign" as an alias
    const sign_step = b.step("sign", "Build, install, and codesign (same as default build)");
    sign_step.dependOn(&codesign_lcl.step);

    // ── Bridge host daemon ─────────────────────────────────────────

    const bridge_host_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge/host/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "handler", .module = bridge_handler_mod },
        },
    });

    const bridge_host = b.addExecutable(.{
        .name = "lcl-bridge-host",
        .root_module = bridge_host_mod,
    });
    b.installArtifact(bridge_host);

    // ── LCL Terminal App ──────────────────────────────────────────

    const cell_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal/cell.zig"),
        .target = target,
        .optimize = optimize,
    });

    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal/parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cell", .module = cell_mod },
        },
    });

    const input_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal/input.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app_ui_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    app_ui_mod.linkFramework("AppKit", .{});

    const window_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/window.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    window_mod.linkFramework("AppKit", .{});

    const session_mod = b.createModule(.{
        .root_source_file = b.path("src/app/session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cell", .module = cell_mod },
            .{ .name = "parser", .module = parser_mod },
        },
    });

    const coretext_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/coretext.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    coretext_mod.linkFramework("CoreText", .{});
    coretext_mod.linkFramework("CoreGraphics", .{});
    coretext_mod.linkFramework("AppKit", .{});
    coretext_mod.linkFramework("Foundation", .{});

    const terminal_view_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/terminal_view.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
            .{ .name = "coretext", .module = coretext_mod },
            .{ .name = "cell", .module = cell_mod },
            .{ .name = "input", .module = input_mod },
        },
    });
    terminal_view_mod.linkFramework("AppKit", .{});
    terminal_view_mod.linkFramework("CoreText", .{});
    terminal_view_mod.linkFramework("CoreGraphics", .{});

    const tabs_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/tabs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
            .{ .name = "window", .module = window_mod },
        },
    });
    tabs_mod.linkFramework("AppKit", .{});

    const splits_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/splits.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    splits_mod.linkFramework("AppKit", .{});

    const lcl_app_mod = b.createModule(.{
        .root_source_file = b.path("src/app/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
            .{ .name = "app_mod", .module = app_ui_mod },
            .{ .name = "window", .module = window_mod },
            .{ .name = "cell", .module = cell_mod },
            .{ .name = "parser", .module = parser_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "session", .module = session_mod },
            .{ .name = "coretext", .module = coretext_mod },
            .{ .name = "terminal_view", .module = terminal_view_mod },
            .{ .name = "tabs", .module = tabs_mod },
            .{ .name = "splits", .module = splits_mod },
            .{ .name = "vz", .module = vz_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "toml", .module = toml_mod },
            .{ .name = "shell_protocol", .module = shell_protocol_mod },
            .{ .name = "vm_config", .module = vm_config_mod },
            .{ .name = "lifecycle", .module = lifecycle_mod },
            .{ .name = "devices", .module = devices_mod },
        },
    });
    lcl_app_mod.linkFramework("AppKit", .{});
    lcl_app_mod.linkFramework("Foundation", .{});
    lcl_app_mod.linkFramework("CoreText", .{});
    lcl_app_mod.linkFramework("CoreGraphics", .{});
    lcl_app_mod.linkFramework("Virtualization", .{});
    lcl_app_mod.linkFramework("CoreFoundation", .{});
    lcl_app_mod.linkFramework("Security", .{});

    const lcl_app = b.addExecutable(.{
        .name = "lcl-app",
        .root_module = lcl_app_mod,
    });
    b.installArtifact(lcl_app);

    // Codesign lcl-app
    const codesign_app = b.addSystemCommand(&.{
        "codesign", "--sign", "-", "--force", "--entitlements",
    });
    codesign_app.addFileArg(b.path("macos/lcl.entitlements"));
    codesign_app.addArg("zig-out/bin/lcl-app");
    codesign_app.step.dependOn(&lcl_app.step);
    b.getInstallStep().dependOn(&codesign_app.step);
    sign_step.dependOn(&codesign_app.step);

    // ── Bridge guest client (cross-compile to Linux) ───────────────

    const guest_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
    });

    const protocol_guest_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge/protocol.zig"),
        .target = guest_target,
        .optimize = optimize,
    });

    const shell_protocol_guest_mod = b.createModule(.{
        .root_source_file = b.path("src/shell/protocol.zig"),
        .target = guest_target,
        .optimize = optimize,
    });

    const shell_service_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge/guest/shell_service.zig"),
        .target = guest_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "shell_protocol", .module = shell_protocol_guest_mod },
        },
    });

    const bridge_guest_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge/guest/main.zig"),
        .target = guest_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_guest_mod },
            .{ .name = "shell_service", .module = shell_service_mod },
        },
    });

    const bridge_guest = b.addExecutable(.{
        .name = "lcl-bridge-guest",
        .root_module = bridge_guest_mod,
    });
    b.installArtifact(bridge_guest);

    // ── Tests ──────────────────────────────────────────────────────

    const test_step = b.step("test", "Run tests");

    // ObjC runtime tests
    const objc_test_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/objc.zig"),
        .target = target,
        .optimize = optimize,
    });
    objc_test_mod.linkFramework("Foundation", .{});
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = objc_test_mod,
    })).step);

    // Virtualization bindings tests
    const vz_test_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/virtualization.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    vz_test_mod.linkFramework("Foundation", .{});
    vz_test_mod.linkFramework("Virtualization", .{});
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = vz_test_mod,
    })).step);

    // TOML parser tests
    const toml_test_mod = b.createModule(.{
        .root_source_file = b.path("src/config/toml.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = config_mod },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = toml_test_mod,
    })).step);

    // Config types tests
    const config_types_test_mod = b.createModule(.{
        .root_source_file = b.path("src/config/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = config_types_test_mod,
    })).step);

    // Args tests
    const args_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/args.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = args_test_mod,
    })).step);

    // Protocol tests
    const protocol_test_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = protocol_test_mod,
    })).step);

    // Security (Keychain) tests
    const security_test_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/security.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    security_test_mod.linkFramework("Foundation", .{});
    security_test_mod.linkFramework("Security", .{});
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = security_test_mod,
    })).step);

    // Notifications tests
    const notifications_test_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/notifications.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    notifications_test_mod.linkFramework("Foundation", .{});
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = notifications_test_mod,
    })).step);

    // Workspace tests
    const workspace_test_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/workspace.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    workspace_test_mod.linkFramework("AppKit", .{});
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = workspace_test_mod,
    })).step);

    // ext4 tests
    const ext4_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ext4/ext4.zig"),
        .target = target,
        .optimize = optimize,
    });
    ext4_test_mod.addCSourceFiles(.{
        .root = b.path("src/ext4/lwext4/src"),
        .files = lwext4_c_files,
        .flags = lwext4_c_flags,
    });
    ext4_test_mod.addIncludePath(b.path("src/ext4/lwext4/include"));
    ext4_test_mod.link_libc = true;
    ext4_test_mod.addCMacro("CONFIG_USE_DEFAULT_CFG", "1");
    ext4_test_mod.addCMacro("CONFIG_EXTENTS_ENABLE", "0");
    ext4_test_mod.addCMacro("CONFIG_XATTR_ENABLE", "0");
    ext4_test_mod.addCMacro("CONFIG_DEBUG_PRINTF", "0");
    ext4_test_mod.addCMacro("CONFIG_DEBUG_ASSERT", "0");
    ext4_test_mod.addCMacro("CONFIG_HAVE_OWN_ASSERT", "1");
    ext4_test_mod.addCMacro("CONFIG_HAVE_OWN_OFLAGS", "1");
    ext4_test_mod.addCMacro("CONFIG_BLOCK_DEV_CACHE_SIZE", "16");
    ext4_test_mod.addCMacro("CONFIG_BLOCK_DEV_ENABLE_STATS", "0");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = ext4_test_mod,
    })).step);

    // Shell protocol tests
    const shell_proto_test_mod = b.createModule(.{
        .root_source_file = b.path("src/shell/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = shell_proto_test_mod,
    })).step);

    // Cell grid tests
    const cell_test_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal/cell.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = cell_test_mod,
    })).step);

    // VT parser tests
    const parser_test_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal/parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cell", .module = cell_test_mod },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = parser_test_mod,
    })).step);

    // Input encoding tests
    const input_test_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = input_test_mod,
    })).step);

    // Pasteboard tests
    const pasteboard_test_mod = b.createModule(.{
        .root_source_file = b.path("src/macos/pasteboard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
        },
    });
    pasteboard_test_mod.linkFramework("AppKit", .{});
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_module = pasteboard_test_mod,
    })).step);
}
