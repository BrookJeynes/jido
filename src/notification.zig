const std = @import("std");

const Self = @This();

/// Seconds.
pub const notification_timeout = 3;

const Style = enum {
    err,
    info,
    warn,
};

const Error = enum {
    PermissionDenied,
    UnknownError,
    UnableToUndo,
    UnableToOpenFile,
    UnableToDelete,
    FailedToDeleteSomeItems,
    UnableToDeleteAcrossMountPoints,
    UnsupportedImageFormat,
    EditorNotSet,
    ItemAlreadyExists,
    UnableToRename,
    IncorrectPath,
    ConfigSyntaxError,
    ConfigUnknownError,
    ConfigPathNotFound,
    CannotDeleteTrashDir,
    DuplicateKeybinds,
    InvalidKeybind,
    NotADir,
};

const Info = enum {
    CreatedFile,
    CreatedFolder,
    Deleted,
    Renamed,
    RestoredDelete,
    RestoredRename,
    EmptyUndo,
    ChangedDir,
    ConfigReloaded,
};

const Warn = enum { DeprecatedConfigPath, DuplicateFileOnUndo };

buf: [1024]u8 = undefined,
style: Style = Style.info,
fbs: std.io.FixedBufferStream([]u8) = undefined,
/// How long until the notification disappears in seconds.
timer: i64 = 0,

pub fn init(self: *Self) void {
    self.fbs = std.io.fixedBufferStream(&self.buf);
    self.timer = std.time.timestamp();
}

pub fn write(self: *Self, text: []const u8, style: Style) !void {
    self.fbs.reset();
    _ = try self.fbs.write(text);
    self.timer = std.time.timestamp();
    self.style = style;
}

pub fn writeErr(self: *Self, err: Error) !void {
    try switch (err) {
        .PermissionDenied => self.write("Permission denied.", .err),
        .UnknownError => self.write("An unknown error occurred.", .err),
        .UnableToOpenFile => self.write("Unable to open file.", .err),
        .UnableToDelete => self.write("Unable to delete item.", .err),
        .FailedToDeleteSomeItems => self.write("Failed to delete some items..", .err),
        .UnableToDeleteAcrossMountPoints => self.write("Unable to move item to /tmp. Failed to delete.", .err),
        .UnableToUndo => self.write("Unable to undo previous action.", .err),
        .ItemAlreadyExists => self.write("Item already exists.", .err),
        .UnableToRename => self.write("Unable to rename item.", .err),
        .IncorrectPath => self.write("Unable to find path.", .err),
        .NotADir => self.write("Path is not a directory.", .err),
        .EditorNotSet => self.write("$EDITOR is not set.", .err),
        .UnsupportedImageFormat => self.write("Unsupported image format.", .err),
        .ConfigSyntaxError => self.write("Could not read config due to a syntax error.", .err),
        .ConfigUnknownError => self.write("Could not read config due to an unknown error.", .err),
        .ConfigPathNotFound => self.write("Could not read config due to unset env variables. Please set either $HOME or $XDG_CONFIG_HOME.", .err),
        .CannotDeleteTrashDir => self.write("Cannot delete trash directory.", .err),
        .DuplicateKeybinds => self.write("Config has keybinds with the same key. This can lead to undefined behaviour. Check log file for more information.", .err),
        .InvalidKeybind => self.write("Config has keybind(s) with invalid key(s).", .err),
    };
}

pub fn writeInfo(self: *Self, info: Info) !void {
    try switch (info) {
        .CreatedFile => self.write("Successfully created file.", .info),
        .CreatedFolder => self.write("Successfully created folder.", .info),
        .Deleted => self.write("Successfully deleted item.", .info),
        .Renamed => self.write("Successfully renamed item.", .info),
        .RestoredDelete => self.write("Successfully restored deleted item.", .info),
        .RestoredRename => self.write("Successfully restored renamed item.", .info),
        .EmptyUndo => self.write("Nothing to undo.", .info),
        .ChangedDir => self.write("Successfully changed directory.", .info),
        .ConfigReloaded => self.write("Successfully reloaded config.", .info),
    };
}

pub fn writeWarn(self: *Self, warning: Warn) !void {
    try switch (warning) {
        .DeprecatedConfigPath => self.write("You are using a deprecated config path. Please move your config to either `$XDG_CONFIG_HOME/jido` or `$HOME/.jido`", .warn),
        .DuplicateFileOnUndo => self.write("A file with the same name already exists. A unique identifier has been appending to the duplicated item.", .warn),
    };
}

pub fn reset(self: *Self) void {
    self.fbs.reset();
    self.style = Style.info;
}

pub fn slice(self: *Self) []const u8 {
    return self.fbs.getWritten();
}

pub fn clearIfEnded(self: *Self) bool {
    if (std.time.timestamp() - self.timer > notification_timeout) {
        self.reset();
        return true;
    }

    return false;
}

pub fn len(self: Self) usize {
    return self.fbs.pos;
}
