const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const usage =
    \\usage:
    \\    ingot pack directory
    \\    ingot unpack file.ingot
    \\    ingot diff left.ingot right.ingot
    \\
;

pub fn main() !u8 {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();

    const argv = try std.process.argsAlloc(gpa);

    if (argv.len < 2) {
        std.debug.print(usage, .{});
        return 1;
    }
    const cmd = argv[1];

    if (std.mem.eql(u8, cmd, "pack")) {
        if (argv.len < 3) {
            std.debug.print("error: need one argument -> directory not provided\n", .{});
            std.debug.print(usage, .{});
            return 1;
        }
        try cmd_pack(gpa, argv[2]);
    } else if (std.mem.eql(u8, cmd, "unpack")) {
        if (argv.len < 3) {
            std.debug.print("error: need one argument -> file not provided\n", .{});
            std.debug.print(usage, .{});
            return 1;
        }
        try cmd_unpack(argv[2]);
    } else if (std.mem.eql(u8, cmd, "diff")) {
        if (argv.len < 4) {
            std.debug.print("error: need two arguments -> left and right files\n", .{});
            std.debug.print(usage, .{});
            return 1;
        }
        try cmd_diff(argv[2], argv[3]);
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{cmd});
        std.debug.print(usage, .{});
        return 1;
    }

    return 0;
}

// TODO: add progress bars for pack and unpack

const io_buf_size = 256 * 1024;

fn cmd_diff(left_path: []const u8, right_path: []const u8) !void {
    const l_archive = try std.fs.cwd().openFile(left_path, .{});
    defer l_archive.close();

    const r_archive = try std.fs.cwd().openFile(right_path, .{});
    defer r_archive.close();

    var l_reader_buf: [io_buf_size]u8 = undefined;
    var l_reader = l_archive.reader(&l_reader_buf);

    var r_reader_buf: [io_buf_size]u8 = undefined;
    var r_reader = r_archive.reader(&r_reader_buf);

    const l_top = try parse_top_header(&l_reader);
    const r_top = try parse_top_header(&r_reader);

    if (l_top.ndirs != r_top.ndirs) return error.different_ndirs;
    if (l_top.nfiles != r_top.nfiles) return error.different_nfiles;

    for (0..l_top.ndirs) |i| {
        var l_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const l_path = try parse_dir(&l_reader, &l_path_buf);

        var r_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const r_path = try parse_dir(&r_reader, &r_path_buf);

        if (!std.mem.eql(u8, l_path, r_path)) {
            std.debug.print("dir {d}/{d} want(l): {s}\n", .{ i, l_top.ndirs, l_path });
            std.debug.print("dir {d}/{d} have(r): {s}\n", .{ i, l_top.ndirs, r_path });
            return error.different_dir_path;
        }
    }

    // TODO: files
}

fn parse_dir(reader: *std.fs.File.Reader, path_buf: []u8) ![]const u8 {
    var h = Format.DirHeader{};
    {
        const n = try reader.read(std.mem.asBytes(&h));
        if (n != @sizeOf(Format.DirHeader)) @panic("short read");
    }

    const path_size = h.get_path_size();
    if (path_size > std.fs.max_path_bytes) @panic("path too big");

    // read path
    {
        const n = try reader.read(path_buf[0..path_size]);
        if (n != path_size) @panic("short read");
    }

    return path_buf[0..path_size];
}

fn parse_top_header(reader: *std.fs.File.Reader) !struct { ndirs: u64, nfiles: u64 } {
    var header = Format.TopHeader{};
    {
        const n = try reader.read(std.mem.asBytes(&header));
        if (n != @sizeOf(Format.TopHeader)) @panic("short read");
    }
    if (!std.mem.eql(u8, &header.magic, Format.magic)) return error.wrong_magic;
    if (header.version != Format.version) return error.version;
    return .{
        .ndirs = header.get_ndirs(),
        .nfiles = header.get_nfiles(),
    };
}

fn cmd_unpack(archive_path: []const u8) !void {
    const archive = try std.fs.cwd().openFile(archive_path, .{});
    defer archive.close();

    var reader_buf: [io_buf_size]u8 = undefined;
    var reader = archive.reader(&reader_buf);

    const top = try parse_top_header(&reader);

    // create output directory
    const out_dir_path = std.fs.path.stem(archive_path);
    std.fs.cwd().makeDir(out_dir_path) catch |err| if (err != error.PathAlreadyExists) return err;
    var out_dir = try std.fs.cwd().openDir(out_dir_path, .{});
    defer out_dir.close();

    // read directories
    for (0..top.ndirs) |_| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try parse_dir(&reader, &path_buf);
        out_dir.makeDir(path) catch |err| if (err != error.PathAlreadyExists) return err;
    }

    // read files
    var writer_buf: [io_buf_size]u8 = undefined;
    for (0..top.nfiles) |_| {
        var h = Format.FileHeader{};
        {
            const n = try reader.read(std.mem.asBytes(&h));
            if (n != @sizeOf(Format.FileHeader)) @panic("short read");
        }

        const path_size = h.get_path_size();
        const file_size = h.get_file_size();
        if (path_size > std.fs.max_path_bytes) @panic("path too big");

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        {
            const n = try reader.read(path_buf[0..path_size]);
            if (n != path_size) @panic("short read");
        }
        const path = path_buf[0..path_size];

        var file = try out_dir.createFile(path, .{});
        defer file.close();

        var writer = file.writer(&writer_buf);
        var writer_if = &writer.interface;

        const n = try writer_if.sendFileAll(&reader, .limited64(file_size));
        assert(n == file_size);

        try writer_if.flush();
    }
}

fn cmd_pack(allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var dirs = try std.ArrayList(Item).initCapacity(allocator, 100);
    var files = try std.ArrayList(Item).initCapacity(allocator, 100);

    // recursively traverse the input directory and collect file and dir paths
    {
        var walker = try dir.walk(allocator);
        defer walker.deinit();

        // TODO: how to avoid dupe and reduce allocs?
        // TODO: normalize(remove redundant . or .., collapse double slashes, etc.) and validate path, right now only replacing \ with /

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    const path = try allocator.dupe(u8, entry.path);
                    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, path, std.fs.path.sep_windows, std.fs.path.sep_posix);
                    try files.append(allocator, Item{
                        .path = path,
                    });
                },
                .directory => {
                    const path = try allocator.dupe(u8, entry.path);
                    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, path, std.fs.path.sep_windows, std.fs.path.sep_posix);
                    try dirs.append(allocator, Item{
                        .path = path,
                    });
                },
                // TODO: handle symlinks?
                else => continue,
            }
        }
    }

    // sort
    {
        const cmp = struct {
            pub fn lessThan(_: void, a: Item, b: Item) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan;
        std.sort.block(Item, dirs.items, {}, cmp);
        std.sort.block(Item, files.items, {}, cmp);
    }

    const out_path = try std.mem.concat(allocator, u8, &[_][]const u8{ std.fs.path.basename(dir_path), "." ++ Format.magic });

    var out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();

    var out_buf: [io_buf_size]u8 = undefined;
    var out_writer = out_file.writer(&out_buf);
    const out = &out_writer.interface;

    // write the archive
    var w = Format.Writer{
        .out = out,
    };
    try w.begin(dirs.items.len, files.items.len);
    for (dirs.items) |item| {
        try w.append_dir(item);
    }
    for (files.items) |item| {
        try w.append_file(dir, item);
    }
    try w.end();
}

const Item = struct {
    path: []const u8,
};

const Format = struct {
    const version: u8 = 1;
    const magic = "ingot";

    comptime {
        assert(@alignOf(TopHeader) == 1);
        assert(@alignOf(DirHeader) == 1);
        assert(@alignOf(FileHeader) == 1);
    }

    const TopHeader = struct {
        magic: [5]u8 = .{0} ** 5,
        version: u8 = 0,
        ndirs: [8]u8 = .{0} ** 8,
        nfiles: [8]u8 = .{0} ** 8,

        fn write(self: *TopHeader, ndirs: usize, nfiles: usize) void {
            @memcpy(&self.magic, magic);
            self.version = version;

            const ndirs64: u64 = @intCast(ndirs);
            std.mem.writeInt(u64, &self.ndirs, ndirs64, .big);

            const nfiles64: u64 = @intCast(nfiles);
            std.mem.writeInt(u64, &self.nfiles, nfiles64, .big);
        }

        fn get_ndirs(self: *const TopHeader) u64 {
            const v = std.mem.readInt(u64, &self.ndirs, .big);
            return v;
        }

        fn get_nfiles(self: *const TopHeader) u64 {
            const v = std.mem.readInt(u64, &self.nfiles, .big);
            return v;
        }
    };

    const DirHeader = struct {
        path_size: [4]u8 = .{0} ** 4,

        fn write(self: *DirHeader, path_len: usize) void {
            const path_size: u32 = @intCast(path_len);
            std.mem.writeInt(u32, &self.path_size, path_size, .big);
        }

        fn get_path_size(self: *const DirHeader) u32 {
            const v = std.mem.readInt(u32, &self.path_size, .big);
            return v;
        }
    };

    const FileHeader = struct {
        path_size: [4]u8 = .{0} ** 4,
        file_size: [8]u8 = .{0} ** 8,

        fn write(self: *FileHeader, path_len: usize, file_len: usize) void {
            const path_size: u32 = @intCast(path_len);
            std.mem.writeInt(u32, &self.path_size, path_size, .big);

            const file_size: u64 = @intCast(file_len);
            std.mem.writeInt(u64, &self.file_size, file_size, .big);
        }

        fn get_path_size(self: *const FileHeader) u32 {
            const v = std.mem.readInt(u32, &self.path_size, .big);
            return v;
        }

        fn get_file_size(self: *const FileHeader) u64 {
            const v = std.mem.readInt(u64, &self.file_size, .big);
            return v;
        }
    };

    const Writer = struct {
        out: *std.Io.Writer = undefined,
        reader_buf: [io_buf_size]u8 = undefined,

        fn begin(self: *Writer, ndirs: usize, nfiles: usize) !void {
            var hdr = TopHeader{};
            hdr.write(ndirs, nfiles);
            try self.out.writeAll(std.mem.asBytes(&hdr));
        }

        fn end(self: *Writer) !void {
            try self.out.flush();
        }

        fn append_dir(self: *Writer, item: Item) !void {
            var hdr = DirHeader{};
            hdr.write(item.path.len);
            try self.out.writeAll(std.mem.asBytes(&hdr));
            try self.out.writeAll(item.path);
        }

        fn append_file(self: *Writer, base_dir: std.fs.Dir, item: Item) !void {
            const file = try base_dir.openFile(item.path, .{});
            defer file.close();

            const stat = try file.stat();

            var hdr = FileHeader{};
            hdr.write(item.path.len, stat.size);

            try self.out.writeAll(std.mem.asBytes(&hdr));
            try self.out.writeAll(item.path);

            var reader = file.reader(&self.reader_buf);
            _ = try self.out.sendFileAll(&reader, .unlimited);
        }
    };
};
