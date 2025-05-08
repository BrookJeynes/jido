const std = @import("std");
const App = @import("./app.zig");
const config = &@import("./config.zig").config;
const zuid = @import("zuid");
const environment = @import("./environment.zig");
const vaxis = @import("vaxis");

pub fn delete(app: *App) error{OutOfMemory}!void {
    var message: ?[]const u8 = null;
    defer if (message) |msg| app.alloc.free(msg);

    const entry = (app.directories.getSelected() catch {
        app.notification.write("Can not to delete item - no item selected.", .warn) catch {};
        return;
    }) orelse return;

    var prev_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prev_path = app.directories.dir.realpath(entry.name, &prev_path_buf) catch {
        message = try std.fmt.allocPrint(app.alloc, "Failed to delete '{s}' - unable to retrieve absolute path.", .{entry.name});
        app.notification.write(message.?, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
        return;
    };
    const prev_path_alloc = try app.alloc.dupe(u8, prev_path);

    var trash_dir = dir: {
        notfound: {
            break :dir (config.trashDir() catch break :notfound) orelse break :notfound;
        }
        app.alloc.free(prev_path_alloc);
        message = try std.fmt.allocPrint(app.alloc, "Failed to delete '{s}' - unable to retrieve trash directory.", .{entry.name});
        app.notification.write(message.?, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
        return;
    };
    defer trash_dir.close();

    var trash_dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const trash_dir_path = trash_dir.realpath(".", &trash_dir_path_buf) catch {
        message = try std.fmt.allocPrint(app.alloc, "Failed to delete '{s}' - unable to retrieve absolute path for trash directory.", .{entry.name});
        app.notification.write(message.?, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
        return;
    };

    if (std.mem.eql(u8, prev_path_alloc, trash_dir_path)) {
        app.notification.write("Can not delete trash directory.", .warn) catch {};
        app.alloc.free(prev_path_alloc);
        return;
    }

    const tmp_path = try std.fmt.allocPrint(app.alloc, "{s}/{s}-{s}", .{ trash_dir_path, entry.name, zuid.new.v4() });
    if (app.directories.dir.rename(entry.name, tmp_path)) {
        if (app.actions.push(.{
            .delete = .{ .prev_path = prev_path_alloc, .new_path = tmp_path },
        })) |prev_elem| {
            app.alloc.free(prev_elem.delete.prev_path);
            app.alloc.free(prev_elem.delete.new_path);
        }
        message = try std.fmt.allocPrint(app.alloc, "Deleted '{s}'.", .{entry.name});
        app.notification.write(message.?, .info) catch {};

        app.directories.removeSelected();
    } else |err| {
        app.alloc.free(prev_path_alloc);
        app.alloc.free(tmp_path);

        message = try std.fmt.allocPrint(app.alloc, "Failed to delete '{s}' - {}.", .{ entry.name, err });
        app.notification.write(message.?, .err) catch {};
    }
}

pub fn rename(app: *App) error{OutOfMemory}!void {
    var message: ?[]const u8 = null;
    defer if (message) |msg| app.alloc.free(msg);

    const entry = (app.directories.getSelected() catch {
        app.notification.write("Can not to rename item - no item selected.", .warn) catch {};
        return;
    }) orelse return;

    var dir_prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_prefix = app.directories.dir.realpath(".", &dir_prefix_buf) catch {
        message = try std.fmt.allocPrint(app.alloc, "Failed to rename '{s}' - unable to retrieve absolute path.", .{entry.name});
        app.notification.write(message.?, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
        return;
    };

    const new_path = app.inputToSlice();

    if (environment.fileExists(app.directories.dir, new_path)) {
        message = try std.fmt.allocPrint(app.alloc, "Can not rename file - '{s}' already exists.", .{new_path});
        app.notification.write(message.?, .warn) catch {};
    } else {
        app.directories.dir.rename(entry.name, new_path) catch |err| {
            message = try std.fmt.allocPrint(app.alloc, "Failed to rename '{s}' - {}.", .{ new_path, err });
            app.notification.write(message.?, .err) catch {};
            if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
            return;
        };

        if (app.actions.push(.{
            .rename = .{
                .prev_path = try std.fs.path.join(app.alloc, &.{ dir_prefix, entry.name }),
                .new_path = try std.fs.path.join(app.alloc, &.{ dir_prefix, new_path }),
            },
        })) |prev_elem| {
            app.alloc.free(prev_elem.rename.prev_path);
            app.alloc.free(prev_elem.rename.new_path);
        }

        try app.repopulateDirectory("");
        app.text_input.clearAndFree();

        message = try std.fmt.allocPrint(app.alloc, "Renamed '{s}' to '{s}'.", .{ entry.name, new_path });
        app.notification.write(message.?, .info) catch {};
    }

    app.text_input.clearAndFree();
}

pub fn forceDelete(app: *App) error{OutOfMemory}!void {
    const entry = (app.directories.getSelected() catch {
        app.notification.write("Can not force delete item - no item selected.", .warn) catch {};
        return;
    }) orelse return;

    app.directories.dir.deleteTree(entry.name) catch |err| {
        const error_message = try std.fmt.allocPrint(app.alloc, "Failed to force delete '{s}' - {}.", .{ entry.name, err });
        app.notification.write(error_message, .err) catch {};
        return;
    };

    app.directories.removeSelected();
}

pub fn toggleHiddenFiles(app: *App) error{OutOfMemory}!void {
    config.show_hidden = !config.show_hidden;

    const prev_selected_name: []const u8, const prev_selected_err: bool = lbl: {
        const selected = app.directories.getSelected() catch break :lbl .{ "", true };
        if (selected == null) break :lbl .{ "", true };

        break :lbl .{ try app.alloc.dupe(u8, selected.?.name), false };
    };
    defer if (!prev_selected_err) app.alloc.free(prev_selected_name);

    try app.repopulateDirectory("");
    app.text_input.clearAndFree();

    for (app.directories.entries.all()) |entry| {
        if (std.mem.eql(u8, entry.name, prev_selected_name)) return;
        app.directories.entries.selected += 1;
    }

    // If it didn't find entry, reset selected.
    app.directories.entries.selected = 0;
}

pub fn yank(app: *App) error{OutOfMemory}!void {
    var message: ?[]const u8 = null;
    defer if (message) |msg| app.alloc.free(msg);

    if (app.yanked) |yanked| {
        app.alloc.free(yanked.dir);
        app.alloc.free(yanked.entry.name);
    }

    app.yanked = lbl: {
        const entry = (app.directories.getSelected() catch {
            app.notification.write("Can not yank item - no item selected.", .warn) catch {};
            break :lbl null;
        }) orelse break :lbl null;

        switch (entry.kind) {
            .file, .directory, .sym_link => {
                break :lbl .{
                    .dir = try app.alloc.dupe(u8, app.directories.fullPath(".") catch {
                        message = try std.fmt.allocPrint(
                            app.alloc,
                            "Failed to yank '{s}' - unable to retrieve directory path.",
                            .{entry.name},
                        );
                        app.notification.write(message.?, .err) catch {};
                        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                        break :lbl null;
                    }),
                    .entry = .{
                        .kind = entry.kind,
                        .name = try app.alloc.dupe(u8, entry.name),
                    },
                };
            },
            else => {
                message = try std.fmt.allocPrint(app.alloc, "Can not yank '{s}' - unsupported file type '{s}'.", .{ entry.name, @tagName(entry.kind) });
                app.notification.write(message.?, .warn) catch {};
                break :lbl null;
            },
        }
    };

    if (app.yanked) |y| {
        message = try std.fmt.allocPrint(app.alloc, "Yanked '{s}'.", .{y.entry.name});
        app.notification.write(message.?, .info) catch {};
    }
}

pub fn paste(app: *App) error{ OutOfMemory, NoSpaceLeft }!void {
    var message: ?[]const u8 = null;
    defer if (message) |msg| app.alloc.free(msg);

    const yanked = if (app.yanked) |y| y else return;

    var new_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const new_path_res = environment.checkDuplicatePath(&new_path_buf, app.directories.dir, yanked.entry.name) catch {
        message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - path too long.", .{yanked.entry.name});
        app.notification.write(message.?, .err) catch {};
        return;
    };

    switch (yanked.entry.kind) {
        .directory => {
            var source_dir = std.fs.openDirAbsolute(yanked.dir, .{ .iterate = true }) catch {
                message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - unable to open directory '{s}'.", .{ yanked.entry.name, yanked.dir });
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            };
            defer source_dir.close();

            var selected_dir = source_dir.openDir(yanked.entry.name, .{ .iterate = true }) catch {
                message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - unable to open directory '{s}'.", .{ yanked.entry.name, yanked.entry.name });
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            };
            defer selected_dir.close();

            var walker = selected_dir.walk(app.alloc) catch |err| {
                message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - unable to walk directory tree due to {}.", .{ yanked.entry.name, err });
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            };
            defer walker.deinit();

            // Make initial dir.
            app.directories.dir.makeDir(new_path_res.path) catch |err| {
                message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - unable to create new directory due to {}.", .{ yanked.entry.name, err });
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            };

            var errored = false;
            var inner_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            while (walker.next() catch |err| {
                message = try std.fmt.allocPrint(app.alloc, "Failed to copy one or more files - {}. A partial copy may have taken place.", .{err});
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            }) |entry| {
                const path = try std.fmt.bufPrint(&inner_path_buf, "{s}{s}{s}", .{ new_path_res.path, std.fs.path.sep_str, entry.path });
                switch (entry.kind) {
                    .directory => {
                        app.directories.dir.makeDir(path) catch {
                            message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - unable to create containing directory '{s}'.", .{ entry.basename, path });
                            app.notification.write(message.?, .err) catch {};
                            if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                            errored = true;
                        };
                    },
                    .file, .sym_link => {
                        entry.dir.copyFile(entry.basename, app.directories.dir, path, .{}) catch |err| switch (err) {
                            error.FileNotFound => {
                                message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - the original file was deleted or moved.", .{entry.path});
                                app.notification.write(message.?, .err) catch {};
                                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                                errored = true;
                            },
                            else => {
                                message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - {}.", .{ entry.path, err });
                                app.notification.write(message.?, .err) catch {};
                                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                                errored = true;
                            },
                        };
                    },
                    else => {
                        message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - unsupported file type '{s}'.", .{ entry.path, @tagName(entry.kind) });
                        app.notification.write(message.?, .err) catch {};
                        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                        errored = true;
                    },
                }
            }

            if (errored) {
                app.notification.write("Failed to copy some items, check the log file for more details.", .err) catch {};
            } else {
                message = try std.fmt.allocPrint(app.alloc, "Copied '{s}'.", .{yanked.entry.name});
                app.notification.write(message.?, .info) catch {};
            }
        },
        .file, .sym_link => {
            var source_dir = std.fs.openDirAbsolute(yanked.dir, .{ .iterate = true }) catch {
                message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - unable to open directory '{s}'.", .{ yanked.entry.name, yanked.dir });
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            };
            defer source_dir.close();

            std.fs.Dir.copyFile(
                source_dir,
                yanked.entry.name,
                app.directories.dir,
                new_path_res.path,
                .{},
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - the original file was deleted or moved.", .{yanked.entry.name});
                    app.notification.write(message.?, .err) catch {};
                    if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                    return;
                },
                else => {
                    message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - {}.", .{ yanked.entry.name, err });
                    app.notification.write(message.?, .err) catch {};
                    if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                    return;
                },
            };

            message = try std.fmt.allocPrint(app.alloc, "Copied '{s}'.", .{yanked.entry.name});
            app.notification.write(message.?, .info) catch {};
        },
        else => {
            message = try std.fmt.allocPrint(app.alloc, "Can not copy '{s}' - unsupported file type '{s}'.", .{ yanked.entry.name, @tagName(yanked.entry.kind) });
            app.notification.write(message.?, .warn) catch {};
            return;
        },
    }

    // Append action to undo history.
    var new_path_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const new_path_abs = app.directories.dir.realpath(new_path_res.path, &new_path_abs_buf) catch {
        message = try std.fmt.allocPrint(
            app.alloc,
            "Failed to push copy action for '{s}' to undo history - unable to retrieve absolute directory path for '{s}'. This action will not be able to be undone via the `undo` keybind.",
            .{ new_path_res.path, yanked.entry.name },
        );
        app.notification.write(message.?, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
        return;
    };

    if (app.actions.push(.{
        .paste = try app.alloc.dupe(u8, new_path_abs),
    })) |prev_elem| {
        app.alloc.free(prev_elem.delete.prev_path);
        app.alloc.free(prev_elem.delete.new_path);
    }

    try app.repopulateDirectory("");
    app.text_input.clearAndFree();
}

pub fn traverseLeft(app: *App) error{OutOfMemory}!void {
    app.text_input.clearAndFree();

    const dir = app.directories.dir.openDir("../", .{ .iterate = true }) catch |err| {
        const message = try std.fmt.allocPrint(app.alloc, "Failed to read directory entries - {}.", .{err});
        defer app.alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
        return;
    };

    app.directories.dir.close();
    app.directories.dir = dir;

    try app.repopulateDirectory("");
    app.text_input.clearAndFree();

    if (app.directories.history.pop()) |history| {
        if (history < app.directories.entries.len()) {
            app.directories.entries.selected = history;
        }
    }
}

pub fn traverseRight(app: *App) !void {
    var message: ?[]const u8 = null;
    defer if (message) |msg| app.alloc.free(msg);

    const entry = (app.directories.getSelected() catch {
        app.notification.write("Can not rename item - no item selected.", .warn) catch {};
        return;
    }) orelse return;

    switch (entry.kind) {
        .directory => {
            app.text_input.clearAndFree();

            const dir = app.directories.dir.openDir(entry.name, .{ .iterate = true }) catch |err| {
                message = try std.fmt.allocPrint(app.alloc, "Failed to read directory entries - {}.", .{err});
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            };

            app.directories.dir.close();
            app.directories.dir = dir;
            _ = app.directories.history.push(app.directories.entries.selected);
            try app.repopulateDirectory("");
            app.text_input.clearAndFree();
        },
        .file => {
            if (environment.getEditor()) |editor| {
                try app.vx.exitAltScreen(app.tty.anyWriter());
                try app.vx.resetState(app.tty.anyWriter());
                app.loop.stop();

                environment.openFile(app.alloc, app.directories.dir, entry.name, editor) catch |err| {
                    message = try std.fmt.allocPrint(app.alloc, "Failed to open file '{s}' - {}.", .{ entry.name, err });
                    app.notification.write(message.?, .err) catch {};
                    if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                };

                try app.loop.start();
                try app.vx.enterAltScreen(app.tty.anyWriter());
                try app.vx.enableDetectedFeatures(app.tty.anyWriter());
                app.vx.queueRefresh();
            } else {
                app.notification.write("Can not open file - $EDITOR not set.", .warn) catch {};
            }
        },
        else => {},
    }
}

pub fn createNewDir(app: *App) error{OutOfMemory}!void {
    var message: ?[]const u8 = null;
    defer if (message) |msg| app.alloc.free(msg);

    const dir = app.inputToSlice();

    app.directories.dir.makeDir(dir) catch |err| {
        message = try std.fmt.allocPrint(app.alloc, "Failed to create directory '{s}' - {}", .{ dir, err });
        app.notification.write(message.?, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
        app.text_input.clearAndFree();
        return;
    };

    try app.repopulateDirectory("");
    app.text_input.clearAndFree();

    message = try std.fmt.allocPrint(app.alloc, "Created new directory '{s}'.", .{dir});
    app.notification.write(message.?, .info) catch {};
}

pub fn createNewFile(app: *App) error{OutOfMemory}!void {
    var message: ?[]const u8 = null;
    defer if (message) |msg| app.alloc.free(msg);

    const file = app.inputToSlice();

    if (environment.fileExists(app.directories.dir, file)) {
        message = try std.fmt.allocPrint(app.alloc, "Can not create file - '{s}' already exists.", .{file});
        app.notification.write(message.?, .warn) catch {};
    } else {
        _ = app.directories.dir.createFile(file, .{}) catch |err| {
            message = try std.fmt.allocPrint(app.alloc, "Failed to create file '{s}' - {}", .{ file, err });
            app.notification.write(message.?, .err) catch {};
            if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
            app.text_input.clearAndFree();
            return;
        };

        try app.repopulateDirectory("");
        app.text_input.clearAndFree();

        message = try std.fmt.allocPrint(app.alloc, "Created new file '{s}'.", .{file});
        app.notification.write(message.?, .info) catch {};
    }

    app.text_input.clearAndFree();
}

pub fn undo(app: *App) error{OutOfMemory}!void {
    var message: ?[]const u8 = null;
    defer if (message) |msg| app.alloc.free(msg);

    const action = app.actions.pop() orelse {
        app.notification.write("There is nothing to undo.", .info) catch {};
        return;
    };

    const selected = app.directories.entries.selected;

    switch (action) {
        .delete => |a| {
            defer app.alloc.free(a.new_path);
            defer app.alloc.free(a.prev_path);

            var new_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const new_path_res = environment.checkDuplicatePath(&new_path_buf, app.directories.dir, a.prev_path) catch {
                message = try std.fmt.allocPrint(app.alloc, "Failed to undo delete '{s}' - path too long.", .{a.prev_path});
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            };

            app.directories.dir.rename(a.new_path, new_path_res.path) catch |err| {
                message = try std.fmt.allocPrint(app.alloc, "Failed to undo delete for '{s}' - {}.", .{ a.prev_path, err });
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            };

            try app.repopulateDirectory("");
            app.text_input.clearAndFree();

            message = try std.fmt.allocPrint(app.alloc, "Restored '{s}' as '{s}'.", .{ a.prev_path, new_path_res.path });
            app.notification.write(message.?, .info) catch {};
        },
        .rename => |a| {
            defer app.alloc.free(a.new_path);
            defer app.alloc.free(a.prev_path);

            var new_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const new_path_res = environment.checkDuplicatePath(&new_path_buf, app.directories.dir, a.prev_path) catch {
                message = try std.fmt.allocPrint(app.alloc, "Failed to undo rename '{s}' - path too long.", .{a.prev_path});
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            };

            app.directories.dir.rename(a.new_path, new_path_res.path) catch |err| {
                message = try std.fmt.allocPrint(app.alloc, "Failed to undo rename for '{s}' - {}.", .{ a.new_path, err });
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            };

            try app.repopulateDirectory("");
            app.text_input.clearAndFree();

            message = try std.fmt.allocPrint(app.alloc, "Reverted renaming of '{s}', now '{s}'.", .{ a.new_path, new_path_res.path });
            app.notification.write(message.?, .info) catch {};
        },
        .paste => |path| {
            defer app.alloc.free(path);

            app.directories.dir.deleteTree(path) catch |err| {
                message = try std.fmt.allocPrint(app.alloc, "Failed to delete '{s}' - {}.", .{ path, err });
                app.notification.write(message.?, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message.?, .err) catch {};
                return;
            };

            try app.repopulateDirectory("");
            app.text_input.clearAndFree();
        },
    }

    app.directories.entries.selected = selected;
}
