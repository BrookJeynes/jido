const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("app.zig");


pub const Cache = struct {
    mutex: std.Thread.Mutex = .{},
    cache: std.StringHashMap(Image),
};

const Status = enum {
    ready,
    processing,
    failed,
};

const Image = @This();

///Only use on first transmission. Subsequent draws should use
///`Image.image`.
data: ?vaxis.zigimg.Image = null,
image: ?vaxis.Image = null,
path: ?[]const u8 = null,
status: Status = .processing,

pub fn deinit(self: @This(), alloc: std.mem.Allocator, vx: vaxis.Vaxis, tty: *vaxis.Tty) void {
    if (self.image) |image| {
        vx.freeImage(tty.writer(), image.id);
    }
    if (self.data) |data| {
        var d = data;
        d.deinit(alloc);
    }
    if (self.path) |path| alloc.free(path);
}

pub fn processImage(alloc: std.mem.Allocator, app: *App, path: []const u8) error{ Unsupported, OutOfMemory }!void {
    app.images.cache.put(path, .{ .path = path, .status = .processing }) catch {
        const message = try std.fmt.allocPrint(alloc, "Failed to load image '{s}' - error occurred while attempting to add image to cache.", .{path});
        defer alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
        return error.Unsupported;
    };

    const load_img_thread = std.Thread.spawn(.{}, loadImage, .{
        alloc,
        app,
        path,
    }) catch {
        app.images.mutex.lock();
        if (app.images.cache.getPtr(path)) |entry| {
            entry.status = .failed;
        }
        app.images.mutex.unlock();

        const message = try std.fmt.allocPrint(alloc, "Failed to load image '{s}' - error occurred while attempting to spawn processing thread.", .{path});
        defer alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};

        return error.Unsupported;
    };
    load_img_thread.detach();
}

fn loadImage(alloc: std.mem.Allocator, app: *App, path: []const u8) error{OutOfMemory}!void {
    var buf: [(1024 * 1024) * 5]u8 = undefined; // 5mb
    const data = vaxis.zigimg.Image.fromFilePath(alloc, path, &buf) catch {
        app.images.mutex.lock();
        if (app.images.cache.getPtr(path)) |entry| {
            entry.status = .failed;
        }
        app.images.mutex.unlock();

        const message = try std.fmt.allocPrint(alloc, "Failed to load image '{s}' - error occurred while attempting to read image from path.", .{path});
        defer alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};

        return;
    };

    app.images.mutex.lock();
    if (app.images.cache.getPtr(path)) |entry| {
        entry.status = .ready;
        entry.data = data;
        entry.path = path;
    } else {
        const message = try std.fmt.allocPrint(alloc, "Failed to load image '{s}' - error occurred while attempting to add image to cache.", .{path});
        defer alloc.free(message);
        app.notification.write(message, .err) catch {};
        if (app.file_logger) |file_logger| file_logger.write(message, .err) catch {};
        return;
    }
    app.images.mutex.unlock();

    app.loop.postEvent(.image_ready);
}
