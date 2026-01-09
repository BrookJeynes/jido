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

dir: std.fs.Dir,
file: ?std.fs.File,

pub fn init(dir: std.fs.Dir) FileLogger {
    const file = dir.createFile(LOG_PATH, .{ .truncate = false, .read = true }) catch |err| {
        std.log.err("Failed to create/open log file: {s}", .{@errorName(err)});
        return .{ .dir = dir, .file = null };
    };

    return .{ .dir = dir, .file = file };
}

pub fn deinit(self: FileLogger) void {
    if (self.file) |file| {
        var f = file;
        f.close();
    }
}

pub fn write(self: FileLogger, msg: []const u8, level: LogLevel) !void {
    const file = if (self.file) |file| file else return error.NoLogFile;

    if (try file.tryLock(.exclusive)) {
        defer file.unlock();

        var buffer: [1024]u8 = undefined;
        var file_writer_impl = file.writer(&buffer);
        const file_writer = &file_writer_impl.interface;
        try file_writer_impl.seekTo(file.getEndPos() catch 0);

        try file_writer.print(
            "({d}) {s}: {s}\n",
            .{ std.time.timestamp(), LogLevel.toString(level), msg },
        );
        try file_writer.flush();
    }
}
