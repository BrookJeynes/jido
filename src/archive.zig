const std = @import("std");
const ascii = @import("std").ascii;

pub const ArchiveType = enum {
    tar,
    @"tar.gz",
    @"tar.xz",
    @"tar.zst",
    zip,

    pub fn fromPath(file_path: []const u8) ?ArchiveType {
        if (ascii.endsWithIgnoreCase(file_path, ".tar")) return .tar;
        if (ascii.endsWithIgnoreCase(file_path, ".tgz")) return .@"tar.gz";
        if (ascii.endsWithIgnoreCase(file_path, ".tar.gz")) return .@"tar.gz";
        if (ascii.endsWithIgnoreCase(file_path, ".txz")) return .@"tar.xz";
        if (ascii.endsWithIgnoreCase(file_path, ".tar.xz")) return .@"tar.xz";
        if (ascii.endsWithIgnoreCase(file_path, ".tzst")) return .@"tar.zst";
        if (ascii.endsWithIgnoreCase(file_path, ".tar.zst")) return .@"tar.zst";
        if (ascii.endsWithIgnoreCase(file_path, ".zip")) return .zip;
        if (ascii.endsWithIgnoreCase(file_path, ".jar")) return .zip;
        return null;
    }
};

pub const ArchiveContents = struct {
    entries: std.ArrayList([]const u8),
    total_count: usize,

    pub fn deinit(self: *ArchiveContents, alloc: std.mem.Allocator) void {
        for (self.entries.items) |entry| alloc.free(entry);
        self.entries.deinit(alloc);
    }
};

pub fn listArchiveContents(
    alloc: std.mem.Allocator,
    file: std.fs.File,
    archive_type: ArchiveType,
    limit: usize,
    sort: bool,
) !ArchiveContents {
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(&buffer);

    const contents = switch (archive_type) {
        .tar => try listTar(alloc, &reader.interface, limit),
        .@"tar.gz" => try listTarGz(alloc, &reader.interface, limit),
        .@"tar.xz" => try listTarXz(alloc, &reader.interface, limit),
        .@"tar.zst" => try listTarZst(alloc, &reader.interface, limit),
        .zip => try listZip(alloc, file, limit),
    };

    if (sort) {
        std.mem.sort([]const u8, contents.entries.items, {}, sortEntry);
    }

    return contents;
}

fn sortEntry(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn extractTopLevelEntry(
    alloc: std.mem.Allocator,
    full_path: []const u8,
    is_directory: bool,
    truncated: bool,
) ![]const u8 {
    if (std.mem.indexOfScalar(u8, full_path, '/')) |idx| {
        const dir_name = full_path[0..idx];
        if (truncated) {
            return try std.fmt.allocPrint(alloc, "{s}.../", .{dir_name});
        } else {
            return try std.fmt.allocPrint(alloc, "{s}/", .{dir_name});
        }
    }

    if (is_directory or std.mem.endsWith(u8, full_path, "/")) {
        if (std.mem.endsWith(u8, full_path, "/")) {
            if (truncated) {
                return try std.fmt.allocPrint(alloc, "{s}...", .{full_path[0 .. full_path.len - 1]});
            } else {
                return try alloc.dupe(u8, full_path);
            }
        } else {
            if (truncated) {
                return try std.fmt.allocPrint(alloc, "{s}.../", .{full_path});
            } else {
                return try std.fmt.allocPrint(alloc, "{s}/", .{full_path});
            }
        }
    } else {
        if (truncated) {
            return try std.fmt.allocPrint(alloc, "{s}...", .{full_path});
        } else {
            return try alloc.dupe(u8, full_path);
        }
    }
}

fn addUniqueEntry(
    alloc: std.mem.Allocator,
    entries: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
    entry: []const u8,
    limit: usize,
    total_count: *usize,
) !bool {
    const gop = try seen.getOrPut(entry);
    if (gop.found_existing) {
        alloc.free(entry);
        return true;
    }

    if (entries.items.len >= limit) {
        alloc.free(entry);
        return false;
    }

    try entries.append(alloc, entry);
    total_count.* += 1;
    return true;
}

fn listTar(
    alloc: std.mem.Allocator,
    reader: anytype,
    limit: usize,
) !ArchiveContents {
    var entries: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }

    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    var total_count: usize = 0;
    var diagnostics: std.tar.Diagnostics = .{ .allocator = alloc };
    defer diagnostics.deinit();

    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var iter = std.tar.Iterator.init(reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    iter.diagnostics = &diagnostics;

    while (try iter.next()) |tar_file| {
        const full_path = tar_file.name;
        const is_dir = tar_file.kind == .directory;

        const truncated = full_path.len >= std.fs.max_path_bytes;
        const top_level = try extractTopLevelEntry(alloc, full_path, is_dir, truncated);
        if (!try addUniqueEntry(alloc, &entries, &seen, top_level, limit, &total_count)) {
            break;
        }
    }

    return ArchiveContents{
        .entries = entries,
        .total_count = total_count,
    };
}

fn listTarGz(
    alloc: std.mem.Allocator,
    reader: anytype,
    limit: usize,
) !ArchiveContents {
    var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(reader, .gzip, &flate_buffer);
    return try listTar(alloc, &decompress.reader, limit);
}

fn listTarXz(
    alloc: std.mem.Allocator,
    reader: anytype,
    limit: usize,
) !ArchiveContents {
    var dcp = try std.compress.xz.decompress(alloc, reader.adaptToOldInterface());
    defer dcp.deinit();
    var adapter_buffer: [1024]u8 = undefined;
    var adapter = dcp.reader().adaptToNewApi(&adapter_buffer);
    return try listTar(alloc, &adapter.new_interface, limit);
}

fn listTarZst(
    alloc: std.mem.Allocator,
    reader: anytype,
    limit: usize,
) !ArchiveContents {
    const window_len = std.compress.zstd.default_window_len;
    const window_buffer = try alloc.alloc(u8, window_len + std.compress.zstd.block_size_max);
    var decompress: std.compress.zstd.Decompress = .init(reader, window_buffer, .{
        .verify_checksum = false,
        .window_len = window_len,
    });
    return try listTar(alloc, &decompress.reader, limit);
}

fn listZip(
    alloc: std.mem.Allocator,
    file: std.fs.File,
    limit: usize,
) !ArchiveContents {
    var entries: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }

    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    var total_count: usize = 0;

    var buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&buffer);

    var iter = try std.zip.Iterator.init(&file_reader);
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (try iter.next()) |entry| {
        const filename_len = @min(entry.filename_len, filename_buf.len);
        const truncated = entry.filename_len > filename_buf.len;

        try file_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const filename = filename_buf[0..filename_len];
        try file_reader.interface.readSliceAll(filename);

        const is_dir = std.mem.endsWith(u8, filename, "/");
        const top_level = try extractTopLevelEntry(alloc, filename, is_dir, truncated);
        if (!try addUniqueEntry(alloc, &entries, &seen, top_level, limit, &total_count)) {
            break;
        }
    }

    return ArchiveContents{
        .entries = entries,
        .total_count = total_count,
    };
}
