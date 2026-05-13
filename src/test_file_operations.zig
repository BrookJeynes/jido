const std = @import("std");
const testing = std.testing;
const TestEnv = @import("test_helpers.zig").TestEnv;
const Directories = @import("directories.zig");
const io = std.testing.io;
const environment = @import("environment.zig");
const getCleanName = @import("path_utils.zig").getCleanName;

test "FileOps: create new directory" {
    var env = try TestEnv.init(testing.allocator);
    defer env.deinit();

    var dirs = try Directories.init(io, testing.allocator, env.tmp_path);
    defer dirs.deinit();

    try dirs.dir.createDir(io, "testdir", .default_dir);

    var test_dir = dirs.dir.openDir(io, "testdir", .{}) catch |err| {
        std.debug.print("Failed to open created directory: {}\n", .{err});
        return err;
    };
    test_dir.close(io);

    try dirs.populateEntries("");
    var found = false;
    for (dirs.entries.all()) |entry| {
        if (std.mem.eql(u8, getCleanName(entry), "testdir")) {
            found = true;
            try testing.expectEqual(std.Io.File.Kind.directory, entry.kind);
        }
    }
    try testing.expect(found);
}

test "FileOps: create new file" {
    var env = try TestEnv.init(testing.allocator);
    defer env.deinit();

    var dirs = try Directories.init(io, testing.allocator, env.tmp_path);
    defer dirs.deinit();

    const file = try dirs.dir.createFile(io, "testfile.txt", .{});
    file.close(io);

    try testing.expect(environment.fileExists(io, dirs.dir, "testfile.txt"));

    try dirs.populateEntries("");
    var found = false;
    for (dirs.entries.all()) |entry| {
        if (std.mem.eql(u8, entry.name, "testfile.txt")) {
            found = true;
            try testing.expectEqual(std.Io.File.Kind.file, entry.kind);
        }
    }
    try testing.expect(found);
}

test "FileOps: rename file" {
    var env = try TestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFiles(&.{"oldname.txt"});

    var dirs = try Directories.init(io, testing.allocator, env.tmp_path);
    defer dirs.deinit();

    try dirs.populateEntries("");

    try testing.expect(environment.fileExists(io, dirs.dir, "oldname.txt"));
    try dirs.dir.rename("oldname.txt", dirs.dir, "newname.txt", io);
    try testing.expect(!environment.fileExists(io, dirs.dir, "oldname.txt"));
    try testing.expect(environment.fileExists(io, dirs.dir, "newname.txt"));

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
