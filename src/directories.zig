const std = @import("std");

const fuzzig = @import("fuzzig");

const CircStack = @import("./circ_stack.zig").CircularStack;
const List = @import("./list.zig").List;

const sort = &@import("./sort.zig");
const config = &@import("./config.zig").config;
const history_len: usize = 100;

const Self = @This();

io: std.Io,
alloc: std.mem.Allocator,
dir: std.Io.Dir,
path_buf: [std.fs.max_path_bytes]u8 = undefined,
file: struct {
    handle: ?std.Io.File = null,
    data: [4096]u8 = undefined,
    bytes_read: usize = 0,
} = .{},
pdf_contents: ?[]u8 = null,
entries: List(std.Io.Dir.Entry),
history: CircStack(usize, history_len),
child_entries: List([]const u8),
searcher: fuzzig.Ascii,

pub fn init(io: std.Io, alloc: std.mem.Allocator, entry_dir: ?[]const u8) !Self {
    const dir_path = if (entry_dir) |dir| dir else ".";
    const dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.log.err("path '{s}' could not be found.", .{dir_path});
                return err;
            },
            else => {
                std.log.err("{}", .{err});
                return err;
            },
        }
    };

    return Self{
        .io = io,
        .alloc = alloc,
        .dir = dir,
        .entries = List(std.Io.Dir.Entry).init(alloc),
        .history = CircStack(usize, history_len).init(),
        .child_entries = List([]const u8).init(alloc),
        .searcher = try fuzzig.Ascii.init(
            alloc,
            std.fs.max_path_bytes,
            std.fs.max_path_bytes,
            .{ .case_sensitive = false },
        ),
    };
}

pub fn deinit(self: *Self) void {
    self.clearEntries();
    self.clearChildEntries();

    self.entries.deinit();
    self.child_entries.deinit();

    self.dir.close(self.io);
    self.searcher.deinit();

    if (self.pdf_contents) |contents| self.alloc.free(contents);
}

pub fn getSelected(self: *Self) !?std.Io.Dir.Entry {
    return self.entries.getSelected();
}

/// Asserts there is a selected item.
pub fn removeSelected(self: *Self) void {
    const entry = lbl: {
        const entry = self.getSelected() catch return std.debug.assert(false);
        if (entry) |e| break :lbl e else return std.debug.assert(false);
    };
    self.alloc.free(entry.name);
    _ = self.entries.items.orderedRemove(self.entries.selected);
}

pub fn fullPath(self: *Self, relative_path: []const u8) ![]const u8 {
    const len = try self.dir.realPathFile(self.io, relative_path, &self.path_buf);
    return self.path_buf[0..len];
}

pub fn getDirSize(self: Self, dir: std.Io.Dir) !usize {
    var total_size: usize = 0;

    var walker = try dir.walk(self.alloc);
    defer walker.deinit();

    while (try walker.next(self.io)) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = try entry.dir.statFile(self.io, entry.basename, .{});
                total_size += stat.size;
            },
            else => {},
        }
    }

    return total_size;
}

pub fn populateChildEntries(
    self: *Self,
    relative_path: []const u8,
) !void {
    var dir = try self.dir.openDir(self.io, relative_path, .{ .iterate = true });
    defer dir.close(self.io);

    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".") and config.show_hidden == false) {
            continue;
        }

        if (entry.kind == .directory) {
            try self.child_entries.append(try std.fmt.allocPrint(self.alloc, "{s}/", .{entry.name}));
        } else {
            try self.child_entries.append(try self.alloc.dupe(u8, entry.name));
        }
    }

    if (config.sort_dirs == true) {
        std.mem.sort([]const u8, self.child_entries.all(), {}, sort.string);
    }
}

pub fn populateEntries(self: *Self, fuzzy_search: []const u8) !void {
    var it = self.dir.iterate();
    while (try it.next(self.io)) |entry| {
        const score = self.searcher.score(entry.name, fuzzy_search) orelse 0;
        if (fuzzy_search.len > 0 and score < 1) {
            continue;
        }

        if (std.mem.startsWith(u8, entry.name, ".") and config.show_hidden == false) {
            continue;
        }

        try self.entries.append(.{
            .kind = entry.kind,
            .inode = entry.inode,
            .name = if (entry.kind == .directory) try std.fmt.allocPrint(self.alloc, "{s}/", .{entry.name}) else try self.alloc.dupe(u8, entry.name),
        });
    }

    if (config.sort_dirs == true) {
        std.mem.sort(std.Io.Dir.Entry, self.entries.all(), {}, sort.sortDirectoryEntry);
    }
}

pub fn clearEntries(self: *Self) void {
    for (self.entries.all()) |entry| {
        self.entries.alloc.free(entry.name);
    }
    self.entries.clear();
}

pub fn clearChildEntries(self: *Self) void {
    for (self.child_entries.all()) |entry| {
        self.child_entries.alloc.free(entry);
    }
    self.child_entries.clear();
}

const testing = std.testing;

test "Directories: populateEntries respects show_hidden config" {
    const local_config = &@import("./config.zig").config;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var visible = try tmp.dir.createFile(io, "visible.txt", .{});
        visible.close(io);
        var hidden = try tmp.dir.createFile(io, ".hidden.txt", .{});
        hidden.close(io);
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const iter_dir = try std.Io.Dir.openDirAbsolute(io, path_buf[0..tmp_path_len], .{ .iterate = true });

    var dirs = try Self.init(io, testing.allocator, null);
    defer {
        dirs.clearEntries();
        dirs.clearChildEntries();
        dirs.entries.deinit();
        dirs.child_entries.deinit();
        dirs.searcher.deinit();
    }
    dirs.dir.close(io);
    dirs.dir = iter_dir;

    local_config.show_hidden = false;
    try dirs.populateEntries("");
    try testing.expectEqual(@as(usize, 1), dirs.entries.len());

    dirs.clearEntries();
    local_config.show_hidden = true;
    try dirs.populateEntries("");
    try testing.expectEqual(@as(usize, 2), dirs.entries.len());
}

test "Directories: fuzzy search filters entries" {
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var f1 = try tmp.dir.createFile(io, "test_file.txt", .{});
        f1.close(io);
        var f2 = try tmp.dir.createFile(io, "other.txt", .{});
        f2.close(io);
        var f3 = try tmp.dir.createFile(io, "test_another.txt", .{});
        f3.close(io);
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const iter_dir = try std.Io.Dir.openDirAbsolute(io, path_buf[0..tmp_path_len], .{ .iterate = true });

    var dirs = try Self.init(io, testing.allocator, null);
    defer {
        dirs.clearEntries();
        dirs.clearChildEntries();
        dirs.entries.deinit();
        dirs.child_entries.deinit();
        dirs.searcher.deinit();
    }
    dirs.dir.close(io);
    dirs.dir = iter_dir;

    try dirs.populateEntries("test");
    // Should match test_*
    try testing.expect(dirs.entries.len() >= 2);

    // Verify all entries contain "test"
    for (dirs.entries.all()) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, "test") != null);
    }
}

test "Directories: fullPath resolves relative paths" {
    const io = testing.io;
    var dirs = try Self.init(io, testing.allocator, ".");
    defer dirs.deinit();

    const path = try dirs.fullPath(".");
    try testing.expect(path.len > 0);
    // Should be absolute
    try testing.expect(std.mem.indexOf(u8, path, "/") != null);
}
