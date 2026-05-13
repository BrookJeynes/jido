const std = @import("std");

/// Callers owns memory returned.
pub fn getGitBranch(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) !?[]const u8 {
    var file = try dir.openFile(io, ".git/HEAD", .{});
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var file_reader = file.reader(io, &.{});
    const bytes = file_reader.interface.readSliceShort(&buf) catch 0;
    if (bytes == 0) return null;

    const preamble = "ref: refs/heads/";
    if (bytes < preamble.len) return null;

    return try alloc.dupe(u8, buf[preamble.len..bytes]);
}
