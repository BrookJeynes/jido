const std = @import("std");
const builtin = @import("builtin");

const vaxis = @import("vaxis");
const Key = vaxis.Key;
const zuid = @import("zuid");

const Archive = @import("./archive.zig");
const CircStack = @import("./circ_stack.zig").CircularStack;
const CommandHistory = @import("./commands.zig").CommandHistory;
const Directories = @import("./directories.zig");
const Drawer = @import("./drawer.zig");
const environment = @import("./environment.zig");
const EventHandlers = @import("./event_handlers.zig");
const FileLogger = @import("./file_logger.zig");
const Image = @import("./image.zig");
const List = @import("./list.zig").List;
const Notification = @import("./notification.zig");
const Preview = @import("./preview.zig");

const config = &@import("./config.zig").config;
const help_menu_items = [_][]const u8{
    "Global:",
    "<CTRL-c>           :Exit.",
    "<CTRL-r>           :Reload config.",
    "",
    "Normal mode:",
    "j / <Down>         :Go down.",
    "k / <Up>           :Go up.",
    "h / <Left> / -     :Go to the parent directory.",
    "l / <Right>        :Open item or change directory.",
    "g                  :Go to the top.",
    "G                  :Go to the bottom.",
    "c                  :Change directory via path. Will enter input mode.",
    "R                  :Rename item. Will enter input mode.",
    "D                  :Delete item.",
    "u                  :Undo delete/rename.",
    "d                  :Create directory. Will enter input mode.",
    "%                  :Create file. Will enter input mode.",
    "/                  :Fuzzy search directory. Will enter input mode.",
    ".                  :Toggle hidden files.",
    ":                  :Allows for Jido commands to be entered. Please refer to the ",
    "                    \"Command mode\" section for available commands. Will enter ",
    "                    input mode.",
    "v                  :Verbose mode. Provides more information about selected entry. ",
    "y                  :Yank selected item.",
    "p                  :Past yanked item.",
    "x                  :Extract archive to `<name>/`",
    "",
    "Input mode:",
    "<Esc>              :Cancel input.",
    "<CR>               :Confirm input.",
    "",
    "Command mode:",
    "<Up> / <Down>      :Cycle previous commands.",
    ":q                 :Exit.",
    ":h                 :View available keybinds. 'q' to return to app.",
    ":config            :Navigate to config directory if it exists.",
    ":trash             :Navigate to trash directory if it exists.",
    ":empty_trash       :Empty trash if it exists. This action cannot be undone.",
    ":cd <path>         :Change directory via path. Will enter input mode.",
    ":extract           :Extract archive under cursor.",
};

pub const State = enum {
    normal,
    fuzzy,
    new_dir,
    new_file,
    change_dir,
    rename,
    command,
    help_menu,
};

pub const Action = union(enum) {
    delete: struct { prev_path: []const u8, new_path: []const u8 },
    rename: struct { prev_path: []const u8, new_path: []const u8 },
    paste: []const u8,
};

pub const Event = union(enum) {
    image_ready,
    notification,
    key_press: Key,
    winsize: vaxis.Winsize,
};

const actions_len = 100;
const image_cache_cap = 100;

const App = @This();

io: std.Io,
env_map: *std.process.Environ.Map,
alloc: std.mem.Allocator,
should_quit: bool,
vx: vaxis.Vaxis = undefined,
tty_buffer: [1024]u8 = undefined,
tty: vaxis.Tty = undefined,
loop: vaxis.Loop(Event) = undefined,
state: State = .normal,
actions: CircStack(Action, actions_len),
command_history: CommandHistory = CommandHistory{},
drawer: Drawer = Drawer{},

help_menu: List([]const u8),
directories: Directories,
archive_files: ?Archive.ArchiveContents = null,
notification: Notification = Notification{},
file_logger: ?FileLogger = null,

text_input: vaxis.widgets.TextInput,
text_input_buf: [std.fs.max_path_bytes]u8 = undefined,

yanked: ?struct { dir: []const u8, entry: struct { kind: std.Io.File.Kind, name: []const u8 } } = null,
last_known_height: usize,

// Used to detect whether to re-render an image.
current_item_path_buf: [std.fs.max_path_bytes]u8 = undefined,
current_item_path: []u8 = "",
last_item_path_buf: [std.fs.max_path_bytes]u8 = undefined,
last_item_path: []u8 = "",

images: Image.Cache,
preview_cache: Preview.PreviewCache,

pub fn init(io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map, entry_dir: ?[]const u8) !App {
    var vx = try vaxis.init(io, alloc, env_map, .{
        .kitty_keyboard_flags = .{
            .report_text = false,
            .disambiguate = false,
            .report_events = false,
            .report_alternate_keys = false,
            .report_all_as_ctl_seqs = false,
        },
    });

    var help_menu = List([]const u8).init(alloc);
    try help_menu.fromArray(&help_menu_items);

    var app: App = .{
        .io = io,
        .env_map = env_map,
        .alloc = alloc,
        .should_quit = false,
        .vx = vx,
        .directories = try Directories.init(io, alloc, entry_dir),
        .help_menu = help_menu,
        .text_input = vaxis.widgets.TextInput.init(alloc),
        .actions = CircStack(Action, actions_len).init(),
        .last_known_height = vx.window().height,
        .images = .{ .cache = .init(alloc) },
        .preview_cache = Preview.PreviewCache.init(alloc),
    };
    app.tty = try vaxis.Tty.init(io, &app.tty_buffer);
    app.loop = vaxis.Loop(Event).init(io, &app.tty, &app.vx);
    app.notification.io = io;

    return app;
}

pub fn deinit(self: *App) void {
    while (self.actions.pop()) |action| {
        switch (action) {
            .delete => |a| {
                self.alloc.free(a.new_path);
                self.alloc.free(a.prev_path);
            },
            .rename => |a| {
                self.alloc.free(a.new_path);
                self.alloc.free(a.prev_path);
            },
            .paste => |a| self.alloc.free(a),
        }
    }

    if (self.yanked) |yanked| {
        self.alloc.free(yanked.dir);
        self.alloc.free(yanked.entry.name);
    }

    self.command_history.deinit(self.alloc);

    self.help_menu.deinit();
    self.directories.deinit();
    self.text_input.deinit();
    self.vx.deinit(self.alloc, self.tty.writer());
    self.tty.deinit();
    if (self.file_logger) |file_logger| file_logger.deinit();
    if (self.archive_files) |*archive_files| archive_files.deinit(self.alloc);

    var image_iter = self.images.cache.iterator();
    while (image_iter.next()) |img| {
        img.value_ptr.deinit(self.alloc, self.vx, &self.tty);
    }
    self.images.cache.deinit();
    self.preview_cache.deinit();
}

/// Reads the current text input without consuming it.
/// The returned slice is valid until the next call to readInput() or until
/// the text_input buffer is modified.
pub fn readInput(self: *App) []const u8 {
    const first = self.text_input.buf.firstHalf();
    const second = self.text_input.buf.secondHalf();
    var dest_idx: usize = 0;

    const first_len = @min(first.len, self.text_input_buf.len - dest_idx);
    @memcpy(self.text_input_buf[dest_idx .. dest_idx + first_len], first[0..first_len]);
    dest_idx += first_len;

    const second_len = @min(second.len, self.text_input_buf.len - dest_idx);
    @memcpy(self.text_input_buf[dest_idx .. dest_idx + second_len], second[0..second_len]);
    dest_idx += second_len;

    return self.text_input_buf[0..dest_idx];
}

pub fn repopulateDirectory(self: *App, fuzzy: []const u8) error{OutOfMemory}!void {
    // Save current selection name to restore cursor position after repopulation
    const prev_name = if (self.directories.getSelected() catch null) |entry|
        try self.alloc.dupe(u8, entry.name)
    else
        null;
    defer if (prev_name) |name| self.alloc.free(name);

    self.directories.clearEntries();
    self.directories.populateEntries(fuzzy) catch |err| {
        const message = try std.fmt.allocPrint(self.alloc, "Failed to read directory entries - {}.", .{err});
        defer self.alloc.free(message);
        self.notification.write(message, .err) catch {};
        if (self.file_logger) |file_logger| file_logger.write(message, .err) catch {};
    };

    // Try to restore cursor to the same file by name
    if (prev_name) |name| {
        for (self.directories.entries.all(), 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                self.directories.entries.selected = i;
                break;
            }
        }
    }

    // Revalidate current entry for display
    self.preview_cache.invalidate();
    Preview.loadPreviewForCurrentEntry(self) catch |err| {
        if (self.file_logger) |file_logger| {
            const msg = std.fmt.allocPrint(self.alloc, "Failed to load preview after repopulate: {}", .{err}) catch return;
            defer self.alloc.free(msg);
            file_logger.write(msg, .err) catch {};
        }
    };
}

pub fn run(self: *App) !void {
    try self.repopulateDirectory("");
    try self.loop.start();
    defer self.loop.stop();

    try self.vx.enterAltScreen(self.tty.writer());
    try self.vx.queryTerminal(self.tty.writer(), std.Io.Duration.fromSeconds(1));
    self.vx.caps.kitty_graphics = true;

    while (!self.should_quit) {
        try self.loop.pollEvent();
        while (try self.loop.tryEvent()) |event| {
            const selected = self.directories.getSelected() catch |err| err: {
                const message = try std.fmt.allocPrint(self.alloc, "Can not display file - {}", .{err});
                defer self.alloc.free(message);
                self.notification.write(message, .err) catch {};
                if (self.file_logger) |file_logger| file_logger.write(message, .err) catch {};
                break :err null;
            };

            if (selected) |entry| err: {
                @memcpy(&self.last_item_path_buf, &self.current_item_path_buf);
                self.last_item_path = self.last_item_path_buf[0..self.current_item_path.len];
                self.current_item_path = try std.fmt.bufPrint(
                    &self.current_item_path_buf,
                    "{s}/{s}",
                    .{ self.directories.fullPath(".") catch {
                        const message = try std.fmt.allocPrint(self.alloc, "Can not display file - unable to retrieve directory path.", .{});
                        defer self.alloc.free(message);
                        self.notification.write(message, .err) catch {};
                        if (self.file_logger) |file_logger| file_logger.write(message, .err) catch {};
                        break :err;
                    }, entry.name },
                );
            }

            // Global keybinds.
            try EventHandlers.handleGlobalEvent(self, event);

            // State specific keybinds.
            switch (self.state) {
                .normal => {
                    try EventHandlers.handleNormalEvent(self, event);
                },
                .help_menu => {
                    try EventHandlers.handleHelpMenuEvent(self, event);
                },
                else => {
                    try EventHandlers.handleInputEvent(self, event);
                },
            }
        }

        try self.drawer.draw(self);

        const writer = self.tty.writer();
        try self.vx.render(writer);
        try writer.flush();
    }

    if (config.empty_trash_on_exit) {
        var trash_dir = dir: {
            notfound: {
                break :dir (config.trashDir(self.io) catch break :notfound) orelse break :notfound;
            }
            if (self.file_logger) |file_logger| file_logger.write("Failed to open trash directory.", .err) catch {
                std.log.err("Failed to open trash directory.", .{});
            };
            return;
        };
        defer trash_dir.close(self.io);

        const failed = environment.deleteContents(self.io, trash_dir) catch |err| {
            const message = try std.fmt.allocPrint(self.alloc, "Failed to empty trash - {}.", .{err});
            defer self.alloc.free(message);
            if (self.file_logger) |file_logger| file_logger.write(message, .err) catch {
                std.log.err("Failed to empty trash - {}.", .{err});
            };
            return;
        };
        if (failed > 0) {
            const message = try std.fmt.allocPrint(self.alloc, "Failed to empty {d} items from the trash.", .{failed});
            defer self.alloc.free(message);
            if (self.file_logger) |file_logger| file_logger.write(message, .err) catch {
                std.log.err("Failed to empty {d} items from the trash.", .{failed});
            };
        }
    }
}
