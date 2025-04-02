const std = @import("std");
const App = @import("./app.zig");
const FileLogger = @import("./file_logger.zig");
const Notification = @import("./notification.zig");
const Directories = @import("./directories.zig");
const config = &@import("./config.zig").config;
const vaxis = @import("vaxis");
const Git = @import("./git.zig");
const List = @import("./list.zig").List;
const zeit = @import("zeit");

const Drawer = @This();

const top_div: u16 = 1;
const info_div: u16 = 1;

// Used to detect whether to re-render an image.
current_item_path_buf: [std.fs.max_path_bytes]u8 = undefined,
current_item_path: []u8 = "",
last_item_path_buf: [std.fs.max_path_bytes]u8 = undefined,
last_item_path: []u8 = "",
file_info_buf: [std.fs.max_path_bytes]u8 = undefined,
file_name_buf: [std.fs.max_path_bytes + 2]u8 = undefined, // +2 to accomodate for [<file_name>]
git_branch: [1024]u8 = undefined,
verbose: bool = false,

pub fn draw(self: *Drawer, app: *App) error{ OutOfMemory, NoSpaceLeft }!void {
    const win = app.vx.window();
    win.clear();

    if (app.state == .help_menu) {
        win.hideCursor();
        const offset: usize = app.help_menu.selected;
        for (app.help_menu.all()[offset..], 0..) |item, i| {
            if (i > win.height) continue;

            const w = win.child(.{ .y_off = @intCast(i), .height = 1 });
            w.fill(vaxis.Cell{
                .style = config.styles.list_item,
            });

            _ = w.print(&.{.{
                .text = item,
                .style = config.styles.list_item,
            }}, .{});
        }

        return;
    }

    const abs_file_path_bar = try self.drawAbsFilePath(app, win);
    const file_info_bar = try self.drawFileInfo(app.alloc, &app.directories, win);
    app.last_known_height = drawDirList(
        win,
        app.directories.entries,
        abs_file_path_bar,
        file_info_bar,
    );

    if (config.preview_file) {
        const file_name_bar = try self.drawFileName(&app.directories, win);
        try self.drawFilePreview(app, win, file_name_bar);
    }

    const input = app.inputToSlice();
    drawUserInput(app.state, &app.text_input, input, win);

    // Notification should be drawn last.
    drawNotification(&app.notification, &app.file_logger, win);
}

fn drawFileName(
    self: *Drawer,
    directories: *Directories,
    win: vaxis.Window,
) error{NoSpaceLeft}!vaxis.Window {
    const file_name_bar = win.child(.{
        .x_off = win.width / 2,
        .y_off = 0,
        .width = win.width,
        .height = top_div,
    });

    const entry = lbl: {
        const entry = directories.getSelected() catch return file_name_bar;
        if (entry) |e| break :lbl e else return file_name_bar;
    };

    const file_name = try std.fmt.bufPrint(&self.file_name_buf, "[{s}]", .{entry.name});
    _ = file_name_bar.printSegment(.{ .text = file_name, .style = config.styles.file_name }, .{});

    return file_name_bar;
}

fn drawFilePreview(
    self: *Drawer,
    app: *App,
    win: vaxis.Window,
    file_name_win: vaxis.Window,
) error{ OutOfMemory, NoSpaceLeft }!void {
    const bottom_div: u16 = 1;

    const preview_win = win.child(.{
        .x_off = win.width / 2,
        .y_off = top_div + 1,
        .width = win.width / 2,
        .height = win.height - (file_name_win.height + top_div + bottom_div),
    });

    if (app.directories.entries.len() == 0 or !config.preview_file) return;

    const entry = lbl: {
        const entry = app.directories.getSelected() catch return;
        if (entry) |e| break :lbl e else return;
    };

    @memcpy(&self.last_item_path_buf, &self.current_item_path_buf);
    self.last_item_path = self.last_item_path_buf[0..self.current_item_path.len];
    self.current_item_path = try std.fmt.bufPrint(
        &self.current_item_path_buf,
        "{s}/{s}",
        .{ app.directories.fullPath(".") catch {
            const message = try std.fmt.allocPrint(app.alloc, "Can not display file - unable to retrieve directory path.", .{});
            defer app.alloc.free(message);
            app.notification.write(message, .err) catch {};
            if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};

            _ = preview_win.print(&.{
                .{ .text = "Can not display file - unable to retrieve directory path. No preview available." },
            }, .{});
            return;
        }, entry.name },
    );

    switch (entry.kind) {
        .directory => {
            app.directories.clearChildEntries();
            app.directories.populateChildEntries(entry.name) catch |err| {
                const message = try std.fmt.allocPrint(app.alloc, "Failed to populate child directory entries - {}.", .{err});
                defer app.alloc.free(message);
                app.notification.write(message, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};

                _ = preview_win.print(&.{
                    .{ .text = "Failed to populate child directory entries. No preview available." },
                }, .{});

                return;
            };

            for (app.directories.child_entries.all(), 0..) |item, i| {
                if (std.mem.startsWith(u8, item, ".") and config.show_hidden == false) {
                    continue;
                }
                if (i > preview_win.height) continue;
                const w = preview_win.child(.{ .y_off = @intCast(i), .height = 1 });
                w.fill(vaxis.Cell{ .style = config.styles.list_item });
                _ = w.print(&.{.{ .text = item, .style = config.styles.list_item }}, .{});
            }
        },
        .file => file: {
            var file = app.directories.dir.openFile(
                entry.name,
                .{ .mode = .read_only },
            ) catch |err| {
                const message = try std.fmt.allocPrint(app.alloc, "Failed to open file - {}.", .{err});
                defer app.alloc.free(message);
                app.notification.write(message, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};

                _ = preview_win.print(&.{
                    .{ .text = "Failed to open file. No preview available." },
                }, .{});

                break :file;
            };
            defer file.close();
            const bytes = file.readAll(&app.directories.file_contents) catch |err| {
                const message = try std.fmt.allocPrint(app.alloc, "Failed to read file contents - {}.", .{err});
                defer app.alloc.free(message);
                app.notification.write(message, .err) catch {};
                if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};

                _ = preview_win.print(&.{
                    .{ .text = "Failed to read file contents. No preview available." },
                }, .{});

                break :file;
            };

            // Handle image.
            if (config.show_images == true) unsupported: {
                var match = false;
                inline for (@typeInfo(vaxis.zigimg.Image.Format).@"enum".fields) |field| {
                    const entry_ext = std.mem.trimLeft(u8, std.fs.path.extension(entry.name), ".");
                    if (std.mem.eql(u8, entry_ext, field.name)) match = true;
                }
                if (!match) break :unsupported;

                if (std.mem.eql(u8, self.last_item_path, self.current_item_path)) break :unsupported;

                var image = vaxis.zigimg.Image.fromFilePath(
                    app.alloc,
                    self.current_item_path,
                ) catch {
                    break :unsupported;
                };
                defer image.deinit();

                if (app.vx.transmitImage(app.alloc, app.tty.anyWriter(), &image, .rgba)) |img| {
                    app.image = img;
                } else |_| {
                    if (app.image) |img| {
                        app.vx.freeImage(app.tty.anyWriter(), img.id);
                    }
                    app.image = null;
                    break :unsupported;
                }

                if (app.image) |img| {
                    img.draw(preview_win, .{ .scale = .contain }) catch |err| {
                        const message = try std.fmt.allocPrint(app.alloc, "Failed to draw image to screen - {}.", .{err});
                        defer app.alloc.free(message);
                        app.notification.write(message, .err) catch {};
                        if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};

                        _ = preview_win.print(&.{
                            .{ .text = "Failed to draw image to screen. No preview available." },
                        }, .{});

                        break :file;
                    };
                }

                break :file;
            }

            // Handle pdf.
            if (std.mem.eql(u8, std.fs.path.extension(entry.name), ".pdf")) {
                const output = std.process.Child.run(.{
                    .allocator = app.alloc,
                    .argv = &[_][]const u8{
                        "pdftotext",
                        "-f",
                        "0",
                        "-l",
                        "5",
                        self.current_item_path,
                        "-",
                    },
                    .cwd_dir = app.directories.dir,
                }) catch {
                    _ = preview_win.print(&.{.{
                        .text = "No preview available. Install pdftotext to get PDF previews.",
                    }}, .{});
                    break :file;
                };
                defer app.alloc.free(output.stderr);
                defer app.alloc.free(output.stdout);

                if (output.term.Exited != 0) {
                    _ = preview_win.print(&.{.{
                        .text = "No preview available. Install pdftotext to get PDF previews.",
                    }}, .{});
                    break :file;
                }

                if (app.directories.pdf_contents) |contents| app.alloc.free(contents);
                app.directories.pdf_contents = try app.alloc.dupe(u8, output.stdout);

                _ = preview_win.print(&.{
                    .{ .text = app.directories.pdf_contents.? },
                }, .{});
                break :file;
            }

            // Handle utf-8.
            if (std.unicode.utf8ValidateSlice(app.directories.file_contents[0..bytes])) {
                _ = preview_win.print(&.{
                    .{ .text = app.directories.file_contents[0..bytes] },
                }, .{});
                break :file;
            }

            // Fallback to no preview.
            _ = preview_win.print(&.{.{ .text = "No preview available." }}, .{});
        },
        else => {
            _ = preview_win.print(&.{
                vaxis.Segment{ .text = self.current_item_path },
            }, .{});
        },
    }
}

fn drawFileInfo(
    self: *Drawer,
    alloc: std.mem.Allocator,
    directories: *Directories,
    win: vaxis.Window,
) error{NoSpaceLeft}!vaxis.Window {
    const bottom_div: u16 = if (self.verbose) 6 else 1;

    const file_info_win = win.child(.{
        .x_off = 0,
        .y_off = win.height - bottom_div,
        .width = if (config.preview_file) win.width / 2 else win.width,
        .height = bottom_div,
    });
    file_info_win.fill(.{ .style = config.styles.file_information });

    const entry = lbl: {
        const entry = directories.getSelected() catch return file_info_win;
        if (entry) |e| break :lbl e else return file_info_win;
    };

    var fbs = std.io.fixedBufferStream(&self.file_info_buf);

    // Selected entry.
    try fbs.writer().print(
        "{s}{d}/{d}{s}",
        .{
            if (self.verbose) "Entry: " else "",
            directories.entries.selected + 1,
            directories.entries.len(),
            if (self.verbose) "\n" else " ",
        },
    );

    // Time created / last modified
    if (self.verbose) lbl: {
        var maybe_meta: ?std.fs.File.Metadata = null;
        if (entry.kind == .directory) {
            maybe_meta = directories.dir.metadata() catch break :lbl;
        } else if (entry.kind == .file) {
            var file = directories.dir.openFile(entry.name, .{}) catch break :lbl;
            maybe_meta = file.metadata() catch break :lbl;
        }

        const meta = maybe_meta orelse break :lbl;
        var env = std.process.getEnvMap(alloc) catch break :lbl;
        defer env.deinit();
        const local = zeit.local(alloc, &env) catch break :lbl;
        defer local.deinit();

        const ctime_instant = zeit.instant(.{
            .source = .{ .unix_nano = meta.created().? },
            .timezone = &local,
        }) catch break :lbl;
        const ctime = ctime_instant.time();
        ctime.strftime(fbs.writer().any(), "Created: %Y-%m-%d %H:%M:%S\n") catch break :lbl;

        const mtime_instant = zeit.instant(.{
            .source = .{ .unix_nano = meta.modified() },
            .timezone = &local,
        }) catch break :lbl;
        const mtime = mtime_instant.time();
        mtime.strftime(fbs.writer().any(), "Last modified: %Y-%m-%d %H:%M:%S\n") catch break :lbl;
    }

    // File permissions.
    var file_perm_buf: [11]u8 = undefined;
    const file_perms: usize = lbl: {
        if (self.verbose) try fbs.writer().writeAll("Permissions: ");
        var file_perm_fbs = std.io.fixedBufferStream(&file_perm_buf);

        if (entry.kind == .directory) {
            _ = try file_perm_fbs.write("d");
        }

        const perm_strings = [_][]const u8{
            "---", "--x", "-w-", "-wx",
            "r--", "r-x", "rw-", "rwx",
        };

        const stat = directories.dir.statFile(entry.name) catch {
            _ = try file_perm_fbs.write("---------\n");
            break :lbl 10;
        };
        // Ignore upper bytes as they represent file type.
        const perms = @as(u9, @truncate(stat.mode));

        for (0..3) |group| {
            const shift: u4 = @truncate((2 - group) * 3); // Extract from left to right
            const perm = @as(u3, @truncate((perms >> shift) & 0b111));
            _ = try file_perm_fbs.write(perm_strings[perm]);
        }

        if (self.verbose) {
            _ = try file_perm_fbs.write("\n");
        } else {
            _ = try file_perm_fbs.write(" ");
        }

        if (entry.kind == .directory) {
            break :lbl 11;
        } else {
            break :lbl 10;
        }
    };
    try fbs.writer().writeAll(file_perm_buf[0..file_perms]);

    // Size.
    const size: ?usize = lbl: {
        const stat = directories.dir.statFile(entry.name) catch break :lbl null;
        if (entry.kind == .file) {
            break :lbl stat.size;
        } else if (entry.kind == .directory) {
            if (config.true_dir_size) {
                var dir = directories.dir.openDir(
                    entry.name,
                    .{ .iterate = true },
                ) catch break :lbl null;
                defer dir.close();
                break :lbl directories.getDirSize(dir) catch break :lbl null;
            } else {
                break :lbl stat.size;
            }
        }

        break :lbl 0;
    };
    if (size) |s| try fbs.writer().print("{s}{:.2}\n", .{
        if (self.verbose) "Size: " else "",
        std.fmt.fmtIntSizeDec(s),
    });

    // Extension.
    const extension = std.fs.path.extension(entry.name);
    if (self.verbose) {
        try fbs.writer().print(
            "Extension: {s}\n",
            .{if (entry.kind == .directory) "Dir" else extension},
        );
    } else {
        try fbs.writer().print(
            "{s} ",
            .{if (entry.kind == .directory) "dir" else extension},
        );
    }

    _ = file_info_win.printSegment(.{
        .text = fbs.getWritten(),
        .style = config.styles.file_information,
    }, .{});

    return file_info_win;
}

fn drawDirList(
    win: vaxis.Window,
    list: List(std.fs.Dir.Entry),
    abs_file_path: vaxis.Window,
    file_information: vaxis.Window,
) u16 {
    const bottom_div: u16 = 1;

    const current_dir_list_win = win.child(.{
        .x_off = 0,
        .y_off = top_div + 1,
        .width = if (config.preview_file) win.width / 2 else win.width,
        .height = win.height - (abs_file_path.height + file_information.height + top_div + bottom_div),
    });

    const win_height = current_dir_list_win.height;
    var offset: usize = 0;

    while (list.all()[offset..].len > win_height and
        list.selected >= offset + (win_height / 2))
    {
        offset += 1;
    }

    for (list.all()[offset..], 0..) |item, i| {
        const selected = list.selected - offset;
        const is_selected = selected == i;

        if (i > win_height) continue;

        const w = current_dir_list_win.child(.{ .y_off = @intCast(i), .height = 1 });
        w.fill(vaxis.Cell{
            .style = if (is_selected) config.styles.selected_list_item else config.styles.list_item,
        });

        _ = w.print(&.{
            .{
                .text = item.name,
                .style = if (is_selected) config.styles.selected_list_item else config.styles.list_item,
            },
        }, .{});
    }

    return win_height;
}

fn drawAbsFilePath(
    self: *Drawer,
    app: *App,
    win: vaxis.Window,
) error{ OutOfMemory, NoSpaceLeft }!vaxis.Window {
    const abs_file_path_bar = win.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = win.width,
        .height = top_div,
    });

    const branch_alloc = Git.getGitBranch(app.alloc, app.directories.dir) catch null;
    defer if (branch_alloc) |b| app.alloc.free(b);
    const branch = if (branch_alloc) |b|
        try std.fmt.bufPrint(
            &self.git_branch,
            "{s}",
            .{std.mem.trim(u8, b, " \n\r")},
        )
    else
        "";

    _ = abs_file_path_bar.print(&.{
        vaxis.Segment{ .text = app.directories.fullPath(".") catch {
            const message = try std.fmt.allocPrint(app.alloc, "Can not display absolute file path - unable to retrieve full path.", .{});
            defer app.alloc.free(message);
            app.notification.write(message, .err) catch {};
            if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
            return abs_file_path_bar;
        } },
        vaxis.Segment{ .text = if (branch_alloc != null) " on " else "" },
        vaxis.Segment{ .text = branch, .style = config.styles.git_branch },
    }, .{});

    return abs_file_path_bar;
}

fn drawUserInput(
    current_state: App.State,
    text_input: *vaxis.widgets.TextInput,
    input: []const u8,
    win: vaxis.Window,
) void {
    const user_input_win = win.child(.{
        .x_off = 0,
        .y_off = top_div,
        .width = win.width / 2,
        .height = info_div,
    });
    user_input_win.fill(.{ .style = config.styles.text_input });

    switch (current_state) {
        .fuzzy, .new_file, .new_dir, .rename, .change_dir, .command => {
            text_input.drawWithStyle(user_input_win, config.styles.text_input);
        },
        .normal => {
            if (text_input.buf.realLength() > 0) {
                text_input.drawWithStyle(
                    user_input_win,
                    if (std.mem.eql(u8, input, ":UnsupportedCommand"))
                        config.styles.text_input_err
                    else
                        config.styles.text_input,
                );
            }

            win.hideCursor();
        },
        .help_menu => {
            win.hideCursor();
        },
    }
}

fn drawNotification(
    notification: *Notification,
    file_logger: *?FileLogger,
    win: vaxis.Window,
) void {
    if (notification.len() == 0) return;
    if (notification.clearIfEnded()) return;

    const width_padding = 4;
    const height_padding = 3;
    const screen_pos_padding = 10;

    const max_width = win.width / 4;
    const width = notification.len() + width_padding;
    const calculated_width = if (width > max_width) max_width else width;
    const height = (std.math.divCeil(usize, notification.len(), calculated_width) catch {
        if (file_logger.*) |fl| fl.write("Unable to display notification - failed to calculate notification height.", .err) catch {};
        return;
    }) + height_padding;

    const notification_win = win.child(.{
        .x_off = @intCast(win.width - (calculated_width + screen_pos_padding)),
        .y_off = top_div,
        .width = @intCast(calculated_width),
        .height = @intCast(height),
        .border = .{ .where = .all, .style = switch (notification.style) {
            .info => config.styles.notification.info,
            .err => config.styles.notification.err,
            .warn => config.styles.notification.warn,
        } },
    });

    notification_win.fill(.{ .style = config.styles.notification.box });
    _ = notification_win.printSegment(.{
        .text = notification.slice(),
        .style = config.styles.notification.box,
    }, .{ .wrap = .word });
}
