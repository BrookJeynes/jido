const std = @import("std");
const App = @import("app.zig");
const environment = @import("environment.zig");
const user_config = &@import("./config.zig").config;

pub const CommandHistory = struct {
    const history_len = 10;

    selected: usize = 0,
    len: usize = 0,
    history: [history_len][]const u8 = undefined,

    pub fn push(self: *CommandHistory, command: []const u8) ?[]const u8 {
        var deleted: ?[]const u8 = null;
        if (self.len == history_len) {
            deleted = self.history[0];
            for (0..self.len - 1) |i| {
                self.history[i] = self.history[i + 1];
            }
        } else {
            self.len += 1;
        }

        self.history[self.len - 1] = command;
        self.selected = self.len;

        return deleted;
    }

    pub fn next(self: *CommandHistory) ?[]const u8 {
        if (self.selected == 0) return null;
        self.selected -= 1;
        return self.history[self.selected];
    }

    pub fn previous(self: *CommandHistory) ?[]const u8 {
        if (self.selected + 1 == self.len) return null;
        self.selected += 1;
        return self.history[self.selected];
    }

    pub fn resetSelected(self: *CommandHistory) void {
        self.selected = self.len;
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

///Change directory.
pub fn cd(app: *App, path: []const u8) error{OutOfMemory}!void {
    var message: ?[]const u8 = null;
    defer if (message) |msg| app.alloc.free(msg);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_path = lbl: {
        const resolved_path = if (std.mem.startsWith(u8, path, "~")) path: {
            var home_dir = (environment.getHomeDir() catch break :path path) orelse break :path path;
            defer home_dir.close();
            const relative = std.mem.trim(u8, path[1..], std.fs.path.sep_str);
            break :lbl home_dir.realpath(
                if (relative.len == 0) "." else relative,
                &path_buf,
            ) catch path;
        } else path;

        break :lbl app.directories.dir.realpath(resolved_path, &path_buf) catch path;
    };

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
