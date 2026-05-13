const std = @import("std");

pub fn string(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

pub fn sortDirectoryEntry(_: void, lhs: std.Io.Dir.Entry, rhs: std.Io.Dir.Entry) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}
