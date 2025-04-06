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
    key_press: Key,
    winsize: vaxis.Winsize,
};

const actions_len = 100;

const App = @This();

alloc: std.mem.Allocator,
should_quit: bool,
vx: vaxis.Vaxis = undefined,
tty: vaxis.Tty = undefined,
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
image: ?vaxis.Image = null,
last_known_height: usize,

pub fn init(alloc: std.mem.Allocator) !App {
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

    return App{
        .alloc = alloc,
        .should_quit = false,
        .vx = vx,
        .tty = try vaxis.Tty.init(),
        .directories = try Directories.init(alloc),
        .help_menu = help_menu,
        .text_input = vaxis.widgets.TextInput.init(alloc, &vx.unicode),
        .actions = CircStack(Action, actions_len).init(),
        .last_known_height = vx.window().height,
    };
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
    self.vx.deinit(self.alloc, self.tty.anyWriter());
    self.tty.deinit();
    if (self.file_logger) |file_logger| file_logger.deinit();
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

    var loop: vaxis.Loop(Event) = .{
        .vaxis = &self.vx,
        .tty = &self.tty,
    };
    try loop.start();
    defer loop.stop();

    try self.vx.enterAltScreen(self.tty.anyWriter());
    try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);

    while (!self.should_quit) {
        loop.pollEvent();
        while (loop.tryEvent()) |event| {
            // Global keybinds.
            switch (event) {
                .key_press => |key| {
                    if ((key.codepoint == 'c' and key.mods.ctrl)) {
                        self.should_quit = true;
                        return;
                    }

                    if ((key.codepoint == 'r' and key.mods.ctrl)) {
                        if (config.parse(self.alloc, self)) {
                            self.notification.write("Reloaded configuration file.", .info) catch {};
                        } else |err| switch (err) {
                            error.SyntaxError => {
                                self.notification.write("Encountered a syntax error while parsing the config file.", .err) catch {
                                    std.log.err("Encountered a syntax error while parsing the config file.", .{});
                                };
                            },
                            error.InvalidCharacter => {
                                self.notification.write("One or more overriden keybinds are invalid.", .err) catch {
                                    std.log.err("One or more overriden keybinds are invalid.", .{});
                                };
                            },
                            error.DuplicateKeybind => {
                                // Error logged in function
                            },
                            else => {
                                const message = try std.fmt.allocPrint(self.alloc, "Encountend an unknown error while parsing the config file - {}", .{err});
                                defer self.alloc.free(message);

                                self.notification.write(message, .err) catch {
                                    std.log.err("Encountend an unknown error while parsing the config file - {}", .{err});
                                };
                            },
                        }
                    }
                },
                else => {},
            }

            // State specific keybinds.
            switch (self.state) {
                .normal => {
                    try EventHandlers.handleNormalEvent(self, event, &loop);
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

        var buffered = self.tty.bufferedWriter();
        try self.vx.render(buffered.writer().any());
        try buffered.flush();
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
