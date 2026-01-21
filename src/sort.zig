const std = @import("std");

pub fn string(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

pub fn sortDirectoryEntry(_: void, lhs: std.fs.Dir.Entry, rhs: std.fs.Dir.Entry) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}
