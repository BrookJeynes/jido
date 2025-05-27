const std = @import("std");
const App = @import("app.zig");
const environment = @import("environment.zig");
const user_config = &@import("./config.zig").config;

pub const CommandHistory = struct {
    const history_len = 10;

    history: [history_len][]const u8 = undefined,
    count: usize = 0,
    ///Points to the oldest entry.
    start: usize = 0,
    cursor: ?usize = null,

    pub fn deinit(self: *CommandHistory, allocator: std.mem.Allocator) void {
        for (self.history[0..self.count]) |entry| {
            allocator.free(entry);
        }
    }

    pub fn add(self: *CommandHistory, cmd: []const u8, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        const index = (self.start + self.count) % history_len;

        if (self.count < history_len) {
            self.count += 1;
        } else {
            // Overwriting the oldest entry.
            allocator.free(self.history[self.start]);
            self.start = (self.start + 1) % history_len;
        }

        self.history[index] = try allocator.dupe(u8, cmd);
        self.cursor = null;
    }

    pub fn previous(self: *CommandHistory) ?[]const u8 {
        if (self.count == 0) return null;

        if (self.cursor == null) {
            self.cursor = self.count - 1;
        } else if (self.cursor.? > 0) {
            self.cursor.? -= 1;
        }

        return self.getAtCursor();
    }

    pub fn next(self: *CommandHistory) ?[]const u8 {
        if (self.count == 0 or self.cursor == null) return null;

        if (self.cursor.? < self.count - 1) {
            self.cursor.? += 1;
            return self.getAtCursor();
        }

        self.cursor = null;
        return null;
    }

    fn getAtCursor(self: *CommandHistory) ?[]const u8 {
        if (self.cursor == null) return null;
        const index = (self.start + self.cursor.?) % history_len;
        return self.history[index];
    }
};

///Navigate the user to the config dir.
pub fn config(app: *App) error{OutOfMemory}!void {
    const dir = dir: {
        notfound: {
            break :dir (user_config.configDir() catch break :notfound) orelse break :notfound;
        }
        const message = try std.fmt.allocPrint(app.alloc, "Failed to navigate to config directory - unable to retrieve config directory.", .{});
        defer app.alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
        return;
    };

    app.directories.dir.close();
    app.directories.dir = dir;
    try app.repopulateDirectory("");
}

///Navigate the user to the trash dir.
pub fn trash(app: *App) error{OutOfMemory}!void {
    const dir = dir: {
        notfound: {
            break :dir (user_config.trashDir() catch break :notfound) orelse break :notfound;
        }
        const message = try std.fmt.allocPrint(app.alloc, "Failed to navigate to trash directory - unable to retrieve trash directory.", .{});
        defer app.alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
        return;
    };

    app.directories.dir.close();
    app.directories.dir = dir;
    try app.repopulateDirectory("");
}

///Empty the trash.
pub fn emptyTrash(app: *App) error{OutOfMemory}!void {
    var message: ?[]const u8 = null;
    defer if (message) |msg| app.alloc.free(msg);

    var dir = dir: {
        notfound: {
            break :dir (user_config.trashDir() catch break :notfound) orelse break :notfound;
        }
        message = try std.fmt.allocPrint(app.alloc, "Failed to navigate to trash directory - unable to retrieve trash directory.", .{});
        app.notification.write(message.?, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
        return;
    };
    defer dir.close();

    const failed = environment.deleteContents(dir) catch |err| lbl: {
        message = try std.fmt.allocPrint(app.alloc, "Failed to empty trash - {}.", .{err});
        app.notification.write(message.?, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
        break :lbl 0;
    };
    if (failed > 0) {
        message = try std.fmt.allocPrint(app.alloc, "Failed to empty {d} items from the trash.", .{failed});
        app.notification.write(message.?, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
    }

    try app.repopulateDirectory("");
}

pub fn resolvePath(buf: *[std.fs.max_path_bytes]u8, path: []const u8, dir: std.fs.Dir) []const u8 {
    const resolved_path = if (std.mem.startsWith(u8, path, "~")) path: {
        var home_dir = (environment.getHomeDir() catch break :path path) orelse break :path path;
        defer home_dir.close();
        const relative = std.mem.trim(u8, path[1..], std.fs.path.sep_str);
        return home_dir.realpath(
            if (relative.len == 0) "." else relative,
            buf,
        ) catch path;
    } else path;

    return dir.realpath(resolved_path, buf) catch path;
}

///Change directory.
pub fn cd(app: *App, path: []const u8) error{OutOfMemory}!void {
    var message: ?[]const u8 = null;
    defer if (message) |msg| app.alloc.free(msg);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_path = resolvePath(&path_buf, path, app.directories.dir);

    const dir = app.directories.dir.openDir(resolved_path, .{ .iterate = true }) catch |err| {
        message = switch (err) {
            error.FileNotFound => try std.fmt.allocPrint(app.alloc, "Failed to navigate to '{s}' - directory does not exist.", .{resolved_path}),
            error.NotDir => try std.fmt.allocPrint(app.alloc, "Failed to navigate to '{s}' - item is not a directory.", .{resolved_path}),
            else => try std.fmt.allocPrint(app.alloc, "Failed to read directory entries - {}.", .{err}),
        };
        app.notification.write(message.?, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
        return;
    };
    app.directories.dir.close();
    app.directories.dir = dir;

    message = try std.fmt.allocPrint(app.alloc, "Navigated to directory '{s}'.", .{resolved_path});
    app.notification.write(message.?, .info) catch {};

    try app.repopulateDirectory("");
    app.directories.history.reset();
}
