const std = @import("std");
const App = @import("app.zig");
const environment = @import("environment.zig");
const _config = &@import("./config.zig").config;

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
pub fn config(app: *App) !void {
    const dir = dir: {
        notfound: {
            break :dir (_config.configDir() catch break :notfound) orelse break :notfound;
        }
        try app.notification.writeErr(.ConfigPathNotFound);
        return;
    };
    app.directories.clearEntries();
    app.directories.dir.close();
    app.directories.dir = dir;
    app.directories.populateEntries("") catch |err| {
        switch (err) {
            error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
            else => try app.notification.writeErr(.UnknownError),
        }
    };
}

///Navigate the user to the trash dir.
pub fn trash(app: *App) !void {
    const dir = dir: {
        notfound: {
            break :dir (_config.trashDir() catch break :notfound) orelse break :notfound;
        }
        try app.notification.writeErr(.ConfigPathNotFound);
        return;
    };
    app.directories.clearEntries();
    app.directories.dir.close();
    app.directories.dir = dir;
    app.directories.populateEntries("") catch |err| {
        switch (err) {
            error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
            else => try app.notification.writeErr(.UnknownError),
        }
    };
}

///Empty the trash.
pub fn emptyTrash(app: *App) !void {
    const dir = dir: {
        notfound: {
            break :dir (_config.trashDir() catch break :notfound) orelse break :notfound;
        }
        try app.notification.writeErr(.ConfigPathNotFound);
        return;
    };

    var trash_dir = dir;
    defer trash_dir.close();
    const failed = try environment.deleteContents(trash_dir);
    if (failed > 0) try app.notification.writeErr(.FailedToDeleteSomeItems);

    app.directories.clearEntries();
    app.directories.populateEntries("") catch |err| {
        switch (err) {
            error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
            else => try app.notification.writeErr(.UnknownError),
        }
    };
}

///Change directory.
pub fn cd(app: *App, path: []const u8) !void {
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

    if (app.directories.dir.openDir(resolved_path, .{ .iterate = true })) |dir| {
        app.directories.dir.close();
        app.directories.dir = dir;

        try app.notification.writeInfo(.ChangedDir);

        app.directories.clearEntries();
        app.directories.populateEntries("") catch |err| {
            switch (err) {
                error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                else => try app.notification.writeErr(.UnknownError),
            }
        };
        app.directories.history.reset();
    } else |err| {
        switch (err) {
            error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
            error.FileNotFound => try app.notification.writeErr(.IncorrectPath),
            error.NotDir => try app.notification.writeErr(.NotADir),
            else => try app.notification.writeErr(.UnknownError),
        }
    }
}
