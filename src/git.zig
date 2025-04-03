const std = @import("std");

/// Callers owns memory returned.
pub fn getGitBranch(alloc: std.mem.Allocator, dir: std.fs.Dir) !?[]const u8 {
    var file = try dir.openFile(".git/HEAD", .{});
    defer file.close();

    var buf: [1024]u8 = undefined;
    const bytes = try file.readAll(&buf);
    if (bytes == 0) return null;

    const preamble = "ref: refs/heads/";

    return try alloc.dupe(u8, buf[preamble.len..]);
}
