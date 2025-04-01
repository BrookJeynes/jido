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
    var file: ?std.fs.File = null;
    if (!environment.fileExists(dir, LOG_PATH)) {
        file = dir.createFile(LOG_PATH, .{}) catch lbl: {
            std.log.err("Failed to create log file.", .{});
            break :lbl null;
        };
    } else {
        file = dir.openFile(LOG_PATH, .{ .mode = .write_only }) catch lbl: {
            std.log.err("Failed to open log file.", .{});
            break :lbl null;
        };
    }

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
    if (try file.tryLock(std.fs.File.Lock.shared)) {
        defer file.unlock();
        try file.seekFromEnd(0);

        try file.writer().print(
            "({d}) {s}: {s}\n",
            .{ std.time.timestamp(), LogLevel.toString(level), msg },
        );
    }
}
