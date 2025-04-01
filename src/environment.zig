const std = @import("std");
const zuid = @import("zuid");
const builtin = @import("builtin");

pub fn getHomeDir() !?std.fs.Dir {
    return try std.fs.openDirAbsolute(std.posix.getenv("HOME") orelse {
        return null;
    }, .{ .iterate = true });
}

pub fn getXdgConfigHomeDir() !?std.fs.Dir {
    return try std.fs.openDirAbsolute(std.posix.getenv("XDG_CONFIG_HOME") orelse {
        return null;
    }, .{ .iterate = true });
}

pub fn getEditor() ?[]const u8 {
    const editor = std.posix.getenv("EDITOR");
    if (editor) |e| {
        if (std.mem.trim(u8, e, " ").len > 0) {
            return e;
        }
    }
    return null;
}

pub fn checkDuplicatePath(
    buf: []u8,
    dir: std.fs.Dir,
    relative_path: []const u8,
) std.fmt.BufPrintError!struct {
    path: []const u8,
    had_duplicate: bool,
} {
    var had_duplicate = false;
    const new_path = if (fileExists(dir, relative_path)) lbl: {
        had_duplicate = true;
        const extension = std.fs.path.extension(relative_path);
        break :lbl try std.fmt.bufPrint(
            buf,
            "{s}-{s}{s}",
            .{ relative_path[0 .. relative_path.len - extension.len], zuid.new.v4(), extension },
        );
    } else lbl: {
        break :lbl try std.fmt.bufPrint(buf, "{s}", .{relative_path});
    };

    return .{ .path = new_path, .had_duplicate = had_duplicate };
}

pub fn openFile(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    file: []const u8,
    editor: []const u8,
) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try dir.realpath(file, &path_buf);

    var child = std.process.Child.init(&.{ editor, path }, alloc);
    _ = try child.spawnAndWait();
}

pub fn fileExists(dir: std.fs.Dir, path: []const u8) bool {
    const result = blk: {
        _ = dir.openFile(path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => break :blk false,
                else => {
                    std.log.info("{}", .{err});
                    break :blk true;
                },
            }
        };
        break :blk true;
    };
    return result;
}

pub fn dirExists(dir: std.fs.Dir, path: []const u8) bool {
    const result = blk: {
        _ = dir.openDir(path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => break :blk false,
                else => {
                    std.log.info("{}", .{err});
                    break :blk true;
                },
            }
        };
        break :blk true;
    };
    return result;
}

///Deletes the contents of a directory but not the directory itself.
///Returns the amount of files failed to be delete.
pub fn deleteContents(dir: std.fs.Dir) !usize {
    var failed: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        dir.deleteTree(entry.name) catch {
            failed += 1;
        };
    }
    return failed;
}
