const std = @import("std");
const FileLogger = @import("file_logger.zig");

const Self = @This();

/// Seconds.
pub const notification_timeout = 3;

const Style = enum {
    err,
    info,
    warn,
};

var buf: [1024]u8 = undefined;

style: Style = Style.info,
fbs: std.io.FixedBufferStream([]u8) = std.io.fixedBufferStream(&buf),
/// How long until the notification disappears in seconds.
timer: i64 = 0,

pub fn write(self: *Self, text: []const u8, style: Style) !void {
    self.fbs.reset();
    _ = try self.fbs.write(text);
    self.timer = std.time.timestamp();
    self.style = style;
}

pub fn reset(self: *Self) void {
    self.fbs.reset();
    self.style = Style.info;
}

pub fn slice(self: *Self) []const u8 {
    return self.fbs.getWritten();
}

pub fn clearIfEnded(self: *Self) bool {
    if (std.time.timestamp() - self.timer > notification_timeout) {
        self.reset();
        return true;
    }

    return false;
}

pub fn len(self: Self) usize {
    return self.fbs.pos;
}
