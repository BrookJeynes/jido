const std = @import("std");
const builtin = @import("builtin");
const environment = @import("./environment.zig");
const vaxis = @import("vaxis");
const FileLogger = @import("file_logger.zig");
const Notification = @import("./notification.zig");
const App = @import("./app.zig");

const CONFIG_NAME = "config.json";
const TRASH_DIR_NAME = "trash";
const HOME_DIR_NAME = ".jido";
const XDG_CONFIG_HOME_DIR_NAME = "jido";

const Config = struct {
    show_hidden: bool = true,
    sort_dirs: bool = true,
    show_images: bool = true,
    preview_file: bool = true,
    empty_trash_on_exit: bool = false,
    true_dir_size: bool = false,
    // TODO(10-01-25): This needs to be implemented.
    // command_history_len: usize = 10,
    styles: Styles = .{},
    keybinds: Keybinds = .{},

    config_dir: ?std.fs.Dir = null,

    ///Returned dir needs to be closed by user.
    pub fn configDir(self: Config) !?std.fs.Dir {
        if (self.config_dir) |dir| {
            return try dir.openDir(".", .{ .iterate = true });
        } else return null;
    }

    ///Returned dir needs to be closed by user.
    pub fn trashDir(self: Config) !?std.fs.Dir {
        var parent = try self.configDir() orelse return null;
        defer parent.close();
        if (!environment.dirExists(parent, TRASH_DIR_NAME)) {
            try parent.makeDir(TRASH_DIR_NAME);
        }

        return try parent.openDir(TRASH_DIR_NAME, .{ .iterate = true });
    }

    pub fn parse(self: *Config, alloc: std.mem.Allocator, app: *App) !void {
        var dir = lbl: {
            if (try environment.getXdgConfigHomeDir()) |home_dir| {
                defer {
                    var dir = home_dir;
                    dir.close();
                }

                if (!environment.dirExists(home_dir, XDG_CONFIG_HOME_DIR_NAME)) {
                    try home_dir.makeDir(XDG_CONFIG_HOME_DIR_NAME);
                }

                const jido_dir = try home_dir.openDir(
                    XDG_CONFIG_HOME_DIR_NAME,
                    .{ .iterate = true },
                );
                self.config_dir = jido_dir;

                if (environment.fileExists(jido_dir, CONFIG_NAME)) {
                    break :lbl jido_dir;
                }
                return;
            }

            if (try environment.getHomeDir()) |home_dir| {
                defer {
                    var dir = home_dir;
                    dir.close();
                }

                if (!environment.dirExists(home_dir, HOME_DIR_NAME)) {
                    try home_dir.makeDir(HOME_DIR_NAME);
                }

                const jido_dir = try home_dir.openDir(
                    HOME_DIR_NAME,
                    .{ .iterate = true },
                );
                self.config_dir = jido_dir;

                if (environment.fileExists(jido_dir, CONFIG_NAME)) {
                    break :lbl jido_dir;
                }
                return;
            }

            return;
        };

        const config_file = try dir.openFile(CONFIG_NAME, .{});
        defer config_file.close();

        const config_str = try config_file.readToEndAlloc(alloc, 1024 * 1024 * 1024);
        defer alloc.free(config_str);

        const parsed_config = try std.json.parseFromSlice(Config, alloc, config_str, .{});
        defer parsed_config.deinit();

        self.* = parsed_config.value;
        self.config_dir = dir;

        // Check duplicate keybinds
        {
            var file_logger = try FileLogger.init(alloc);
            defer file_logger.deinit();

            var key_map = std.AutoHashMap(u21, []const u8).init(alloc);
            defer {
                var it = key_map.iterator();
                while (it.next()) |entry| {
                    alloc.free(entry.value_ptr.*);
                }
                key_map.deinit();
            }

            inline for (std.meta.fields(Keybinds)) |field| {
                const codepoint = @intFromEnum(@field(self.keybinds, field.name));

                const res = try key_map.getOrPut(codepoint);
                if (res.found_existing) {
                    var keybind_str: [1024]u8 = undefined;
                    const keybind_str_bytes = try std.unicode.utf8Encode(codepoint, &keybind_str);

                    const message = try std.fmt.allocPrint(
                        alloc,
                        "'{s}' and '{s}' have the same keybind: '{s}'",
                        .{ res.value_ptr.*, field.name, keybind_str[0..keybind_str_bytes] },
                    );
                    defer alloc.free(message);

                    try app.notification.write(message, .err);
                    file_logger.write(message, .err) catch {};

                    return error.DuplicateKeybind;
                }
                res.value_ptr.* = try alloc.dupe(u8, field.name);
            }
        }

        return;
    }
};

const Colours = struct {
    const RGB = [3]u8;
    const red: RGB = .{ 227, 23, 10 };
    const orange: RGB = .{ 251, 139, 36 };
    const blue: RGB = .{ 82, 209, 220 };
    const grey: RGB = .{ 39, 39, 39 };
    const black: RGB = .{ 0, 0, 0 };
    const snow_white: RGB = .{ 254, 252, 253 };
};

const NotificationStyles = struct {
    box: vaxis.Style = vaxis.Style{
        .fg = .{ .rgb = Colours.snow_white },
        .bg = .{ .rgb = Colours.grey },
    },
    err: vaxis.Style = vaxis.Style{
        .fg = .{ .rgb = Colours.red },
        .bg = .{ .rgb = Colours.grey },
    },
    warn: vaxis.Style = vaxis.Style{
        .fg = .{ .rgb = Colours.orange },
        .bg = .{ .rgb = Colours.grey },
    },
    info: vaxis.Style = vaxis.Style{
        .fg = .{ .rgb = Colours.blue },
        .bg = .{ .rgb = Colours.grey },
    },
};

pub const Keybinds = struct {
    pub const Char = enum(u21) {
        _,
        pub fn jsonParse(alloc: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const parsed = try std.json.innerParse([]const u8, alloc, source, options);
            if (std.mem.eql(u8, parsed, "")) return error.InvalidCharacter;
            const unicode = std.unicode.utf8Decode(parsed) catch return error.InvalidCharacter;
            return @enumFromInt(unicode);
        }
    };

    toggle_hidden_files: Char = @enumFromInt('.'),
    delete: Char = @enumFromInt('D'),
    rename: Char = @enumFromInt('R'),
    create_dir: Char = @enumFromInt('d'),
    create_file: Char = @enumFromInt('%'),
    fuzzy_find: Char = @enumFromInt('/'),
    change_dir: Char = @enumFromInt('c'),
    enter_command_mode: Char = @enumFromInt(':'),
    jump_top: Char = @enumFromInt('g'),
    jump_bottom: Char = @enumFromInt('G'),
    toggle_verbose_file_information: Char = @enumFromInt('v'),
};

const Styles = struct {
    selected_list_item: vaxis.Style = vaxis.Style{
        .bg = .{ .rgb = Colours.grey },
        .bold = true,
    },
    notification: NotificationStyles = NotificationStyles{},
    text_input: vaxis.Style = vaxis.Style{},
    text_input_err: vaxis.Style = vaxis.Style{ .bg = .{ .rgb = Colours.red } },
    list_item: vaxis.Style = vaxis.Style{},
    file_name: vaxis.Style = vaxis.Style{},
    file_information: vaxis.Style = vaxis.Style{
        .fg = .{ .rgb = Colours.black },
        .bg = .{ .rgb = Colours.snow_white },
    },
    git_branch: vaxis.Style = vaxis.Style{
        .fg = .{ .rgb = Colours.blue },
    },
};

pub var config: Config = Config{};
