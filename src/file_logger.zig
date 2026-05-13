const std = @import("std");

const environment = @import("environment.zig");

const config = &@import("./config.zig").config;

pub const LOG_PATH = "log.txt";

const LogLevel = enum {
    err,
    info,
    warn,

    pub fn toString(level: LogLevel) []const u8 {
        return switch (level) {
            .err => "ERROR",
            .info => "INFO",
            .warn => "WARN",
        };
    }
};

const FileLogger = @This();

io: std.Io,
dir: std.Io.Dir,
file: ?std.Io.File,

pub fn init(io: std.Io, dir: std.Io.Dir) FileLogger {
    const file = dir.createFile(io, LOG_PATH, .{ .truncate = false, .read = true }) catch |err| {
        std.log.err("Failed to create/open log file: {s}", .{@errorName(err)});
        return .{ .io = io, .dir = dir, .file = null };
    };

    return .{ .io = io, .dir = dir, .file = file };
}

pub fn deinit(self: FileLogger) void {
    if (self.file) |file| {
        file.close(self.io);
    }
}

pub fn write(self: FileLogger, msg: []const u8, level: LogLevel) !void {
    const file = if (self.file) |file| file else return error.NoLogFile;

    if (try file.tryLock(self.io, .exclusive)) {
        defer file.unlock(self.io);

        var buffer: [1024]u8 = undefined;
        var file_writer_impl = file.writer(self.io, &buffer);
        const file_writer = &file_writer_impl.interface;

        const end = if (file.stat(self.io)) |s| s.size else |_| 0;
        try file_writer_impl.seekTo(end);

        const now: i64 = @intCast(@divTrunc(std.Io.Clock.now(.real, self.io).nanoseconds, std.time.ns_per_s));
        try file_writer.print(
            "({d}) {s}: {s}\n",
            .{ now, LogLevel.toString(level), msg },
        );
        try file_writer.flush();
    }
}
