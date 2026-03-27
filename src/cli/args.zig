/// CLI argument parsing for lcl.
/// Hand-rolled subcommand dispatch — no external dependencies.

const std = @import("std");

pub const Command = enum {
    @"init",
    start,
    stop,
    status,
    config,
    build,
    shell,
    destroy,
    help,
    version,
};

pub const GlobalOptions = struct {
    command: ?Command = null,
    name: ?[]const u8 = null,
    force: bool = false,
    help: bool = false,
    rest: []const []const u8 = &.{},
};

/// Parse command-line arguments into a GlobalOptions struct.
/// `raw_args` should include the program name as the first element.
pub fn parseArgs(raw_args: []const []const u8) GlobalOptions {
    var opts = GlobalOptions{};

    if (raw_args.len < 2) {
        opts.command = .help;
        return opts;
    }

    var i: usize = 1; // skip program name
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            opts.command = .version;
            return opts;
        }
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            opts.force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) {
            i += 1;
            if (i < raw_args.len) {
                opts.name = raw_args[i];
            }
            continue;
        }

        // First non-flag arg is the command
        if (opts.command == null) {
            opts.command = std.meta.stringToEnum(Command, arg);
            if (opts.command == null) {
                // Unknown command — will be handled by caller
                opts.rest = raw_args[i..];
                return opts;
            }
            continue;
        }

        // Everything after the command is passed through
        opts.rest = raw_args[i..];
        break;
    }

    if (opts.command == null) {
        opts.command = .help;
    }

    return opts;
}

pub const version_string = "lcl v0.1.0";

pub fn printVersion(writer: anytype) !void {
    try writer.writeAll(version_string ++ "\n");
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\lcl — Linux Compatibility Layer
        \\
        \\Usage: lcl <command> [options]
        \\
        \\Commands:
        \\  init       Create a new Linux environment
        \\  start      Boot an environment
        \\  stop       Stop a running environment
        \\  status     Show environment status
        \\  config     View or edit environment config
        \\  build      Rebuild the container image
        \\  shell      Attach to a running environment
        \\  destroy    Remove an environment
        \\
        \\Options:
        \\  -n, --name <name>  Target environment name
        \\  -f, --force        Skip confirmation prompts
        \\  -h, --help         Show this help
        \\  -v, --version      Show version
        \\
    );
}

// ── Tests ────────────────────────────────────────────────────────────

test "parse no args shows help" {
    const args = [_][]const u8{"lcl"};
    const opts = parseArgs(&args);
    try std.testing.expectEqual(Command.help, opts.command.?);
}

test "parse subcommand" {
    const args = [_][]const u8{ "lcl", "init" };
    const opts = parseArgs(&args);
    try std.testing.expectEqual(Command.@"init", opts.command.?);
}

test "parse --version flag" {
    const args = [_][]const u8{ "lcl", "--version" };
    const opts = parseArgs(&args);
    try std.testing.expectEqual(Command.version, opts.command.?);
}

test "parse --name flag" {
    const args = [_][]const u8{ "lcl", "--name", "arch-dev", "start" };
    const opts = parseArgs(&args);
    try std.testing.expectEqual(Command.start, opts.command.?);
    try std.testing.expectEqualStrings("arch-dev", opts.name.?);
}

test "parse --force flag" {
    const args = [_][]const u8{ "lcl", "destroy", "--force" };
    const opts = parseArgs(&args);
    try std.testing.expectEqual(Command.destroy, opts.command.?);
    try std.testing.expect(opts.force);
}

test "unknown command" {
    const args = [_][]const u8{ "lcl", "foobar" };
    const opts = parseArgs(&args);
    try std.testing.expect(opts.command == null);
    try std.testing.expectEqual(@as(usize, 1), opts.rest.len);
}
