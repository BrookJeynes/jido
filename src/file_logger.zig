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

alloc: std.mem.Allocator,
dir: std.fs.Dir,

pub fn init(alloc: std.mem.Allocator) !FileLogger {
    const file_logger = FileLogger{
        .alloc = alloc,
        .dir = try config.configDir() orelse return error.UnableToFindConfigDir,
    };

    if (!environment.fileExists(file_logger.dir, LOG_PATH)) {
        _ = try file_logger.dir.createFile(LOG_PATH, .{});
    }

    return file_logger;
}

pub fn deinit(self: FileLogger) void {
    var dir = self.dir;
    dir.close();
}

pub fn write(self: FileLogger, msg: []const u8, level: LogLevel) !void {
    var log = try self.dir.openFile(LOG_PATH, .{ .mode = .write_only });
    defer log.close();

    const message = try std.fmt.allocPrint(
        self.alloc,
        "({d}) {s}: {s}\n",
        .{ std.time.timestamp(), LogLevel.toString(level), msg },
    );
    defer self.alloc.free(message);

    if (try log.tryLock(std.fs.File.Lock.shared)) {
        defer log.unlock();
        try log.seekFromEnd(0);
        try log.writeAll(message);
    }
}
