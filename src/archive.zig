const std = @import("std");
const ascii = @import("std").ascii;

const archive_buf_size = 8192;

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

    pub fn deinit(self: *ArchiveContents, alloc: std.mem.Allocator) void {
        for (self.entries.items) |entry| alloc.free(entry);
        self.entries.deinit(alloc);
    }
};

pub fn listArchiveContents(
    alloc: std.mem.Allocator,
    file: std.fs.File,
    archive_type: ArchiveType,
    traversal_limit: usize,
) !ArchiveContents {
    var buffer: [archive_buf_size]u8 = undefined;
    var reader = file.reader(&buffer);

    const contents = switch (archive_type) {
        .tar => try listTar(alloc, &reader.interface, traversal_limit),
        .@"tar.gz" => try listTarGz(alloc, &reader.interface, traversal_limit),
        .@"tar.xz" => try listTarXz(alloc, &reader.interface, traversal_limit),
        .@"tar.zst" => try listTarZst(alloc, &reader.interface, traversal_limit),
        .zip => try listZip(alloc, file, traversal_limit),
    };

    return contents;
}

fn extractTopLevelEntry(
    alloc: std.mem.Allocator,
    full_path: []const u8,
    is_directory: bool,
    truncated: bool,
) ![]const u8 {
    var is_directory_internal = is_directory;
    var path = full_path;

    if (std.mem.indexOfScalar(u8, full_path, '/')) |idx| {
        path = full_path[0..idx];
        is_directory_internal = true;
    }

    return try std.fmt.allocPrint(
        alloc,
        "{s}{s}{s}",
        .{ path, if (truncated) "..." else "", if (is_directory_internal) "/" else "" },
    );
}

fn listTar(
    alloc: std.mem.Allocator,
    reader: anytype,
    traversal_limit: usize,
) !ArchiveContents {
    var entries: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }

    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    var diagnostics: std.tar.Diagnostics = .{ .allocator = alloc };
    defer diagnostics.deinit();

    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var iter = std.tar.Iterator.init(reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    iter.diagnostics = &diagnostics;

    for (0..traversal_limit) |_| {
        const tar_file = try iter.next();
        if (tar_file == null) break;

        const is_dir = tar_file.?.kind == .directory;
        const truncated = tar_file.?.name.len >= std.fs.max_path_bytes;
        const entry = try extractTopLevelEntry(alloc, tar_file.?.name, is_dir, truncated);

        const gop = try seen.getOrPut(entry);
        if (gop.found_existing) {
            alloc.free(entry);
            continue;
        }

        try entries.append(alloc, entry);
    }

    return ArchiveContents{
        .entries = entries,
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
    traversal_limit: usize,
) !ArchiveContents {
    var entries: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }

    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    var buffer: [archive_buf_size]u8 = undefined;
    var file_reader = file.reader(&buffer);

    var iter = try std.zip.Iterator.init(&file_reader);
    var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;

    for (0..traversal_limit) |_| {
        const zip_file = try iter.next();
        if (zip_file == null) break;

        const file_name_len = @min(zip_file.?.filename_len, file_name_buf.len);
        const truncated = zip_file.?.filename_len > file_name_buf.len;

        try file_reader.seekTo(zip_file.?.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const file_name = file_name_buf[0..file_name_len];
        try file_reader.interface.readSliceAll(file_name);

        const is_dir = std.mem.endsWith(u8, file_name, "/");
        const entry = try extractTopLevelEntry(alloc, file_name, is_dir, truncated);

        const gop = try seen.getOrPut(entry);
        if (gop.found_existing) {
            alloc.free(entry);
            continue;
        }

        try entries.append(alloc, entry);
    }

    return ArchiveContents{
        .entries = entries,
    };
}
