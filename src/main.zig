const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const App = @import("app.zig");
const FileLogger = @import("file_logger.zig");
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

    var args = std.process.args();
    _ = args.skip();
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            std.debug.print("jido v{}\n", .{options.version});
            return;
        }

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: jido
                \\
                \\a lightweight Unix TUI file explorer
                \\
                \\Flags:
                \\  -h, --help                     Show help information and exit.
                \\  -v, --version                  Print version information and exit.
                \\
            , .{});
            return;
        }
    }

    var app = try App.init(alloc);
    defer app.deinit();

    config.parse(alloc, &app) catch |err| switch (err) {
        error.SyntaxError => {
            try app.notification.writeErr(.ConfigSyntaxError);
        },
        error.InvalidCharacter => {
            try app.notification.writeErr(.InvalidKeybind);
        },
        error.DuplicateKeybind => {
            // Error logged in function
        },
        else => {
            try app.notification.writeErr(.ConfigUnknownError);
        },
    };

    app.file_logger = try FileLogger.init(alloc);

    try app.run();
}
