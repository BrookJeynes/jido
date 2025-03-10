const std = @import("std");
const App = @import("./app.zig");
const Notification = @import("./notification.zig");
const Directories = @import("./directories.zig");
const config = &@import("./config.zig").config;
const vaxis = @import("vaxis");
const Git = @import("./git.zig");
const inputToSlice = @import("./event_handlers.zig").inputToSlice;

const Drawer = @This();

const top_div: u16 = 1;
const info_div: u16 = 1;
const bottom_div: u16 = 1;

// Used to detect whether to re-render an image.
current_item_path_buf: [std.fs.max_path_bytes]u8 = undefined,
current_item_path: []u8 = "",
last_item_path_buf: [std.fs.max_path_bytes]u8 = undefined,
last_item_path: []u8 = "",
file_info_buf: [std.fs.max_path_bytes]u8 = undefined,
file_name_buf: [std.fs.max_path_bytes + 2]u8 = undefined, // +2 to accomodate for [<file_name>]
git_branch: [1024]u8 = undefined,

pub fn draw(self: *Drawer, app: *App) !void {
    const win = app.vx.window();
    win.clear();

    const abs_file_path_bar = try self.drawAbsFilePath(app.alloc, &app.directories, win);
    const file_info_bar = try self.drawFileInfo(&app.directories, win);
    app.last_known_height = try drawDirList(
        &app.directories,
        win,
        abs_file_path_bar,
        file_info_bar,
    );

    if (config.preview_file == true) {
        const file_name_bar = try self.drawFileName(&app.directories, win);
        try self.drawFilePreview(app, win, file_name_bar);
    }

    const input = inputToSlice(app);
    try drawUserInput(app.state, &app.text_input, input, win);
    try drawNotification(&app.notification, win);
}

fn drawFileName(
    self: *Drawer,
    directories: *Directories,
    win: vaxis.Window,
) !vaxis.Window {
    const file_name_bar = win.child(.{
        .x_off = win.width / 2,
        .y_off = 0,
        .width = win.width,
        .height = top_div,
    });

    lbl: {
        const entry = directories.getSelected() catch break :lbl;
        if (entry) |e| {
            const file_name = try std.fmt.bufPrint(
                &self.file_name_buf,
                "[{s}]",
                .{e.name},
            );
            _ = file_name_bar.print(&.{vaxis.Segment{
                .text = file_name,
                .style = config.styles.file_name,
            }}, .{});
        }
    }

    return file_name_bar;
}

fn drawFilePreview(
    self: *Drawer,
    app: *App,
    win: vaxis.Window,
    file_name_win: vaxis.Window,
) !void {
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
        .{ try app.directories.fullPath("."), entry.name },
    );

    switch (entry.kind) {
        .directory => {
            app.directories.clearChildEntries();
            if (app.directories.populateChildEntries(entry.name)) {
                try app.directories.writeChildEntries(preview_win, config.styles.list_item);
            } else |err| {
                switch (err) {
                    error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                    else => try app.notification.writeErr(.UnknownError),
                }
            }
        },
        .file => file: {
            var file = app.directories.dir.openFile(entry.name, .{ .mode = .read_only }) catch |err| {
                switch (err) {
                    error.AccessDenied => try app.notification.writeErr(.PermissionDenied),
                    else => try app.notification.writeErr(.UnknownError),
                }

                _ = preview_win.print(&.{
                    .{ .text = "No preview available." },
                }, .{});

                break :file;
            };
            defer file.close();
            const bytes = try file.readAll(&app.directories.file_contents);

            // Handle image.
            if (config.show_images == true) unsupported: {
                var match = false;
                inline for (@typeInfo(vaxis.zigimg.Image.Format).@"enum".fields) |field| {
                    const entry_ext = std.mem.trimLeft(
                        u8,
                        std.fs.path.extension(entry.name),
                        ".",
                    );
                    if (std.mem.eql(u8, entry_ext, field.name)) {
                        match = true;
                    }
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
                    try img.draw(preview_win, .{ .scale = .contain });
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
    directories: *Directories,
    win: vaxis.Window,
) !vaxis.Window {
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
    try fbs.writer().print(
        "{d}/{d} ",
        .{ directories.entries.selected + 1, directories.entries.len() },
    );

    if (entry.kind == .directory) {
        _ = file_info_win.printSegment(.{
            .text = fbs.getWritten(),
            .style = config.styles.file_information,
        }, .{});
        return file_info_win;
    }

    const file_size: u64 = lbl: {
        const formatted_size = directories.dir.statFile(entry.name) catch break :lbl 0;
        break :lbl formatted_size.size;
    };

    const extension = std.fs.path.extension(entry.name);
    if (extension.len > 0) try fbs.writer().print("{s} ", .{extension});

    try fbs.writer().print("{:.2}", .{std.fmt.fmtIntSizeDec(file_size)});

    _ = file_info_win.printSegment(.{
        .text = fbs.getWritten(),
        .style = config.styles.file_information,
    }, .{});

    return file_info_win;
}

fn drawDirList(
    directories: *Directories,
    win: vaxis.Window,
    abs_file_path: vaxis.Window,
    file_information: vaxis.Window,
) !u16 {
    const current_dir_list_win = win.child(.{
        .x_off = 0,
        .y_off = top_div + 1,
        .width = if (config.preview_file) win.width / 2 else win.width,
        .height = win.height - (abs_file_path.height + file_information.height + top_div + bottom_div),
    });
    try directories.writeEntries(
        current_dir_list_win,
        config.styles.selected_list_item,
        config.styles.list_item,
    );

    return current_dir_list_win.height;
}

fn drawAbsFilePath(
    self: *Drawer,
    alloc: std.mem.Allocator,
    directories: *Directories,
    win: vaxis.Window,
) !vaxis.Window {
    const abs_file_path_bar = win.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = win.width,
        .height = top_div,
    });

    const branch_alloc = try Git.getGitBranch(alloc, directories.dir);
    defer if (branch_alloc) |b| alloc.free(b);
    const branch = if (branch_alloc) |b|
        try std.fmt.bufPrint(
            &self.git_branch,
            "{s}",
            .{std.mem.trim(u8, b, " \n\r")},
        )
    else
        "";

    _ = abs_file_path_bar.print(&.{
        vaxis.Segment{ .text = try directories.fullPath(".") },
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
) !void {
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
                    if (std.mem.eql(u8, input, ":UnsupportedCommand")) config.styles.text_input_err else config.styles.text_input,
                );
            }

            win.hideCursor();
        },
    }
}

fn drawNotification(
    notification: *Notification,
    win: vaxis.Window,
) !void {
    if (notification.len() == 0) return;
    if (notification.clearIfEnded()) return;

    const width_padding = 4;
    const height_padding = 3;
    const screen_pos_padding = 10;

    const max_width = win.width / 4;
    const width = notification.len() + width_padding;
    const calculated_width = if (width > max_width) max_width else width;
    const height = try std.math.divCeil(usize, notification.len(), calculated_width) + height_padding;

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
