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
    var timer = try std.time.Timer.start();
    const begin = timer.read();
    defer {
        const end = timer.read();
        std.debug.print("total {D}\n", .{end - begin});
    }

    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const argv = try std.process.argsAlloc(arena);

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
        try cmd_pack(arena, argv[2]);
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

    // TODO: compare files
    // TODO: compare symlinks
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

fn parse_top_header(reader: *std.fs.File.Reader) !struct { ndirs: u64, nfiles: u64, nsymlinks: u64 } {
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
        .nsymlinks = header.get_nsymlinks(),
    };
}

fn cmd_unpack(archive_path: []const u8) !void {
    var timer = try std.time.Timer.start();

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
    {
        const begin = timer.read();
        defer {
            const end = timer.read();
            std.debug.print("unpack dirs {D}\n", .{end - begin});
        }

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (0..top.ndirs) |_| {
            const path = try parse_dir(&reader, &path_buf);
            out_dir.makeDir(path) catch |err| if (err != error.PathAlreadyExists) return err;
        }
    }

    // read files
    {
        const begin = timer.read();
        defer {
            const end = timer.read();
            std.debug.print("unpack files {D}\n", .{end - begin});
        }

        var writer_buf: [io_buf_size]u8 = undefined;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (0..top.nfiles) |_| {
            var h = Format.FileHeader{};
            {
                const n = try reader.read(std.mem.asBytes(&h));
                if (n != @sizeOf(Format.FileHeader)) @panic("short read");
            }

            const mode = h.get_mode();
            const path_size = h.get_path_size();
            const file_size = h.get_file_size();
            if (path_size > std.fs.max_path_bytes) @panic("path too big");

            {
                const n = try reader.read(path_buf[0..path_size]);
                if (n != path_size) @panic("short read");
            }
            const path = path_buf[0..path_size];

            var file = try out_dir.createFile(path, .{
                .mode = if (mode == 0) std.fs.File.default_mode else mode,
            });
            defer file.close();

            var writer = file.writer(&writer_buf);
            var writer_if = &writer.interface;

            const n = try writer_if.sendFileAll(&reader, .limited64(file_size));
            assert(n == file_size);

            try writer_if.flush();
        }
    }

    // read symlinks
    {
        const begin = timer.read();
        defer {
            const end = timer.read();
            std.debug.print("unpack symlinks {D}\n", .{end - begin});
        }

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (0..top.nsymlinks) |_| {
            var h = Format.SymlinkHeader{};
            {
                const n = try reader.read(std.mem.asBytes(&h));
                if (n != @sizeOf(Format.SymlinkHeader)) @panic("short read");
            }

            const link_size = h.get_link_size();
            const target_size = h.get_target_size();
            if (link_size > std.fs.max_path_bytes) @panic("path too big");
            if (target_size > std.fs.max_path_bytes) @panic("path too big");

            {
                const n = try reader.read(link_buf[0..link_size]);
                if (n != link_size) @panic("short read");
            }
            const link = link_buf[0..link_size];

            {
                const n = try reader.read(target_buf[0..target_size]);
                if (n != target_size) @panic("short read");
            }
            const target = target_buf[0..target_size];

            try out_dir.symLink(target, link, .{
                // TODO: handle .is_directory for windows
            });
        }
    }
}

fn cmd_pack(allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var timer = try std.time.Timer.start();

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var ndirs: usize = 0;
    var nfiles: usize = 0;
    var nsymlinks: usize = 0;

    // pre-walk dir for precise memory alloc
    {
        const begin = timer.read();
        defer {
            const end = timer.read();
            std.debug.print("walk dir {D}\n", .{end - begin});
        }
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .file => nfiles += 1,
                .directory => ndirs += 1,
                .sym_link => nsymlinks += 1,
                else => continue,
            }
        }
    }

    var dirs = try std.ArrayList(Item).initCapacity(allocator, ndirs);
    var files = try std.ArrayList(Item).initCapacity(allocator, nfiles);
    var symlinks = try std.ArrayList(Item).initCapacity(allocator, nsymlinks);

    // recursively traverse the input directory and collect file and dir paths
    {
        const begin = timer.read();
        defer {
            const end = timer.read();
            std.debug.print("walk dir {D}\n", .{end - begin});
        }

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        // TODO: how to avoid dupe and reduce allocs?

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
                .sym_link => {
                    const path = try allocator.dupe(u8, entry.path);
                    try symlinks.append(allocator, Item{
                        .path = path,
                    });
                },
                else => continue,
            }
        }
    }

    // sort
    {
        const begin = timer.read();
        defer {
            const end = timer.read();
            std.debug.print("sort paths {D}\n", .{end - begin});
        }

        const cmp = struct {
            pub fn lessThan(_: void, a: Item, b: Item) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan;
        std.sort.block(Item, dirs.items, {}, cmp);
        std.sort.block(Item, files.items, {}, cmp);
        std.sort.block(Item, symlinks.items, {}, cmp);
    }

    // write the archive
    {
        const out_path = try std.mem.concat(allocator, u8, &[_][]const u8{ std.fs.path.basename(dir_path), "." ++ Format.magic });

        var out_file = try std.fs.cwd().createFile(out_path, .{});
        defer out_file.close();

        var out_buf: [io_buf_size]u8 = undefined;
        var out_writer = out_file.writer(&out_buf);
        const out = &out_writer.interface;

        // write dirs and files
        {
            var w = Format.Writer{
                .out = out,
            };

            try w.begin(dirs.items.len, files.items.len, symlinks.items.len);

            // write dirs
            {
                const begin = timer.read();
                defer {
                    const end = timer.read();
                    std.debug.print("pack dirs {D}\n", .{end - begin});
                }

                for (dirs.items) |item| {
                    try w.append_dir(item);
                }
            }

            // write files
            {
                const begin = timer.read();
                defer {
                    const end = timer.read();
                    std.debug.print("pack files {D}\n", .{end - begin});
                }
                for (files.items) |item| {
                    try w.append_file(dir, item);
                }
            }

            // write symlinks
            {
                const begin = timer.read();
                defer {
                    const end = timer.read();
                    std.debug.print("pack symlinks {D}\n", .{end - begin});
                }
                for (symlinks.items) |item| {
                    try w.append_symlink(dir, item);
                }
            }

            try w.end();
        }

        // sync to disk
        {
            const begin = timer.read();
            defer {
                const end = timer.read();
                std.debug.print("sync file {D}\n", .{end - begin});
            }

            try out_file.sync();
        }
    }
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
        nsymlinks: [8]u8 = .{0} ** 8,

        fn write(self: *TopHeader, ndirs: usize, nfiles: usize, nsymlinks: usize) void {
            @memcpy(&self.magic, magic);
            self.version = version;

            const ndirs64: u64 = @intCast(ndirs);
            std.mem.writeInt(u64, &self.ndirs, ndirs64, .big);

            const nfiles64: u64 = @intCast(nfiles);
            std.mem.writeInt(u64, &self.nfiles, nfiles64, .big);

            const nsymlinks64: u64 = @intCast(nsymlinks);
            std.mem.writeInt(u64, &self.nsymlinks, nsymlinks64, .big);
        }

        fn get_ndirs(self: *const TopHeader) u64 {
            const v = std.mem.readInt(u64, &self.ndirs, .big);
            return v;
        }

        fn get_nfiles(self: *const TopHeader) u64 {
            const v = std.mem.readInt(u64, &self.nfiles, .big);
            return v;
        }

        fn get_nsymlinks(self: *const TopHeader) u64 {
            const v = std.mem.readInt(u64, &self.nsymlinks, .big);
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

    const SymlinkHeader = struct {
        link_size: [4]u8 = .{0} ** 4,
        target_size: [4]u8 = .{0} ** 4,

        fn write(self: *SymlinkHeader, link_len: usize, target_len: usize) void {
            const link_size: u32 = @intCast(link_len);
            std.mem.writeInt(u32, &self.link_size, link_size, .big);

            const target_size: u32 = @intCast(target_len);
            std.mem.writeInt(u32, &self.target_size, target_size, .big);
        }

        fn get_link_size(self: *const SymlinkHeader) u32 {
            const v = std.mem.readInt(u32, &self.link_size, .big);
            return v;
        }

        fn get_target_size(self: *const SymlinkHeader) u32 {
            const v = std.mem.readInt(u32, &self.target_size, .big);
            return v;
        }
    };

    const FileHeader = struct {
        mode: [4]u8 = .{0} ** 4,
        path_size: [4]u8 = .{0} ** 4,
        file_size: [8]u8 = .{0} ** 8,

        fn write(self: *FileHeader, mode: std.fs.File.Mode, path_len: usize, file_len: usize) void {
            const mode32: u32 = @intCast(mode);
            std.mem.writeInt(u32, &self.mode, mode32, .big);

            const path_size: u32 = @intCast(path_len);
            std.mem.writeInt(u32, &self.path_size, path_size, .big);

            const file_size: u64 = @intCast(file_len);
            std.mem.writeInt(u64, &self.file_size, file_size, .big);
        }

        fn get_mode(self: *const FileHeader) std.fs.File.Mode {
            const v: std.fs.File.Mode = @intCast(std.mem.readInt(u32, &self.mode, .big));
            return v;
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

        fn begin(self: *Writer, ndirs: usize, nfiles: usize, nsymlinks: usize) !void {
            var hdr = TopHeader{};
            hdr.write(ndirs, nfiles, nsymlinks);
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
            hdr.write(stat.mode, item.path.len, stat.size);

            try self.out.writeAll(std.mem.asBytes(&hdr));
            try self.out.writeAll(item.path);

            var reader = file.reader(&self.reader_buf);
            _ = try self.out.sendFileAll(&reader, .unlimited);
        }

        fn append_symlink(self: *Writer, base_dir: std.fs.Dir, item: Item) !void {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = try base_dir.readLink(item.path, &buf);

            var hdr = SymlinkHeader{};
            hdr.write(item.path.len, target.len);

            try self.out.writeAll(std.mem.asBytes(&hdr));
            try self.out.writeAll(item.path);
            try self.out.writeAll(target);
        }
    };
};
