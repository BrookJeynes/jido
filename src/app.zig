const std = @import("std");
const builtin = @import("builtin");
const environment = @import("./environment.zig");
const Drawer = @import("./drawer.zig");
const Notification = @import("./notification.zig");
const config = &@import("./config.zig").config;
const List = @import("./list.zig").List;
const Directories = @import("./directories.zig");
const FileLogger = @import("./file_logger.zig");
const CircStack = @import("./circ_stack.zig").CircularStack;
const zuid = @import("zuid");
const vaxis = @import("vaxis");
const Key = vaxis.Key;
const EventHandlers = @import("./event_handlers.zig");
const CommandHistory = @import("./commands.zig").CommandHistory;

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

pub const Image = struct {
    const Status = enum {
        ready,
        processing,
        failed,
    };

    ///Only use on first transmission. Subsequent draws should use
    ///`Image.image`.
    data: ?vaxis.zigimg.Image = null,
    image: ?vaxis.Image = null,
    path: ?[]const u8 = null,
    status: Status = .processing,

    pub fn deinit(self: @This(), alloc: std.mem.Allocator, vx: vaxis.Vaxis, tty: *vaxis.Tty) void {
        if (self.image) |image| {
            vx.freeImage(tty.writer(), image.id);
        }
        if (self.data) |data| {
            var d = data;
            d.deinit(alloc);
        }
        if (self.path) |path| alloc.free(path);
    }
};

const actions_len = 100;
const image_cache_cap = 100;

const App = @This();

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
notification: Notification = Notification{},
file_logger: ?FileLogger = null,

text_input: vaxis.widgets.TextInput,
text_input_buf: [std.fs.max_path_bytes]u8 = undefined,

yanked: ?struct { dir: []const u8, entry: std.fs.Dir.Entry } = null,
last_known_height: usize,

images: struct {
    mutex: std.Thread.Mutex = .{},
    cache: std.StringHashMap(Image),
},

pub fn init(alloc: std.mem.Allocator, entry_dir: ?[]const u8) !App {
    var vx = try vaxis.init(alloc, .{
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
        .alloc = alloc,
        .should_quit = false,
        .vx = vx,
        .directories = try Directories.init(alloc, entry_dir),
        .help_menu = help_menu,
        .text_input = vaxis.widgets.TextInput.init(alloc),
        .actions = CircStack(Action, actions_len).init(),
        .last_known_height = vx.window().height,
        .images = .{ .cache = .init(alloc) },
    };
    app.tty = try vaxis.Tty.init(&app.tty_buffer);
    app.loop = vaxis.Loop(Event){
        .vaxis = &app.vx,
        .tty = &app.tty,
    };

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

    var image_iter = self.images.cache.iterator();
    while (image_iter.next()) |img| {
        img.value_ptr.deinit(self.alloc, self.vx, &self.tty);
    }
    self.images.cache.deinit();
}

pub fn inputToSlice(self: *App) []const u8 {
    self.text_input.buf.cursor = self.text_input.buf.realLength();
    return self.text_input.sliceToCursor(&self.text_input_buf);
}

pub fn repopulateDirectory(self: *App, fuzzy: []const u8) error{OutOfMemory}!void {
    self.directories.clearEntries();
    self.directories.populateEntries(fuzzy) catch |err| {
        const message = try std.fmt.allocPrint(self.alloc, "Failed to read directory entries - {}.", .{err});
        defer self.alloc.free(message);
        self.notification.write(message, .err) catch {};
        if (self.file_logger) |file_logger| file_logger.write(message, .err) catch {};
    };
}

pub fn run(self: *App) !void {
    try self.repopulateDirectory("");
    try self.loop.start();
    defer self.loop.stop();

    try self.vx.enterAltScreen(self.tty.writer());
    try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);
    self.vx.caps.kitty_graphics = true;

    while (!self.should_quit) {
        self.loop.pollEvent();
        while (self.loop.tryEvent()) |event| {
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

        try self.vx.render(self.tty.writer());
    }

    if (config.empty_trash_on_exit) {
        var trash_dir = dir: {
            notfound: {
                break :dir (config.trashDir() catch break :notfound) orelse break :notfound;
            }
            if (self.file_logger) |file_logger| file_logger.write("Failed to open trash directory.", .err) catch {
                std.log.err("Failed to open trash directory.", .{});
            };
            return;
        };
        defer trash_dir.close();

        const failed = environment.deleteContents(trash_dir) catch |err| {
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
