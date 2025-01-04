const std = @import("std");
const builtin = @import("builtin");
const environment = @import("./environment.zig");
const Drawer = @import("./drawer.zig");
const Notification = @import("./notification.zig");
const config = &@import("./config.zig").config;
const List = @import("./list.zig").List;
const Directories = @import("./directories.zig");
const CircStack = @import("./circ_stack.zig").CircularStack;
const zuid = @import("zuid");
const vaxis = @import("vaxis");
const Key = vaxis.Key;
const EventHandlers = @import("./event_handlers.zig");

pub const State = enum {
    normal,
    fuzzy,
    new_dir,
    new_file,
    change_dir,
    rename,
    command,
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

directories: Directories,
notification: Notification,

text_input: vaxis.widgets.TextInput,
text_input_buf: [std.fs.max_path_bytes]u8 = undefined,

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

    var notification = Notification{};
    notification.init();

    return App{
        .alloc = alloc,
        .should_quit = false,
        .vx = vx,
        .tty = try vaxis.Tty.init(),
        .directories = try Directories.init(alloc),
        .text_input = vaxis.widgets.TextInput.init(alloc, &vx.unicode),
        .notification = notification,
        .actions = CircStack(Action, actions_len).init(),
        .last_known_height = vx.window().height,
    };
}

pub fn deinit(self: *App) void {
    for (self.actions.buf[0..self.actions.count]) |action| {
        switch (action) {
            .delete, .rename => |a| {
                self.alloc.free(a.new);
                self.alloc.free(a.old);
            },
        }
    }

    self.directories.deinit();
    self.text_input.deinit();
    self.vx.deinit(self.alloc, self.tty.anyWriter());
    self.tty.deinit();
}

pub fn run(self: *App) !void {
    var drawer = Drawer{};
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
            switch (self.state) {
                .normal => {
                    try EventHandlers.handleNormalEvent(self, event, &loop);
                },
                .fuzzy, .new_file, .new_dir, .rename, .change_dir, .command => {
                    try EventHandlers.handleInputEvent(self, event);
                },
            }
        }

        try drawer.draw(self);

        var buffered = self.tty.bufferedWriter();
        try self.vx.render(buffered.writer().any());
        try buffered.flush();
    }
}
