const std = @import("std");
const List = @import("./list.zig").List;
const CircStack = @import("./circ_stack.zig").CircularStack;
const config = &@import("./config.zig").config;
const fuzzig = @import("fuzzig");

const history_len: usize = 100;

const Self = @This();

alloc: std.mem.Allocator,
dir: std.fs.Dir,
path_buf: [std.fs.max_path_bytes]u8 = undefined,
file_contents: [4096]u8 = undefined,
pdf_contents: ?[]u8 = null,
entries: List(std.fs.Dir.Entry),
history: CircStack(usize, history_len),
child_entries: List([]const u8),
searcher: fuzzig.Ascii,

pub fn init(alloc: std.mem.Allocator, entry_dir: ?[]const u8) !Self {
    const dir_path = if (entry_dir) |dir| dir else ".";
    const dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
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
        .alloc = alloc,
        .dir = dir,
        .entries = List(std.fs.Dir.Entry).init(alloc),
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

    self.dir.close();
    self.searcher.deinit();

    if (self.pdf_contents) |contents| self.alloc.free(contents);
}

pub fn getSelected(self: *Self) !?std.fs.Dir.Entry {
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
    return try self.dir.realpath(relative_path, &self.path_buf);
}

pub fn getDirSize(self: Self, dir: std.fs.Dir) !usize {
    var total_size: usize = 0;

    var walker = try dir.walk(self.alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = try entry.dir.statFile(entry.basename);
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
    var dir = try self.dir.openDir(relative_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".") and config.show_hidden == false) {
            continue;
        }

        try self.child_entries.append(try self.alloc.dupe(u8, entry.name));
    }

    if (config.sort_dirs == true) {
        std.mem.sort([]const u8, self.child_entries.all(), {}, sortChildEntry);
    }
}

pub fn populateEntries(self: *Self, fuzzy_search: []const u8) !void {
    var it = self.dir.iterate();
    while (try it.next()) |entry| {
        const score = self.searcher.score(entry.name, fuzzy_search) orelse 0;
        if (fuzzy_search.len > 0 and score < 1) {
            continue;
        }

        if (std.mem.startsWith(u8, entry.name, ".") and config.show_hidden == false) {
            continue;
        }

        try self.entries.append(.{
            .kind = entry.kind,
            .name = try self.alloc.dupe(u8, entry.name),
        });
    }

    if (config.sort_dirs == true) {
        std.mem.sort(std.fs.Dir.Entry, self.entries.all(), {}, sortEntry);
    }
}

fn sortEntry(_: void, lhs: std.fs.Dir.Entry, rhs: std.fs.Dir.Entry) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn sortChildEntry(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
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

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const visible = try tmp.dir.createFile("visible.txt", .{});
        visible.close();
        const hidden = try tmp.dir.createFile(".hidden.txt", .{});
        hidden.close();
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    const iter_dir = try std.fs.openDirAbsolute(tmp_path, .{ .iterate = true });

    var dirs = try Self.init(testing.allocator, null);
    defer {
        dirs.clearEntries();
        dirs.clearChildEntries();
        dirs.entries.deinit();
        dirs.child_entries.deinit();
        dirs.searcher.deinit();
    }
    dirs.dir.close();
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
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f1 = try tmp.dir.createFile("test_file.txt", .{});
        f1.close();
        const f2 = try tmp.dir.createFile("other.txt", .{});
        f2.close();
        const f3 = try tmp.dir.createFile("test_another.txt", .{});
        f3.close();
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    const iter_dir = try std.fs.openDirAbsolute(tmp_path, .{ .iterate = true });

    var dirs = try Self.init(testing.allocator, null);
    defer {
        dirs.clearEntries();
        dirs.clearChildEntries();
        dirs.entries.deinit();
        dirs.child_entries.deinit();
        dirs.searcher.deinit();
    }
    dirs.dir.close();
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
    var dirs = try Self.init(testing.allocator, ".");
    defer dirs.deinit();

    const path = try dirs.fullPath(".");
    try testing.expect(path.len > 0);
    // Should be absolute
    try testing.expect(std.mem.indexOf(u8, path, "/") != null);
}
