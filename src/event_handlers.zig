const std = @import("std");
const App = @import("./app.zig");
const environment = @import("./environment.zig");
const zuid = @import("zuid");
const vaxis = @import("vaxis");
const Key = vaxis.Key;
const config = &@import("./config.zig").config;
const commands = @import("./commands.zig");
const Keybinds = @import("./config.zig").Keybinds;

pub fn inputToSlice(self: *App) []const u8 {
    self.text_input.buf.cursor = self.text_input.buf.realLength();
    return self.text_input.sliceToCursor(&self.text_input_buf);
}

pub fn handleNormalEvent(
    app: *App,
    event: App.Event,
    loop: *vaxis.Loop(App.Event),
) !void {
    switch (event) {
        .key_press => |key| {
            @setEvalBranchQuota(
                std.meta.fields(Keybinds).len * 1000,
            );

            const maybe_remap: ?std.meta.FieldEnum(Keybinds) = lbl: {
                inline for (std.meta.fields(Keybinds)) |field| {
                    if (@field(config.keybinds, field.name)) |field_value| {
                        if (key.codepoint == @intFromEnum(field_value)) {
                            break :lbl comptime std.meta.stringToEnum(std.meta.FieldEnum(Keybinds), field.name) orelse unreachable;
                        }
                    }
                }
                break :lbl null;
            };

            if (maybe_remap) |action| {
                switch (action) {
                    .toggle_hidden_files => {
                        config.show_hidden = !config.show_hidden;

                        const prev_selected_name: []const u8, const prev_selected_err: bool = lbl: {
                            const selected = app.directories.getSelected() catch break :lbl .{ "", true };
                            if (selected == null) break :lbl .{ "", true };

                            break :lbl .{ try app.alloc.dupe(u8, selected.?.name), false };
                        };
                        defer if (!prev_selected_err) app.alloc.free(prev_selected_name);

                        app.directories.clearEntries();
                        app.text_input.clearAndFree();
                        app.directories.populateEntries("") catch |err| {
                            switch (err) {
                                error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                else => try app.notification.writeErr(.UnknownError),
                            }
                        };

                        for (app.directories.entries.all()) |entry| {
                            if (std.mem.eql(u8, entry.name, prev_selected_name)) return;
                            app.directories.entries.selected += 1;
                        }

                        // If it didn't find entry, reset selected.
                        app.directories.entries.selected = 0;
                    },
                    .delete => {
                        const entry = lbl: {
                            const entry = app.directories.getSelected() catch {
                                try app.notification.writeErr(.UnableToDelete);
                                return;
                            };
                            if (entry) |e| break :lbl e else return;
                        };

                        var prev_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const prev_path = try app.alloc.dupe(u8, try app.directories.dir.realpath(entry.name, &prev_path_buf));

                        var trash_dir = dir: {
                            notfound: {
                                break :dir (config.trashDir() catch break :notfound) orelse break :notfound;
                            }
                            app.alloc.free(prev_path);
                            try app.notification.writeErr(.ConfigPathNotFound);
                            return;
                        };
                        defer trash_dir.close();
                        var trash_dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const trash_dir_path = try trash_dir.realpath(".", &trash_dir_path_buf);

                        if (std.mem.eql(u8, prev_path, trash_dir_path)) {
                            try app.notification.writeErr(.CannotDeleteTrashDir);
                            app.alloc.free(prev_path);
                            return;
                        }

                        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const tmp_path = try app.alloc.dupe(u8, try std.fmt.bufPrint(&tmp_path_buf, "{s}/{s}-{s}", .{ trash_dir_path, entry.name, zuid.new.v4() }));

                        if (app.directories.dir.rename(entry.name, tmp_path)) {
                            if (app.actions.push(.{
                                .delete = .{ .prev_path = prev_path, .new_path = tmp_path },
                            })) |prev_elem| {
                                app.alloc.free(prev_elem.delete.prev_path);
                                app.alloc.free(prev_elem.delete.new_path);
                            }

                            try app.notification.writeInfo(.Deleted);
                            app.directories.removeSelected();
                        } else |err| {
                            switch (err) {
                                error.RenameAcrossMountPoints => try app.notification.writeErr(.UnableToDeleteAcrossMountPoints),
                                else => try app.notification.writeErr(.UnableToDelete),
                            }
                            app.alloc.free(prev_path);
                            app.alloc.free(tmp_path);
                        }
                    },
                    .rename => {
                        app.text_input.clearAndFree();
                        app.state = .rename;

                        const entry = lbl: {
                            const entry = app.directories.getSelected() catch {
                                app.state = .normal;
                                try app.notification.writeErr(.UnableToRename);
                                return;
                            };
                            if (entry) |e| break :lbl e else {
                                app.state = .normal;
                                return;
                            }
                        };

                        app.text_input.insertSliceAtCursor(entry.name) catch {
                            app.state = .normal;
                            try app.notification.writeErr(.UnableToRename);
                            return;
                        };
                    },
                    .create_dir => {
                        app.text_input.clearAndFree();
                        app.directories.clearEntries();
                        app.directories.populateEntries("") catch |err| {
                            switch (err) {
                                error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                else => try app.notification.writeErr(.UnknownError),
                            }
                        };
                        app.state = .new_dir;
                    },
                    .create_file => {
                        app.text_input.clearAndFree();
                        app.directories.clearEntries();
                        app.directories.populateEntries("") catch |err| {
                            switch (err) {
                                error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                else => try app.notification.writeErr(.UnknownError),
                            }
                        };
                        app.state = .new_file;
                    },
                    .fuzzy_find => {
                        app.text_input.clearAndFree();
                        app.state = .fuzzy;
                    },
                    .change_dir => {
                        app.text_input.clearAndFree();
                        app.state = .change_dir;
                    },
                    .enter_command_mode => {
                        app.text_input.clearAndFree();
                        app.text_input.insertSliceAtCursor(":") catch {};
                        app.state = .command;
                    },
                    .jump_bottom => app.directories.entries.selectLast(),
                    .jump_top => app.directories.entries.selectFirst(),
                    .toggle_verbose_file_information => app.drawer.verbose = !app.drawer.verbose,
                    .force_delete => {
                        const entry = lbl: {
                            const entry = app.directories.getSelected() catch {
                                try app.notification.writeErr(.UnableToDelete);
                                return;
                            };
                            if (entry) |e| break :lbl e else return;
                        };

                        app.directories.dir.deleteTree(entry.name) catch {
                            try app.notification.writeErr(.UnableToDelete);
                            return;
                        };
                        app.directories.removeSelected();
                    },
                    .yank => {
                        if (app.yanked) |yanked| {
                            app.alloc.free(yanked.dir);
                            app.alloc.free(yanked.entry.name);
                        }

                        app.yanked = lbl: {
                            const entry = (app.directories.getSelected() catch {
                                app.notification.write("Failed to yank item - no item selected.", .warn) catch {};
                                break :lbl null;
                            }) orelse break :lbl null;

                            switch (entry.kind) {
                                .file => {
                                    break :lbl .{
                                        .dir = try app.alloc.dupe(u8, app.directories.fullPath(".") catch {
                                            const message = try std.fmt.allocPrint(
                                                app.alloc,
                                                "Failed to yank '{s}' - unable to retrieve directory path.",
                                                .{entry.name},
                                            );
                                            defer app.alloc.free(message);
                                            app.notification.write(message, .err) catch {};
                                            if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
                                            break :lbl null;
                                        }),
                                        .entry = .{
                                            .kind = entry.kind,
                                            .name = try app.alloc.dupe(u8, entry.name),
                                        },
                                    };
                                },
                                else => {
                                    const message = try std.fmt.allocPrint(
                                        app.alloc,
                                        "Failed to yank '{s}' - unsupported file type '{s}'.",
                                        .{ entry.name, @tagName(entry.kind) },
                                    );
                                    defer app.alloc.free(message);
                                    app.notification.write(message, .warn) catch {};
                                    break :lbl null;
                                },
                            }
                        };
                        if (app.yanked) |y| {
                            const message = try std.fmt.allocPrint(app.alloc, "Yanked '{s}'.", .{y.entry.name});
                            defer app.alloc.free(message);
                            app.notification.write(message, .info) catch {};
                        }
                    },
                    .paste => {
                        const yanked = if (app.yanked) |y| y else return;

                        var new_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const new_path_res = environment.checkDuplicatePath(&new_path_buf, app.directories.dir, yanked.entry.name) catch {
                            const message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - path too long.", .{yanked.entry.name});
                            defer app.alloc.free(message);
                            app.notification.write(message, .err) catch {};
                            return;
                        };

                        switch (yanked.entry.kind) {
                            .file => {
                                var source_dir = std.fs.openDirAbsolute(yanked.dir, .{ .iterate = true }) catch {
                                    const message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - unable to open directory '{s}'.", .{ yanked.entry.name, yanked.dir });
                                    defer app.alloc.free(message);
                                    app.notification.write(message, .err) catch {};
                                    if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
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
                                        const message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - the original file was deleted or moved.", .{yanked.entry.name});
                                        defer app.alloc.free(message);
                                        app.notification.write(message, .err) catch {};
                                        if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
                                        return;
                                    },
                                    else => {
                                        const message = try std.fmt.allocPrint(app.alloc, "Failed to copy '{s}' - {}.", .{ yanked.entry.name, err });
                                        defer app.alloc.free(message);
                                        app.notification.write(message, .err) catch {};
                                        if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
                                        return;
                                    },
                                };

                                // Append action to undo history.
                                {
                                    var new_path_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
                                    const new_path_abs = app.directories.dir.realpath(new_path_res.path, &new_path_abs_buf) catch {
                                        const message = try std.fmt.allocPrint(
                                            app.alloc,
                                            "Failed to push copy action for '{s}' to undo history - unable to retrieve absolute directory path for '{s}'. This action will not be able to be undone via the `undo` keybind.",
                                            .{ new_path_res.path, yanked.entry.name },
                                        );
                                        defer app.alloc.free(message);
                                        app.notification.write(message, .err) catch {};
                                        if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
                                        return;
                                    };

                                    if (app.actions.push(.{
                                        .paste = try app.alloc.dupe(u8, new_path_abs),
                                    })) |prev_elem| {
                                        app.alloc.free(prev_elem.delete.prev_path);
                                        app.alloc.free(prev_elem.delete.new_path);
                                    }
                                }

                                const message = try std.fmt.allocPrint(app.alloc, "Copied '{s}'.", .{yanked.entry.name});
                                defer app.alloc.free(message);
                                app.notification.write(message, .info) catch {};
                            },
                            else => {
                                const message = try std.fmt.allocPrint(
                                    app.alloc,
                                    "Failed to copy '{s}' - unsupported file type '{s}'.",
                                    .{ yanked.entry.name, @tagName(yanked.entry.kind) },
                                );
                                defer app.alloc.free(message);
                                app.notification.write(message, .warn) catch {};
                            },
                        }

                        app.directories.clearEntries();
                        app.directories.populateEntries("") catch |err| {
                            switch (err) {
                                error.AccessDenied => app.notification.writeErr(.PermissionDenied) catch {},
                                else => app.notification.writeErr(.UnknownError) catch {},
                            }
                        };
                    },
                }
            } else {
                switch (key.codepoint) {
                    '-', 'h', Key.left => {
                        app.text_input.clearAndFree();

                        if (app.directories.dir.openDir("../", .{ .iterate = true })) |dir| {
                            app.directories.dir.close();
                            app.directories.dir = dir;

                            app.directories.clearEntries();
                            const fuzzy = inputToSlice(app);
                            app.directories.populateEntries(fuzzy) catch |err| {
                                switch (err) {
                                    error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                    else => try app.notification.writeErr(.UnknownError),
                                }
                            };

                            if (app.directories.history.pop()) |history| {
                                if (history < app.directories.entries.len()) {
                                    app.directories.entries.selected = history;
                                }
                            }
                        } else |err| {
                            switch (err) {
                                error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                else => try app.notification.writeErr(.UnknownError),
                            }
                        }
                    },
                    Key.enter, 'l', Key.right => {
                        const entry = lbl: {
                            const entry = app.directories.getSelected() catch return;
                            if (entry) |e| break :lbl e else return;
                        };

                        switch (entry.kind) {
                            .directory => {
                                app.text_input.clearAndFree();

                                if (app.directories.dir.openDir(entry.name, .{ .iterate = true })) |dir| {
                                    app.directories.dir.close();
                                    app.directories.dir = dir;

                                    _ = app.directories.history.push(app.directories.entries.selected);

                                    app.directories.clearEntries();
                                    const fuzzy = inputToSlice(app);
                                    app.directories.populateEntries(fuzzy) catch |err| {
                                        switch (err) {
                                            error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                            else => try app.notification.writeErr(.UnknownError),
                                        }
                                    };
                                } else |err| {
                                    switch (err) {
                                        error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                        else => try app.notification.writeErr(.UnknownError),
                                    }
                                }
                            },
                            .file => {
                                if (environment.getEditor()) |editor| {
                                    try app.vx.exitAltScreen(app.tty.anyWriter());
                                    try app.vx.resetState(app.tty.anyWriter());
                                    loop.stop();

                                    environment.openFile(app.alloc, app.directories.dir, entry.name, editor) catch {
                                        try app.notification.writeErr(.UnableToOpenFile);
                                    };

                                    try loop.start();
                                    try app.vx.enterAltScreen(app.tty.anyWriter());
                                    try app.vx.enableDetectedFeatures(app.tty.anyWriter());
                                    app.vx.queueRefresh();
                                } else {
                                    try app.notification.writeErr(.EditorNotSet);
                                }
                            },
                            else => {},
                        }
                    },
                    'j', Key.down => {
                        app.directories.entries.next();
                    },
                    'k', Key.up => {
                        app.directories.entries.previous();
                    },
                    'u' => {
                        if (app.actions.pop()) |action| {
                            const selected = app.directories.entries.selected;

                            switch (action) {
                                .delete => |a| {
                                    defer app.alloc.free(a.new_path);
                                    defer app.alloc.free(a.prev_path);

                                    var new_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                                    const new_path_res = try environment.checkDuplicatePath(&new_path_buf, app.directories.dir, a.prev_path);

                                    if (app.directories.dir.rename(a.new_path, new_path_res.path)) {
                                        app.directories.clearEntries();
                                        app.directories.populateEntries("") catch |err| {
                                            switch (err) {
                                                error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                                else => try app.notification.writeErr(.UnknownError),
                                            }
                                        };
                                        if (new_path_res.had_duplicate) {
                                            try app.notification.writeWarn(.DuplicateFileOnUndo);
                                        } else {
                                            try app.notification.writeInfo(.RestoredDelete);
                                        }
                                    } else |_| {
                                        try app.notification.writeErr(.UnableToUndo);
                                    }
                                },
                                .rename => |a| {
                                    defer app.alloc.free(a.new_path);
                                    defer app.alloc.free(a.prev_path);

                                    var new_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                                    const new_path_res = try environment.checkDuplicatePath(&new_path_buf, app.directories.dir, a.prev_path);

                                    if (app.directories.dir.rename(a.new_path, new_path_res.path)) {
                                        app.directories.clearEntries();
                                        app.directories.populateEntries("") catch |err| {
                                            switch (err) {
                                                error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                                else => try app.notification.writeErr(.UnknownError),
                                            }
                                        };
                                        if (new_path_res.had_duplicate) {
                                            try app.notification.writeWarn(.DuplicateFileOnUndo);
                                        } else {
                                            try app.notification.writeInfo(.RestoredRename);
                                        }
                                    } else |_| {
                                        try app.notification.writeErr(.UnableToUndo);
                                    }
                                },
                                .paste => |path| {
                                    defer app.alloc.free(path);

                                    app.directories.dir.deleteTree(path) catch {
                                        try app.notification.writeErr(.UnableToUndo);
                                        return;
                                    };

                                    app.directories.clearEntries();
                                    app.directories.populateEntries("") catch |err| {
                                        switch (err) {
                                            error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                            else => try app.notification.writeErr(.UnknownError),
                                        }
                                    };
                                },
                            }

                            app.directories.entries.selected = selected;
                        } else {
                            try app.notification.writeInfo(.EmptyUndo);
                        }
                    },
                    else => {},
                }
            }
        },
        .winsize => |ws| try app.vx.resize(app.alloc, app.tty.anyWriter(), ws),
    }
}

pub fn handleInputEvent(app: *App, event: App.Event) !void {
    switch (event) {
        .key_press => |key| {
            switch (key.codepoint) {
                Key.escape => {
                    switch (app.state) {
                        .fuzzy => {
                            app.directories.clearEntries();
                            app.directories.populateEntries("") catch |err| {
                                switch (err) {
                                    error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                    else => try app.notification.writeErr(.UnknownError),
                                }
                            };
                        },
                        .command => app.command_history.resetSelected(),
                        else => {},
                    }

                    app.text_input.clearAndFree();
                    app.state = .normal;
                },
                Key.enter => {
                    const selected = app.directories.entries.selected;
                    switch (app.state) {
                        .new_dir => {
                            const dir = inputToSlice(app);
                            if (app.directories.dir.makeDir(dir)) {
                                try app.notification.writeInfo(.CreatedFolder);

                                app.directories.clearEntries();
                                app.directories.populateEntries("") catch |err| {
                                    switch (err) {
                                        error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                        else => try app.notification.writeErr(.UnknownError),
                                    }
                                };
                            } else |err| {
                                switch (err) {
                                    error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                    error.PathAlreadyExists => try app.notification.writeErr(.ItemAlreadyExists),
                                    else => try app.notification.writeErr(.UnknownError),
                                }
                            }
                            app.text_input.clearAndFree();
                        },
                        .new_file => {
                            const file = inputToSlice(app);
                            if (environment.fileExists(app.directories.dir, file)) {
                                try app.notification.writeErr(.ItemAlreadyExists);
                            } else {
                                if (app.directories.dir.createFile(file, .{})) |f| {
                                    f.close();

                                    try app.notification.writeInfo(.CreatedFile);

                                    app.directories.clearEntries();
                                    app.directories.populateEntries("") catch |err| {
                                        switch (err) {
                                            error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                            else => try app.notification.writeErr(.UnknownError),
                                        }
                                    };
                                } else |err| {
                                    switch (err) {
                                        error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                        else => try app.notification.writeErr(.UnknownError),
                                    }
                                }
                            }
                            app.text_input.clearAndFree();
                        },
                        .rename => {
                            var dir_prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
                            const dir_prefix = try app.directories.dir.realpath(".", &dir_prefix_buf);

                            const entry = lbl: {
                                const entry = app.directories.getSelected() catch {
                                    try app.notification.writeErr(.UnableToRename);
                                    return;
                                };
                                if (entry) |e| break :lbl e else return;
                            };
                            const new_path = inputToSlice(app);

                            if (environment.fileExists(app.directories.dir, new_path)) {
                                try app.notification.writeErr(.ItemAlreadyExists);
                            } else {
                                app.directories.dir.rename(entry.name, new_path) catch |err| switch (err) {
                                    error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                    error.PathAlreadyExists => try app.notification.writeErr(.ItemAlreadyExists),
                                    else => try app.notification.writeErr(.UnknownError),
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

                                try app.notification.writeInfo(.Renamed);

                                app.directories.clearEntries();
                                app.directories.populateEntries("") catch |err| {
                                    switch (err) {
                                        error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                        else => try app.notification.writeErr(.UnknownError),
                                    }
                                };
                            }
                            app.text_input.clearAndFree();
                        },
                        .change_dir => {
                            const path = inputToSlice(app);
                            try commands.cd(app, path);
                            app.text_input.clearAndFree();
                        },
                        .command => {
                            const command = inputToSlice(app);
                            if (!std.mem.eql(u8, std.mem.trim(u8, command, " "), ":")) {
                                if (app.command_history.push(try app.alloc.dupe(u8, command))) |deleted| {
                                    app.alloc.free(deleted);
                                }
                            }

                            supported: {
                                if (std.mem.eql(u8, command, ":q")) {
                                    app.should_quit = true;
                                    return;
                                }

                                if (std.mem.eql(u8, command, ":config")) {
                                    try commands.config(app);
                                    break :supported;
                                }

                                if (std.mem.eql(u8, command, ":trash")) {
                                    try commands.trash(app);
                                    break :supported;
                                }

                                if (std.mem.startsWith(u8, command, ":cd ")) {
                                    const path = std.mem.trim(u8, command, ":cd \n\r");
                                    try commands.cd(app, path);
                                    break :supported;
                                }

                                if (std.mem.eql(u8, command, ":empty_trash")) {
                                    try commands.emptyTrash(app);
                                    break :supported;
                                }

                                if (std.mem.eql(u8, command, ":h")) {
                                    try commands.displayHelpMenu(app);
                                    break :supported;
                                }

                                app.text_input.clearAndFree();
                                try app.text_input.insertSliceAtCursor(":UnsupportedCommand");
                            }

                            app.command_history.resetSelected();
                        },
                        else => {},
                    }

                    // TODO(2025-03-29): Could there be a better way to check
                    // this?
                    if (app.state != .help_menu) app.state = .normal;
                    app.directories.entries.selected = selected;
                },
                Key.left => app.text_input.cursorLeft(),
                Key.right => app.text_input.cursorRight(),
                Key.up => {
                    if (app.state == .command) {
                        if (app.command_history.next()) |command| {
                            app.text_input.clearAndFree();
                            try app.text_input.insertSliceAtCursor(command);
                        }
                    }
                },
                Key.down => {
                    if (app.state == .command) {
                        app.text_input.clearAndFree();
                        if (app.command_history.previous()) |command| {
                            try app.text_input.insertSliceAtCursor(command);
                        } else {
                            try app.text_input.insertSliceAtCursor(":");
                        }
                    }
                },
                else => {
                    try app.text_input.update(.{ .key_press = key });

                    switch (app.state) {
                        .fuzzy => {
                            app.directories.clearEntries();
                            const fuzzy = inputToSlice(app);
                            app.directories.populateEntries(fuzzy) catch |err| {
                                switch (err) {
                                    error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                                    else => try app.notification.writeErr(.UnknownError),
                                }
                            };
                        },
                        .command => {
                            const command = inputToSlice(app);
                            if (!std.mem.startsWith(u8, command, ":")) {
                                app.text_input.clearAndFree();
                                try app.text_input.insertSliceAtCursor(":");
                            }
                        },
                        else => {},
                    }
                },
            }
        },
        .winsize => |ws| try app.vx.resize(app.alloc, app.tty.anyWriter(), ws),
    }
}

pub fn handleHelpMenuEvent(app: *App, event: App.Event) !void {
    switch (event) {
        .key_press => |key| {
            switch (key.codepoint) {
                Key.escape, 'q' => app.state = .normal,
                'j', Key.down => {
                    app.help_menu.next();
                },
                'k', Key.up => {
                    app.help_menu.previous();
                },
                else => {},
            }
        },
        .winsize => |ws| try app.vx.resize(app.alloc, app.tty.anyWriter(), ws),
    }
}
