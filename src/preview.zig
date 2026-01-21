const std = @import("std");

pub const PreviewType = enum {
    none,
    text,
    image,
    pdf,
    archive,
    directory,
};

pub const PreviewData = union(PreviewType) {
    none: void,
    text: []const u8,
    image: ImageInfo,
    pdf: []const u8,
    archive: std.ArrayList([]const u8),
    directory: std.ArrayList([]const u8),
};

pub const ImageInfo = struct {
    cache_path: []const u8,
};

pub const CacheEntry = struct {
    file_path: []const u8,
    preview: PreviewData,
    is_valid: bool,

    pub fn deinit(self: *CacheEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.file_path);
        switch (self.preview) {
            .text, .pdf => |data| alloc.free(data),
            .archive, .directory => |*list| {
                for (list.items) |item| alloc.free(item);
                list.deinit(alloc);
            },
            .image => |img| alloc.free(img.cache_path),
            .none => {},
        }
    }
};

pub const PreviewCache = struct {
    alloc: std.mem.Allocator,
    current: ?CacheEntry,

    pub fn init(alloc: std.mem.Allocator) PreviewCache {
        return .{
            .alloc = alloc,
            .current = null,
        };
    }

    pub fn deinit(self: *PreviewCache) void {
        if (self.current) |*entry| {
            entry.deinit(self.alloc);
        }
    }

    pub fn invalidate(self: *PreviewCache) void {
        if (self.current) |*entry| {
            entry.is_valid = false;
        }
    }

    pub fn clear(self: *PreviewCache) void {
        if (self.current) |*entry| {
            entry.deinit(self.alloc);
        }
        self.current = null;
    }

    pub fn get(self: *PreviewCache, path: []const u8) ?*const PreviewData {
        if (self.current) |*entry| {
            if (entry.is_valid and std.mem.eql(u8, entry.file_path, path)) {
                return &entry.preview;
            }
        }
        return null;
    }

    pub fn set(self: *PreviewCache, path: []const u8, preview: PreviewData) !void {
        self.clear();

        self.current = .{
            .file_path = try self.alloc.dupe(u8, path),
            .preview = preview,
            .is_valid = true,
        };
    }
};
