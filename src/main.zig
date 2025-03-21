const std = @import("std");
const builtin = @import("builtin");
const App = @import("app.zig");
const vaxis = @import("vaxis");
const config = &@import("./config.zig").config;

pub const panic = vaxis.panic_handler;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .vaxis, .level = .warn },
        .{ .scope = .vaxis_parser, .level = .warn },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var app = try App.init(alloc);
    defer app.deinit();

    config.parse(alloc) catch |err| switch (err) {
        error.SyntaxError => {
            try app.notification.writeErr(.ConfigSyntaxError);
        },
        error.InvalidCharacter => {
            try app.notification.writeErr(.InvalidKeybind);
        },
        error.DuplicateKeybind => {
            try app.notification.writeErr(.DuplicateKeybinds);
        },
        else => {
            try app.notification.writeErr(.ConfigUnknownError);
        },
    };

    try app.run();
}
