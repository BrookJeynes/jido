const std = @import("std");

pub fn getCleanName(entry: std.Io.Dir.Entry) []const u8 {
    if (entry.kind == .directory and entry.name.len > 0 and entry.name[entry.name.len - 1] == '/') {
        return entry.name[0 .. entry.name.len - 1];
    }
    return entry.name;
}
