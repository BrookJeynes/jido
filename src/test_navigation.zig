const std = @import("std");
const testing = std.testing;
const TestEnv = @import("test_helpers.zig").TestEnv;
const Directories = @import("directories.zig");
const events = @import("events.zig");
const App = @import("app.zig");

test "Navigation: traverse left to parent directory" {
    var env = try TestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createDirStructure(&.{
        .{ .name = "parent", .children = &.{
            .{ .name = "child", .children = &.{} },
            .{ .name = "sibling.txt", .children = null },
        } },
    });

    const child_path = try env.path("parent/child");
    defer testing.allocator.free(child_path);

    var dirs = try Directories.init(testing.allocator, child_path);
    defer dirs.deinit();

    const before_path = try dirs.fullPath(".");
    try testing.expect(std.mem.endsWith(u8, before_path, "child"));

    const parent_dir = try dirs.dir.openDir("../", .{ .iterate = true });
    dirs.dir.close();
    dirs.dir = parent_dir;

    const after_path = try dirs.fullPath(".");
    try testing.expect(std.mem.endsWith(u8, after_path, "parent"));

    try dirs.populateEntries("");
    var found_child = false;
    for (dirs.entries.all()) |entry| {
        if (std.mem.eql(u8, entry.name, "child")) {
            found_child = true;
            try testing.expectEqual(std.fs.Dir.Entry.Kind.directory, entry.kind);
        }
    }
    try testing.expect(found_child);
}

test "Navigation: traverse right into directory" {
    var env = try TestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createDirStructure(&.{
        .{ .name = "subdir", .children = &.{
            .{ .name = "inner.txt", .children = null },
        } },
        .{ .name = "file.txt", .children = null },
    });

    var dirs = try Directories.init(testing.allocator, env.tmp_path);
    defer dirs.deinit();

    try dirs.populateEntries("");

    for (dirs.entries.all(), 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, "subdir")) {
            dirs.entries.selected = i;
            break;
        }
    }

    const selected = try dirs.getSelected();
    try testing.expect(selected != null);
    try testing.expectEqualStrings("subdir", selected.?.name);

    const subdir = try dirs.dir.openDir("subdir", .{ .iterate = true });
    dirs.dir.close();
    dirs.dir = subdir;

    const current_path = try dirs.fullPath(".");
    try testing.expect(std.mem.endsWith(u8, current_path, "subdir"));

    dirs.clearEntries();
    try dirs.populateEntries("");
    try testing.expectEqual(@as(usize, 1), dirs.entries.len());

    const inner = try dirs.entries.get(0);
    try testing.expectEqualStrings("inner.txt", inner.name);
}

test "Navigation: move selection with next and previous" {
    var env = try TestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFiles(&.{ "file1.txt", "file2.txt", "file3.txt", "file4.txt", "file5.txt" });

    var dirs = try Directories.init(testing.allocator, env.tmp_path);
    defer dirs.deinit();

    try dirs.populateEntries("");
    try testing.expectEqual(@as(usize, 5), dirs.entries.len());
    try testing.expectEqual(@as(usize, 0), dirs.entries.selected);

    dirs.entries.next();
    dirs.entries.next();
    dirs.entries.next();
    try testing.expectEqual(@as(usize, 3), dirs.entries.selected);

    dirs.entries.previous();
    try testing.expectEqual(@as(usize, 2), dirs.entries.selected);

    dirs.entries.selectLast();
    try testing.expectEqual(@as(usize, 4), dirs.entries.selected);

    dirs.entries.selectFirst();
    try testing.expectEqual(@as(usize, 0), dirs.entries.selected);
}
