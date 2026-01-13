const std = @import("std");
const testing = std.testing;
const TestEnv = @import("test_helpers.zig").TestEnv;
const Directories = @import("directories.zig");
const environment = @import("environment.zig");

test "FileOps: create new directory" {
    var env = try TestEnv.init(testing.allocator);
    defer env.deinit();

    var dirs = try Directories.init(testing.allocator, env.tmp_path);
    defer dirs.deinit();

    try dirs.dir.makeDir("testdir");

    var test_dir = dirs.dir.openDir("testdir", .{}) catch |err| {
        std.debug.print("Failed to open created directory: {}\n", .{err});
        return err;
    };
    test_dir.close();

    try dirs.populateEntries("");
    var found = false;
    for (dirs.entries.all()) |entry| {
        if (std.mem.eql(u8, entry.name, "testdir")) {
            found = true;
            try testing.expectEqual(std.fs.Dir.Entry.Kind.directory, entry.kind);
        }
    }
    try testing.expect(found);
}

test "FileOps: create new file" {
    var env = try TestEnv.init(testing.allocator);
    defer env.deinit();

    var dirs = try Directories.init(testing.allocator, env.tmp_path);
    defer dirs.deinit();

    const file = try dirs.dir.createFile("testfile.txt", .{});
    file.close();

    try testing.expect(environment.fileExists(dirs.dir, "testfile.txt"));

    try dirs.populateEntries("");
    var found = false;
    for (dirs.entries.all()) |entry| {
        if (std.mem.eql(u8, entry.name, "testfile.txt")) {
            found = true;
            try testing.expectEqual(std.fs.Dir.Entry.Kind.file, entry.kind);
        }
    }
    try testing.expect(found);
}

test "FileOps: rename file" {
    var env = try TestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFiles(&.{"oldname.txt"});

    var dirs = try Directories.init(testing.allocator, env.tmp_path);
    defer dirs.deinit();

    try dirs.populateEntries("");

    try testing.expect(environment.fileExists(dirs.dir, "oldname.txt"));
    try dirs.dir.rename("oldname.txt", "newname.txt");
    try testing.expect(!environment.fileExists(dirs.dir, "oldname.txt"));
    try testing.expect(environment.fileExists(dirs.dir, "newname.txt"));

    dirs.clearEntries();
    try dirs.populateEntries("");

    var found_old = false;
    var found_new = false;
    for (dirs.entries.all()) |entry| {
        if (std.mem.eql(u8, entry.name, "oldname.txt")) found_old = true;
        if (std.mem.eql(u8, entry.name, "newname.txt")) found_new = true;
    }

    try testing.expect(!found_old);
    try testing.expect(found_new);
}
