/// Bridge host — entry point for standalone testing.
/// In production, the handler is invoked from the lcl process directly
/// via the vsock listener in lifecycle.zig.

const std = @import("std");
pub const handler = @import("handler");

pub fn main() !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.print("lcl-bridge-host: standalone mode not yet implemented\n", .{});
    try stderr.print("The bridge host runs inside the lcl process via vsock.\n", .{});
}
