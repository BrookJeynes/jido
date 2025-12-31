const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const App = @import("app.zig");
const FileLogger = @import("file_logger.zig");
const vaxis = @import("vaxis");
const config = &@import("./config.zig").config;
const resolvePath = @import("./commands.zig").resolvePath;

pub const panic = vaxis.panic_handler;
const help_menu =
    \\Usage: jido
    \\
    \\a lightweight Unix TUI file explorer
    \\
    \\Flags:
    \\  -h, --help                     Show help information and exit.
    \\  -v, --version                  Print version information and exit.
    \\      --entry-dir=PATH           Open jido at chosen dir.
    \\      --choose-dir               Makes jido act like a directory chooser. When jido
    \\                                 quits, it will write the name of the last visited
    \\                                 directory to STDOUT.
    \\
;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .vaxis, .level = .warn },
        .{ .scope = .vaxis_parser, .level = .warn },
    },
};

const Options = struct {
    help: bool = false,
    version: bool = false,
    @"choose-dir": bool = false,
    @"entry-path": []const u8 = ".",

    fn optKind(a: []const u8) enum { short, long, positional } {
        if (std.mem.startsWith(u8, a, "--")) return .long;
        if (std.mem.startsWith(u8, a, "-")) return .short;
        return .positional;
    }
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

    var last_dir: ?[]const u8 = null;
    var entry_path_buf: [std.fs.max_path_bytes]u8 = undefined;

    var opts = Options{};
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        switch (Options.optKind(arg)) {
            .short => {
                const str = arg[1..];
                for (str) |b| {
                    switch (b) {
                        'v' => opts.version = true,
                        'h' => opts.help = true,
                        else => {
                            std.log.err("Invalid opt: '{c}'", .{b});
                            std.process.exit(1);
                        },
                    }
                }
            },
            .long => {
                var split = std.mem.splitScalar(u8, arg[2..], '=');
                const opt = split.first();
                const val = split.rest();
                if (std.mem.eql(u8, opt, "version")) {
                    opts.version = true;
                } else if (std.mem.eql(u8, opt, "help")) {
                    opts.help = true;
                } else if (std.mem.eql(u8, opt, "choose-dir")) {
                    opts.@"choose-dir" = true;
                } else if (std.mem.eql(u8, opt, "entry-dir")) {
                    const path = if (std.mem.eql(u8, val, "")) "." else val;
                    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
                    defer dir.close();
                    opts.@"entry-path" = resolvePath(&entry_path_buf, path, dir);
                }
            },
            .positional => {
                std.log.err("Invalid opt: '{s}'. Jido does not take positional arguments.", .{arg});
                std.process.exit(1);
            },
        }
    }

    if (opts.help) {
        std.debug.print(help_menu, .{});
        return;
    }

    if (opts.version) {
        std.debug.print("jido v{f}\n", .{options.version});
        return;
    }

    {
        var app = App.init(alloc, opts.@"entry-path") catch {
            vaxis.recover();
            std.process.exit(1);
        };
        defer app.deinit();

        config.parse(alloc, &app) catch |err| switch (err) {
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
                const message = try std.fmt.allocPrint(alloc, "Encountend an unknown error while parsing the config file - {}", .{err});
                defer alloc.free(message);

                app.notification.write(message, .err) catch {
                    std.log.err("Encountend an unknown error while parsing the config file - {}", .{err});
                };
            },
        };

        app.file_logger = if (config.config_dir) |dir| FileLogger.init(dir) else null;

        try app.run();

        if (opts.@"choose-dir") {
            last_dir = alloc.dupe(u8, try app.directories.fullPath(".")) catch null;
        }
    }

    // Must be printed after app has deinit as part of that process clears
    // the screen.
    if (last_dir) |path| {
        var stdout_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        stdout.print("{s}\n", .{path}) catch {};
        stdout.flush() catch {};

        alloc.free(path);
    }
}
