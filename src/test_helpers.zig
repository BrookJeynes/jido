const std = @import("std");

const io = std.testing.io;

pub const TestEnv = struct {
    allocator: std.mem.Allocator,
    tmp_dir: std.testing.TmpDir,
    tmp_path: [:0]const u8,

    pub fn init(allocator: std.mem.Allocator) !TestEnv {
        var tmp_dir = std.testing.tmpDir(.{});
        const real_path = try tmp_dir.dir.realPathFileAlloc(io, ".", allocator);

        return TestEnv{
            .allocator = allocator,
            .tmp_dir = tmp_dir,
            .tmp_path = real_path,
        };
    }

    pub fn deinit(self: *TestEnv) void {
        self.allocator.free(self.tmp_path);
        self.tmp_dir.cleanup();
    }

    pub fn createFiles(self: *TestEnv, names: []const []const u8) !void {
        for (names) |name| {
            var file = try self.tmp_dir.dir.createFile(io, name, .{});
            file.close(io);
        }
    }

    pub const DirNode = struct {
        name: []const u8,
        children: ?[]const DirNode,
    };

    pub fn createDirStructure(self: *TestEnv, nodes: []const DirNode) !void {
        for (nodes) |node| {
            if (node.children) |children| {
                try self.tmp_dir.dir.createDir(io, node.name, .default_dir);
                var subdir = try self.tmp_dir.dir.openDir(io, node.name, .{});
                defer subdir.close(io);

                for (children) |child| {
                    if (child.children) |_| {
                        try subdir.createDir(io, child.name, .default_dir);
                    } else {
                        var file = try subdir.createFile(io, child.name, .{});
                        file.close(io);
                    }
                }
            } else {
                var file = try self.tmp_dir.dir.createFile(io, node.name, .{});
                file.close(io);
            }
        }
    }

    pub fn path(self: *TestEnv, relative: []const u8) ![]const u8 {
        return try std.fs.path.join(self.allocator, &.{ self.tmp_path, relative });
    }
};
