const std = @import("std");
const builtin = @import("builtin");

const zuid = @import("zuid");

pub fn getHomeDir(io: std.Io, env_map: *const std.process.Environ.Map) !?std.Io.Dir {
    return try std.Io.Dir.openDirAbsolute(io, env_map.get("HOME") orelse {
        return null;
    }, .{ .iterate = true });
}

pub fn getXdgConfigHomeDir(io: std.Io, env_map: *const std.process.Environ.Map) !?std.Io.Dir {
    return try std.Io.Dir.openDirAbsolute(io, env_map.get("XDG_CONFIG_HOME") orelse {
        return null;
    }, .{ .iterate = true });
}

pub fn getEditor(env_map: *const std.process.Environ.Map) ?[]const u8 {
    const editor = env_map.get("EDITOR");
    if (editor) |e| {
        if (std.mem.trim(u8, e, " ").len > 0) {
            return e;
        }
    }
    return null;
}

pub fn checkDuplicatePath(
    io: std.Io,
    buf: []u8,
    dir: std.Io.Dir,
    relative_path: []const u8,
) error{NoSpaceLeft}!struct {
    path: []const u8,
    had_duplicate: bool,
} {
    var had_duplicate = false;
    const new_path = if (fileExists(io, dir, relative_path)) lbl: {
        had_duplicate = true;
        const extension = std.fs.path.extension(relative_path);
        break :lbl try std.fmt.bufPrint(
            buf,
            "{s}-{f}{s}",
            .{ relative_path[0 .. relative_path.len - extension.len], zuid.new.v4(io), extension },
        );
    } else lbl: {
        break :lbl try std.fmt.bufPrint(buf, "{s}", .{relative_path});
    };

    return .{ .path = new_path, .had_duplicate = had_duplicate };
}

pub fn openFile(
    io: std.Io,
    dir: std.Io.Dir,
    file: []const u8,
    editor: []const u8,
) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try dir.realPathFile(io, file, &path_buf);
    const path = path_buf[0..path_len];

    var child = try std.process.spawn(io, .{ .argv = &.{ editor, path } });
    _ = try child.wait(io);
}

pub fn fileExists(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    const result = blk: {
        var f = dir.openFile(io, path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => break :blk false,
                else => {
                    std.log.info("{}", .{err});
                    break :blk true;
                },
            }
        };
        f.close(io);
        break :blk true;
    };
    return result;
}

pub fn dirExists(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    const result = blk: {
        var d = dir.openDir(io, path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => break :blk false,
                else => {
                    std.log.info("{}", .{err});
                    break :blk true;
                },
            }
        };
        d.close(io);
        break :blk true;
    };
    return result;
}

///Deletes the contents of a directory but not the directory itself.
///Returns the amount of files failed to be delete.
pub fn deleteContents(io: std.Io, dir: std.Io.Dir) !usize {
    var failed: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        dir.deleteTree(io, entry.name) catch {
            failed += 1;
        };
    }
    return failed;
}
