const std = @import("std");
const ascii = @import("std").ascii;
const FileLogger = @import("./file_logger.zig");

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

pub const ExtractionResult = struct {
    files_extracted: usize,
    dirs_created: usize,
    files_skipped: usize,
};

pub const PathValidationError = error{
    PathContainsTraversal,
    PathTooLong,
    PathEmpty,
};

pub const SkipReason = enum {
    path_contains_traversal,
    path_too_long,
    path_empty,
};

const Operation = enum { list, extract };

const OperationArgs = union(Operation) {
    list: struct {
        traversal_limit: usize,
    },
    extract: struct {
        dest_dir: std.fs.Dir,
        file_logger: ?FileLogger,
    },
};

const OperationResult = union(Operation) {
    list: ArchiveContents,
    extract: ExtractionResult,
};

pub fn listArchiveContents(
    alloc: std.mem.Allocator,
    file: std.fs.File,
    archive_type: ArchiveType,
    traversal_limit: usize,
) !ArchiveContents {
    var buffer: [archive_buf_size]u8 = undefined;
    var reader = file.reader(&buffer);

    const list_args = OperationArgs{ .list = .{
        .traversal_limit = traversal_limit,
    } };

    const contents = switch (archive_type) {
        .tar => try listTar(alloc, &reader.interface, traversal_limit),
        .@"tar.gz" => (try processTarGz(alloc, &reader.interface, list_args)).list,
        .@"tar.xz" => (try processTarXz(alloc, &reader.interface, list_args)).list,
        .@"tar.zst" => (try processTarZst(alloc, &reader.interface, list_args)).list,
        .zip => try listZip(alloc, file, traversal_limit),
    };

    return contents;
}

pub fn extractArchive(
    alloc: std.mem.Allocator,
    file: std.fs.File,
    archive_type: ArchiveType,
    dest_dir: std.fs.Dir,
    file_logger: ?FileLogger,
) !ExtractionResult {
    var buffer: [archive_buf_size]u8 = undefined;
    var reader = file.reader(&buffer);

    const extract_args = OperationArgs{ .extract = .{
        .dest_dir = dest_dir,
        .file_logger = file_logger,
    } };

    return switch (archive_type) {
        .tar => try extractTarImpl(alloc, &reader.interface, dest_dir, file_logger),
        .@"tar.gz" => (try processTarGz(alloc, &reader.interface, extract_args)).extract,
        .@"tar.xz" => (try processTarXz(alloc, &reader.interface, extract_args)).extract,
        .@"tar.zst" => (try processTarZst(alloc, &reader.interface, extract_args)).extract,
        .zip => try extractZipImpl(alloc, file, dest_dir, file_logger),
    };
}

pub fn getExtractDirName(archive_path: []const u8) []const u8 {
    const basename = std.fs.path.basename(archive_path);

    return if (ascii.endsWithIgnoreCase(basename, ".tar.gz"))
        basename[0 .. basename.len - 7]
    else if (ascii.endsWithIgnoreCase(basename, ".tar.xz"))
        basename[0 .. basename.len - 7]
    else if (ascii.endsWithIgnoreCase(basename, ".tar.zst"))
        basename[0 .. basename.len - 8]
    else if (ascii.endsWithIgnoreCase(basename, ".tgz"))
        basename[0 .. basename.len - 4]
    else if (ascii.endsWithIgnoreCase(basename, ".txz"))
        basename[0 .. basename.len - 4]
    else if (ascii.endsWithIgnoreCase(basename, ".tzst"))
        basename[0 .. basename.len - 5]
    else if (ascii.endsWithIgnoreCase(basename, ".tar"))
        basename[0 .. basename.len - 4]
    else if (ascii.endsWithIgnoreCase(basename, ".zip"))
        basename[0 .. basename.len - 4]
    else if (ascii.endsWithIgnoreCase(basename, ".jar"))
        basename[0 .. basename.len - 4]
    else
        basename;
}

fn validateAndCleanPath(
    alloc: std.mem.Allocator,
    path: []const u8,
) (PathValidationError || error{OutOfMemory})![]const u8 {
    // Strip leading slashes (handles /, //, ///, etc.)
    var clean_path = path;
    while (std.mem.startsWith(u8, clean_path, "/")) {
        clean_path = clean_path[1..];
    }

    if (clean_path.len == 0) return error.PathEmpty;
    if (clean_path.len >= std.fs.max_path_bytes) return error.PathTooLong;

    // Check for directory traversal by tracking depth
    var depth: i32 = 0;
    var iter = std.mem.splitScalar(u8, clean_path, '/');
    while (iter.next()) |component| {
        if (component.len == 0) continue;

        if (std.mem.eql(u8, component, "..")) {
            depth -= 1;
            if (depth < 0) {
                return error.PathContainsTraversal;
            }
        } else if (!std.mem.eql(u8, component, ".")) {
            depth += 1;
        }
    }

    return try alloc.dupe(u8, clean_path);
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

fn processTarGz(
    alloc: std.mem.Allocator,
    reader: anytype,
    args: OperationArgs,
) !OperationResult {
    var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(reader, .gzip, &flate_buffer);

    return switch (args) {
        .list => |list_args| .{
            .list = try listTar(alloc, &decompress.reader, list_args.traversal_limit),
        },
        .extract => |extract_args| .{
            .extract = try extractTarImpl(alloc, &decompress.reader, extract_args.dest_dir, extract_args.file_logger),
        },
    };
}

fn processTarXz(
    alloc: std.mem.Allocator,
    reader: anytype,
    args: OperationArgs,
) !OperationResult {
    var dcp = try std.compress.xz.decompress(alloc, reader.adaptToOldInterface());
    defer dcp.deinit();
    var adapter_buffer: [1024]u8 = undefined;
    var adapter = dcp.reader().adaptToNewApi(&adapter_buffer);

    return switch (args) {
        .list => |list_args| .{
            .list = try listTar(alloc, &adapter.new_interface, list_args.traversal_limit),
        },
        .extract => |extract_args| .{
            .extract = try extractTarImpl(alloc, &adapter.new_interface, extract_args.dest_dir, extract_args.file_logger),
        },
    };
}

fn processTarZst(
    alloc: std.mem.Allocator,
    reader: anytype,
    args: OperationArgs,
) !OperationResult {
    const window_len = std.compress.zstd.default_window_len;
    const window_buffer = try alloc.alloc(u8, window_len + std.compress.zstd.block_size_max);
    defer alloc.free(window_buffer);
    var decompress: std.compress.zstd.Decompress = .init(reader, window_buffer, .{
        .verify_checksum = false,
        .window_len = window_len,
    });

    return switch (args) {
        .list => |list_args| .{
            .list = try listTar(alloc, &decompress.reader, list_args.traversal_limit),
        },
        .extract => |extract_args| .{
            .extract = try extractTarImpl(alloc, &decompress.reader, extract_args.dest_dir, extract_args.file_logger),
        },
    };
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

fn extractTarImpl(
    alloc: std.mem.Allocator,
    reader: anytype,
    dest_dir: std.fs.Dir,
    file_logger: ?FileLogger,
) !ExtractionResult {
    var files_extracted: usize = 0;
    var dirs_created: usize = 0;
    var files_skipped: usize = 0;

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
        const safe_path = validateAndCleanPath(alloc, tar_file.name) catch |err| {
            if (err == error.OutOfMemory) return err;

            files_skipped += 1;
            if (file_logger) |logger| {
                const reason: SkipReason = switch (err) {
                    error.PathContainsTraversal => .path_contains_traversal,
                    error.PathTooLong => .path_too_long,
                    error.PathEmpty => .path_empty,
                    error.OutOfMemory => unreachable,
                };

                const message = try std.fmt.allocPrint(alloc, "Failed to extract file '{s}': {any}", .{ tar_file.name, reason });
                defer alloc.free(message);
                logger.write(message, .err) catch {};
            }
            continue;
        };
        defer alloc.free(safe_path);

        if (tar_file.kind == .directory) {
            try dest_dir.makePath(safe_path);
            dirs_created += 1;
        } else if (tar_file.kind == .file or tar_file.kind == .sym_link) {
            if (std.fs.path.dirname(safe_path)) |parent| {
                try dest_dir.makePath(parent);
            }

            // TODO: Investigate preserving file permissions from archive
            const out_file = try dest_dir.createFile(safe_path, .{ .exclusive = true });
            defer out_file.close();

            var file_writer_buffer: [archive_buf_size]u8 = undefined;
            var file_writer = out_file.writer(&file_writer_buffer);
            try iter.streamRemaining(tar_file, &file_writer.interface);

            files_extracted += 1;
        }
    }

    return ExtractionResult{
        .files_extracted = files_extracted,
        .dirs_created = dirs_created,
        .files_skipped = files_skipped,
    };
}

fn extractZipImpl(
    alloc: std.mem.Allocator,
    file: std.fs.File,
    dest_dir: std.fs.Dir,
    file_logger: ?FileLogger,
) !ExtractionResult {
    var files_extracted: usize = 0;
    var dirs_created: usize = 0;
    var files_skipped: usize = 0;

    var buffer: [archive_buf_size]u8 = undefined;
    var file_reader = file.reader(&buffer);

    var iter = try std.zip.Iterator.init(&file_reader);
    var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (try iter.next()) |entry| {
        const file_name_len = @min(entry.filename_len, file_name_buf.len);

        try file_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const file_name = file_name_buf[0..file_name_len];
        try file_reader.interface.readSliceAll(file_name);

        const safe_path = validateAndCleanPath(alloc, file_name) catch |err| {
            if (err == error.OutOfMemory) return err;

            files_skipped += 1;
            if (file_logger) |logger| {
                const reason: SkipReason = switch (err) {
                    error.PathContainsTraversal => .path_contains_traversal,
                    error.PathTooLong => .path_too_long,
                    error.PathEmpty => .path_empty,
                    error.OutOfMemory => unreachable,
                };

                const message = try std.fmt.allocPrint(alloc, "Failed to extract file '{s}': {any}", .{ file_name, reason });
                defer alloc.free(message);
                logger.write(message, .err) catch {};
            }
            continue;
        };
        defer alloc.free(safe_path);

        if (std.mem.endsWith(u8, file_name, "/")) {
            try dest_dir.makePath(safe_path);
            dirs_created += 1;
        } else {
            if (std.fs.path.dirname(safe_path)) |parent| {
                try dest_dir.makePath(parent);
            }

            // TODO: Investigate preserving file permissions from archive
            const out_file = try dest_dir.createFile(safe_path, .{ .exclusive = true });
            defer out_file.close();

            // Seek to local file header and read it to get to compressed data
            try file_reader.seekTo(entry.file_offset);
            const local_header = try file_reader.interface.takeStruct(std.zip.LocalFileHeader, .little);

            // Skip filename and extra field to get to compressed data
            _ = try file_reader.interface.discard(@enumFromInt(local_header.filename_len));
            _ = try file_reader.interface.discard(@enumFromInt(local_header.extra_len));

            var copy_buffer: [archive_buf_size]u8 = undefined;

            if (entry.compression_method == .store) {
                var total_read: usize = 0;
                while (total_read < entry.uncompressed_size) {
                    const to_read = @min(copy_buffer.len, entry.uncompressed_size - total_read);
                    const n = try file_reader.interface.readSliceShort(copy_buffer[0..to_read]);
                    if (n == 0) break;
                    try out_file.writeAll(copy_buffer[0..n]);
                    total_read += n;
                }
            } else if (entry.compression_method == .deflate) {
                var limited_buffer: [archive_buf_size]u8 = undefined;
                var limited_reader = file_reader.interface.limited(@enumFromInt(entry.compressed_size), &limited_buffer);
                var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
                var decompress = std.compress.flate.Decompress.init(&limited_reader.interface, .raw, &flate_buffer);

                while (true) {
                    const n = try decompress.reader.readSliceShort(&copy_buffer);
                    if (n == 0) break;
                    try out_file.writeAll(copy_buffer[0..n]);
                }
            } else {
                return error.UnsupportedCompressionMethod;
            }

            files_extracted += 1;
        }
    }

    return ExtractionResult{
        .files_extracted = files_extracted,
        .dirs_created = dirs_created,
        .files_skipped = files_skipped,
    };
}
