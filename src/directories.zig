const std = @import("std");
const List = @import("./list.zig").List;
const CircStack = @import("./circ_stack.zig").CircularStack;
const config = &@import("./config.zig").config;
const vaxis = @import("vaxis");
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

pub fn init(alloc: std.mem.Allocator) !Self {
    return Self{
        .alloc = alloc,
        .dir = try std.fs.cwd().openDir(".", .{ .iterate = true }),
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
