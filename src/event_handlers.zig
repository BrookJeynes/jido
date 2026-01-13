const std = @import("std");
const App = @import("./app.zig");
const environment = @import("./environment.zig");
const zuid = @import("zuid");
const vaxis = @import("vaxis");
const Key = vaxis.Key;
const config = &@import("./config.zig").config;
const commands = @import("./commands.zig");
const Keybinds = @import("./config.zig").Keybinds;
const events = @import("./events.zig");

pub fn handleGlobalEvent(
    app: *App,
    event: App.Event,
) error{OutOfMemory}!void {
    switch (event) {
        .key_press => |key| {
            if ((key.codepoint == 'c' and key.mods.ctrl)) {
                app.should_quit = true;
                return;
            }

            if ((key.codepoint == 'r' and key.mods.ctrl)) {
                if (config.parse(app.alloc, app)) {
                    app.notification.write("Reloaded configuration file.", .info) catch {};
                } else |err| switch (err) {
                    error.SyntaxError => {
                        app.notification.write("Encountered a syntax error while parsing the config file.", .err) catch {
                            std.log.err("Encountered a syntax error while parsing the config file.", .{});
                        };
                    },
                    error.InvalidCharacter => {
                        app.notification.write("One or more overriden keybinds are invalid.", .err) catch {
                            std.log.err("One or more overriden keybinds are invalid.", .{});
                        };
                    },
                    error.DuplicateKeybind => {
                        // Error logged in function
                    },
                    else => {
                        const message = try std.fmt.allocPrint(app.alloc, "Encountend an unknown error while parsing the config file - {}", .{err});
                        defer app.alloc.free(message);

                        app.notification.write(message, .err) catch {
                            std.log.err("Encountend an unknown error while parsing the config file - {}", .{err});
                        };
                    },
                }
            }
        },
        else => {},
    }
}

pub fn handleNormalEvent(
    app: *App,
    event: App.Event,
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
                    .toggle_hidden_files => try events.toggleHiddenFiles(app),
                    .delete => try events.delete(app),
                    .rename => {
                        const entry = (app.directories.getSelected() catch {
                            app.notification.write("Can not rename item - no item selected.", .warn) catch {};
                            return;
                        }) orelse return;

                        app.text_input.clearAndFree();

                        // Try insert entry name into text input for a nicer experience.
                        // This failing shouldn't stop the user from entering a new name.
                        app.text_input.insertSliceAtCursor(entry.name) catch {};
                        app.state = .rename;
                    },

                    .create_dir => {
                        try app.repopulateDirectory("");
                        app.text_input.clearAndFree();
                        app.state = .new_dir;
                    },
                    .create_file => {
                        try app.repopulateDirectory("");
                        app.text_input.clearAndFree();
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
                    .force_delete => try events.forceDelete(app),
                    .yank => try events.yank(app),
                    .paste => try events.paste(app),
                }
            } else {
                switch (key.codepoint) {
                    '-', 'h', Key.left => try events.traverseLeft(app),
                    Key.enter, 'l', Key.right => try events.traverseRight(app),
                    'j', Key.down => app.directories.entries.next(),
                    'k', Key.up => app.directories.entries.previous(),
                    'u' => try events.undo(app),
                    else => {},
                }
            }
        },
        .image_ready => {},
        .notification => {},
        .winsize => |ws| try app.vx.resize(app.alloc, app.tty.writer(), ws),
    }
}

pub fn handleInputEvent(app: *App, event: App.Event) !void {
    switch (event) {
        .key_press => |key| {
            switch (key.codepoint) {
                Key.escape => {
                    switch (app.state) {
                        .fuzzy => {
                            try app.repopulateDirectory("");
                            app.text_input.clearAndFree();
                        },
                        .command => app.command_history.cursor = null,
                        else => {},
                    }

                    app.text_input.clearAndFree();
                    app.state = .normal;
                },
                Key.enter => {
                    const selected = app.directories.entries.selected;
                    switch (app.state) {
                        .new_dir => try events.createNewDir(app),
                        .new_file => try events.createNewFile(app),
                        .rename => try events.rename(app),
                        .change_dir => {
                            const path = try app.text_input.toOwnedSlice();
                            defer app.alloc.free(path);
                            try commands.cd(app, path);
                        },
                        .command => {
                            const command = try app.text_input.toOwnedSlice();
                            defer app.alloc.free(command);

                            // Push command to history if it's not empty.
                            if (!std.mem.eql(u8, std.mem.trim(u8, command, " "), ":")) {
                                app.command_history.add(command, app.alloc) catch |err| {
                                    const message = try std.fmt.allocPrint(app.alloc, "Failed to add command to history - {}.", .{err});
                                    defer app.alloc.free(message);
                                    if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
                                };
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
                                    try commands.cd(app, command[":cd ".len..]);
                                    break :supported;
                                }

                                if (std.mem.eql(u8, command, ":empty_trash")) {
                                    try commands.emptyTrash(app);
                                    break :supported;
                                }

                                if (std.mem.eql(u8, command, ":h")) {
                                    app.state = .help_menu;
                                    break :supported;
                                }

                                try app.text_input.insertSliceAtCursor(":UnsupportedCommand");
                            }

                            app.command_history.cursor = null;
                        },
                        else => {},
                    }

                    if (app.state != .help_menu) app.state = .normal;
                    app.directories.entries.selected = selected;
                },
                Key.up => {
                    if (app.state == .command) {
                        if (app.command_history.previous()) |command| {
                            app.text_input.clearAndFree();
                            app.text_input.insertSliceAtCursor(command) catch |err| {
                                const message = try std.fmt.allocPrint(app.alloc, "Failed to get previous command history - {}.", .{err});
                                defer app.alloc.free(message);
                                app.notification.write(message, .err) catch {};
                                if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
                            };
                        }
                    }
                },
                Key.down => {
                    if (app.state == .command) {
                        app.text_input.clearAndFree();
                        if (app.command_history.next()) |command| {
                            app.text_input.insertSliceAtCursor(command) catch |err| {
                                const message = try std.fmt.allocPrint(app.alloc, "Failed to get next command history - {}.", .{err});
                                defer app.alloc.free(message);
                                app.notification.write(message, .err) catch {};
                                if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
                            };
                        } else {
                            app.text_input.insertSliceAtCursor(":") catch |err| {
                                const message = try std.fmt.allocPrint(app.alloc, "Failed to get next command history - {}.", .{err});
                                defer app.alloc.free(message);
                                app.notification.write(message, .err) catch {};
                                if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
                            };
                        }
                    }
                },
                else => {
                    try app.text_input.update(.{ .key_press = key });

                    switch (app.state) {
                        .fuzzy => {
                            const fuzzy = app.readInput();
                            try app.repopulateDirectory(fuzzy);
                        },
                        .command => {
                            const command = app.readInput();
                            if (!std.mem.startsWith(u8, command, ":")) {
                                app.text_input.clearAndFree();
                                app.text_input.insertSliceAtCursor(":") catch |err| {
                                    app.state = .normal;

                                    const message = try std.fmt.allocPrint(app.alloc, "An input error occurred while attempting to enter a command - {}.", .{err});
                                    defer app.alloc.free(message);
                                    app.notification.write(message, .err) catch {};
                                    if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
                                };
                            }
                        },
                        else => {},
                    }
                },
            }
        },
        .image_ready => {},
        .notification => {},
        .winsize => |ws| try app.vx.resize(app.alloc, app.tty.writer(), ws),
    }
}

pub fn handleHelpMenuEvent(app: *App, event: App.Event) !void {
    switch (event) {
        .key_press => |key| {
            switch (key.codepoint) {
                Key.escape, 'q' => app.state = .normal,
                'j', Key.down => app.help_menu.next(),
                'k', Key.up => app.help_menu.previous(),
                else => {},
            }
        },
        .image_ready => {},
        .notification => {},
        .winsize => |ws| try app.vx.resize(app.alloc, app.tty.writer(), ws),
    }
}
