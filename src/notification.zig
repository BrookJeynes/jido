const std = @import("std");

const vaxis = @import("vaxis");

const Event = @import("app.zig").Event;
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

io: std.Io = undefined,
style: Style = Style.info,
/// Number of valid bytes in `buf`.
end: usize = 0,
/// How long until the notification disappears in seconds.
timer: i64 = 0,
loop: ?*vaxis.Loop(Event) = null,

fn nowSeconds(self: Self) i64 {
    const ts = std.Io.Clock.now(.real, self.io);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

pub fn write(self: *Self, text: []const u8, style: Style) !void {
    if (text.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[0..text.len], text);
    self.end = text.len;
    self.timer = self.nowSeconds();
    self.style = style;

    if (self.loop) |loop| {
        try loop.postEvent(.notification);
    }
}

pub fn reset(self: *Self) void {
    self.end = 0;
    self.style = Style.info;
}

pub fn slice(self: *Self) []const u8 {
    return buf[0..self.end];
}

pub fn clearIfEnded(self: *Self) bool {
    if (self.nowSeconds() - self.timer > notification_timeout) {
        self.reset();
        return true;
    }

    return false;
}

pub fn len(self: Self) usize {
    return self.end;
}
