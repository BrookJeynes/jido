const std = @import("std");

const App = @import("./app.zig");
const Archive = @import("./archive.zig");
const Image = @import("./image.zig");
const path_utils = @import("./path_utils.zig");
const config = &@import("./config.zig").config;

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

    pub fn updatePath(self: *PreviewCache, app: *App, old_path: []const u8, new_path: []const u8) error{OutOfMemory}!void {
        if (self.current) |*entry| {
            if (std.mem.eql(u8, entry.file_path, old_path)) {
                if (entry.preview == .image) {
                    app.images.mutex.lock();
                    defer app.images.mutex.unlock();

                    if (app.images.cache.fetchRemove(old_path)) |kv| {
                        app.images.cache.put(new_path, kv.value) catch |err| {
                            kv.value.deinit(app.alloc, app.vx, &app.tty);
                            self.clear();
                            return err;
                        };
                    }

                    self.alloc.free(entry.preview.image.cache_path);
                    entry.preview.image.cache_path = try self.alloc.dupe(u8, new_path);
                }

                self.alloc.free(entry.file_path);
                entry.file_path = try self.alloc.dupe(u8, new_path);
            }
        }
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

pub fn loadPreviewForCurrentEntry(app: *App) !void {
    if (!config.preview_file) return;

    const entry = (try app.directories.getSelected()) orelse return;

    const clean_name = path_utils.getCleanName(entry);
    const path = try app.directories.dir.realpathAlloc(
        app.alloc,
        clean_name,
    );
    defer app.alloc.free(path);

    if (app.preview_cache.get(path)) |_| {
        return;
    }

    const preview = switch (entry.kind) {
        .directory => try loadDirectoryPreview(app, entry),
        .file => try loadFilePreview(app, entry),
        else => PreviewData{ .none = {} },
    };

    try app.preview_cache.set(path, preview);
}

fn loadDirectoryPreview(app: *App, entry: std.fs.Dir.Entry) !PreviewData {
    app.directories.clearChildEntries();

    const clean_name = path_utils.getCleanName(entry);
    app.directories.populateChildEntries(clean_name) catch |err| {
        const message = try std.fmt.allocPrint(
            app.alloc,
            "Failed to read directory entries - {}.",
            .{err},
        );
        defer app.alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| {
            file_logger.write(message, .err) catch {};
        }
        return PreviewData{ .none = {} };
    };

    var list: std.ArrayList([]const u8) = .empty;
    for (app.directories.child_entries.all()) |child| {
        const owned = try app.alloc.dupe(u8, child);
        try list.append(app.alloc, owned);
    }

    return PreviewData{ .directory = list };
}

fn loadFilePreview(app: *App, entry: std.fs.Dir.Entry) !PreviewData {
    const file_ext = std.fs.path.extension(entry.name);

    if (config.show_images) {
        if (isImageExtension(file_ext)) {
            return try loadImagePreview(app, entry);
        }
    }

    if (std.mem.eql(u8, file_ext, ".pdf")) {
        return try loadPdfPreview(app, entry);
    }

    if (Archive.ArchiveType.fromPath(entry.name)) |archive_type| {
        return try loadArchivePreview(app, entry, archive_type);
    }

    return try loadTextPreview(app, entry);
}

fn loadTextPreview(app: *App, entry: std.fs.Dir.Entry) !PreviewData {
    const clean_name = path_utils.getCleanName(entry);
    var file = app.directories.dir.openFile(
        clean_name,
        .{ .mode = .read_only },
    ) catch |err| {
        const message = try std.fmt.allocPrint(
            app.alloc,
            "Failed to open file - {}.",
            .{err},
        );
        defer app.alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| {
            file_logger.write(message, .err) catch {};
        }
        return PreviewData{ .none = {} };
    };
    defer file.close();

    var buffer: [4096]u8 = undefined;
    const bytes = file.readAll(&buffer) catch |err| {
        const message = try std.fmt.allocPrint(
            app.alloc,
            "Failed to read file contents - {}.",
            .{err},
        );
        defer app.alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| {
            file_logger.write(message, .err) catch {};
        }
        return PreviewData{ .none = {} };
    };

    if (std.unicode.utf8ValidateSlice(buffer[0..bytes])) {
        const text = try app.alloc.dupe(u8, buffer[0..bytes]);
        return PreviewData{ .text = text };
    }

    return PreviewData{ .none = {} };
}

fn loadImagePreview(app: *App, entry: std.fs.Dir.Entry) !PreviewData {
    const clean_name = path_utils.getCleanName(entry);
    const path = try app.directories.dir.realpathAlloc(
        app.alloc,
        clean_name,
    );
    defer app.alloc.free(path);

    app.images.mutex.lock();
    const exists = app.images.cache.contains(path);
    app.images.mutex.unlock();

    if (!exists) {
        const owned_path = try app.alloc.dupe(u8, path);
        Image.processImage(app.alloc, app, owned_path) catch {
            app.alloc.free(owned_path);
            return PreviewData{ .none = {} };
        };
    }

    return PreviewData{
        .image = .{
            .cache_path = try app.alloc.dupe(u8, path),
        },
    };
}

fn loadPdfPreview(app: *App, entry: std.fs.Dir.Entry) !PreviewData {
    const clean_name = path_utils.getCleanName(entry);
    const path = try app.directories.dir.realpathAlloc(
        app.alloc,
        clean_name,
    );
    defer app.alloc.free(path);

    const result = std.process.Child.run(.{
        .allocator = app.alloc,
        .argv = &[_][]const u8{
            "pdftotext",
            "-f",
            "0",
            "-l",
            "5",
            path,
            "-",
        },
        .cwd_dir = app.directories.dir,
    }) catch {
        app.notification.write("No preview available. Install pdftotext to get PDF previews.", .err) catch {};
        return PreviewData{ .none = {} };
    };
    defer app.alloc.free(result.stdout);
    defer app.alloc.free(result.stderr);

    if (result.term.Exited != 0) {
        app.notification.write("No preview available. Install pdftotext to get PDF previews.", .err) catch {};
        return PreviewData{ .none = {} };
    }

    const text = try app.alloc.dupe(u8, result.stdout);
    return PreviewData{ .pdf = text };
}

fn loadArchivePreview(
    app: *App,
    entry: std.fs.Dir.Entry,
    archive_type: Archive.ArchiveType,
) !PreviewData {
    const clean_name = path_utils.getCleanName(entry);
    var file = app.directories.dir.openFile(
        clean_name,
        .{ .mode = .read_only },
    ) catch |err| {
        const message = try std.fmt.allocPrint(
            app.alloc,
            "Failed to open archive - {}.",
            .{err},
        );
        defer app.alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| {
            file_logger.write(message, .err) catch {};
        }
        return PreviewData{ .none = {} };
    };
    defer file.close();

    const archive_contents = Archive.listArchiveContents(
        app.alloc,
        file,
        archive_type,
        config.archive_traversal_limit,
    ) catch |err| {
        const message = try std.fmt.allocPrint(
            app.alloc,
            "Failed to read archive: {s}",
            .{@errorName(err)},
        );
        defer app.alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| {
            file_logger.write(message, .err) catch {};
        }
        return PreviewData{ .none = {} };
    };

    if (config.sort_dirs) {
        const sort_mod = @import("./sort.zig");
        std.mem.sort(
            []const u8,
            archive_contents.entries.items,
            {},
            sort_mod.string,
        );
    }

    return PreviewData{ .archive = archive_contents.entries };
}

fn isImageExtension(ext: []const u8) bool {
    const supported = [_][]const u8{
        ".bmp",
        ".farbfeld",
        ".gif",
        ".iff",
        ".ilbm",
        ".jpeg",
        ".jpg",
        ".pam",
        ".pbm",
        ".pcx",
        ".pgm",
        ".png",
        ".ppm",
        ".qoi",
        ".ras",
        ".sgi",
        ".tga",
        ".tif",
        ".tiff",
    };

    for (supported) |supported_ext| {
        if (std.ascii.eqlIgnoreCase(ext, supported_ext)) {
            return true;
        }
    }
    return false;
}
