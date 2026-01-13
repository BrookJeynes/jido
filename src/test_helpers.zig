const std = @import("std");

pub const TestEnv = struct {
    allocator: std.mem.Allocator,
    tmp_dir: std.testing.TmpDir,
    tmp_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) !TestEnv {
        var tmp_dir = std.testing.tmpDir(.{});
        const real_path = try tmp_dir.dir.realpathAlloc(allocator, ".");

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
            const file = try self.tmp_dir.dir.createFile(name, .{});
            file.close();
        }
    }

    pub const DirNode = struct {
        name: []const u8,
        children: ?[]const DirNode,
    };

    pub fn createDirStructure(self: *TestEnv, nodes: []const DirNode) !void {
        for (nodes) |node| {
            if (node.children) |children| {
                try self.tmp_dir.dir.makeDir(node.name);
                var subdir = try self.tmp_dir.dir.openDir(node.name, .{});
                defer subdir.close();

                for (children) |child| {
                    if (child.children) |_| {
                        try subdir.makeDir(child.name);
                    } else {
                        const file = try subdir.createFile(child.name, .{});
                        file.close();
                    }
                }
            } else {
                const file = try self.tmp_dir.dir.createFile(node.name, .{});
                file.close();
            }
        }
    }

    pub fn path(self: *TestEnv, relative: []const u8) ![]const u8 {
        return try std.fs.path.join(self.allocator, &.{ self.tmp_path, relative });
    }
};
