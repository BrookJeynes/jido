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

const ActionPaths = struct {
    /// Allocated.
    old: []const u8,
    /// Allocated.
    new: []const u8,
};

pub const Action = union(enum) {
    delete: ActionPaths,
    rename: ActionPaths,
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
// Assigned in main after config parsing.
file_logger: FileLogger = undefined,

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
            .delete, .rename => |a| {
                self.alloc.free(a.new);
                self.alloc.free(a.old);
            },
            .paste => |a| self.alloc.free(a),
        }
    }

    if (self.yanked) |yanked| {
        self.alloc.free(yanked.dir);
        self.alloc.free(yanked.entry.name);
    }

    self.command_history.resetSelected();
    while (self.command_history.next()) |command| {
        self.alloc.free(command);
    }

    self.help_menu.deinit();
    self.directories.deinit();
    self.text_input.deinit();
    self.vx.deinit(self.alloc, self.tty.anyWriter());
    self.tty.deinit();
    self.file_logger.deinit();
}

pub fn run(self: *App) !void {
    try self.directories.populateEntries("");

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
                            try self.notification.writeInfo(.ConfigReloaded);
                        } else |err| switch (err) {
                            error.SyntaxError => {
                                try self.notification.writeErr(.ConfigSyntaxError);
                            },
                            error.InvalidCharacter => {
                                try self.notification.writeErr(.InvalidKeybind);
                            },
                            error.DuplicateKeybind => {
                                // Error logged in function
                            },
                            else => {
                                try self.notification.writeErr(.ConfigUnknownError);
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
        if (try config.trashDir()) |dir| {
            var trash_dir = dir;
            defer trash_dir.close();
            _ = try environment.deleteContents(trash_dir);
        }
    }
}
