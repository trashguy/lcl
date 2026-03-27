/// Terminal session — ties together a vsock connection, VT parser, and cell grid.

const std = @import("std");
const cell = @import("cell");
const parser_mod = @import("parser");

pub const Session = struct {
    allocator: std.mem.Allocator,
    grid: cell.CellGrid,
    parser: parser_mod.Parser,

    // Connection state
    shell_fd: ?std.posix.fd_t = null,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Session {
        var grid = try cell.CellGrid.init(allocator, cols, rows);
        return .{
            .allocator = allocator,
            .grid = grid,
            .parser = .{ .grid = &grid },
        };
    }

    pub fn deinit(self: *Session) void {
        if (self.shell_fd) |fd| std.posix.close(fd);
        self.grid.deinit();
    }

    /// Feed data from the PTY (shell output) into the VT parser.
    pub fn feedOutput(self: *Session, data: []const u8) void {
        self.parser.feed(data);
    }

    /// Send input data to the shell (keyboard input).
    pub fn sendInput(self: *Session, data: []const u8) !void {
        if (self.shell_fd) |fd| {
            _ = std.posix.write(fd, data) catch return;
        }
    }
};
