const std = @import("std");
const assert = std.debug.assert;

const usage =
    \\usage:
    \\    ingot pack directory
    \\    ingot unpack file
    \\
;

pub fn main() !u8 {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();

    const argv = try std.process.argsAlloc(gpa);

    if (argv.len < 2) {
        std.debug.print("error: missing command\n", .{});
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
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{cmd});
        std.debug.print(usage, .{});
        return 1;
    }

    return 0;
}

fn cmd_unpack(archive_path: []const u8) !void {
    const archive = try std.fs.cwd().openFile(archive_path, .{});
    defer archive.close();

    var reader_buf: [64 * 1024]u8 = undefined;
    var reader = archive.reader(&reader_buf);

    var magic: [Format.magic.len]u8 = undefined;
    {
        const n = try reader.read(&magic);
        if (n != Format.magic.len) @panic("short read");
    }
    if (!std.mem.eql(u8, &magic, Format.magic)) return error.wrong_magic;

    const out_dir_path = "out.d";
    std.fs.cwd().makeDir(out_dir_path) catch |err| if (err != error.PathAlreadyExists) return err;
    var out_dir = try std.fs.cwd().openDir(out_dir_path, .{});
    defer out_dir.close();

    var writer_buf: [64 * 1024]u8 = undefined;

    while (true) {
        var header = Format.Header{};
        {
            const n = try reader.read(std.mem.asBytes(&header));
            if (n != @sizeOf(Format.Header)) @panic("short read");
        }

        if (std.mem.eql(u8, std.mem.asBytes(&header), Format.end_of_archive)) {
            break;
        }

        const kind = header.get_kind();
        const mode = header.get_mode();
        const path_size = header.get_path_size();
        const file_size = header.get_file_size();

        if (path_size > std.fs.max_path_bytes) @panic("path too big");

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        {
            const n = try reader.read(path_buf[0..path_size]);
            if (n != path_size) @panic("short read");
        }
        const path = path_buf[0..path_size];

        std.debug.print("{s}\n", .{path});

        switch (kind) {
            .dir => {
                out_dir.makeDir(path) catch |err| if (err != error.PathAlreadyExists) return err;
                var dir = try out_dir.openDir(path, .{
                    .iterate = true,
                });
                defer dir.close();
                try dir.chmod(mode);
            },
            .file => {
                var file = try out_dir.createFile(path, .{
                    .mode = mode,
                });
                defer file.close();
                var writer = file.writer(&writer_buf);
                var writer_if = &writer.interface;
                const n = try writer_if.sendFileAll(&reader, .limited64(file_size));
                assert(n == file_size);
                try writer_if.flush();
            },
        }
    }
}

fn cmd_pack(allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    // TODO: normalize paths to avoid entropy!

    // recursively traverse the input directory and collect file and dir paths
    var paths = try std.ArrayList(Item).initCapacity(allocator, 100);
    while (try walker.next()) |entry| {
        const kind: Item.Kind = switch (entry.kind) {
            .file => .file,
            .directory => .dir,
            // TODO: handle symlinks?
            else => continue,
        };
        const path = try allocator.dupe(u8, entry.path);
        try paths.append(allocator, Item{
            .path = path,
            .kind = kind,
        });
    }

    // sort
    {
        const cmp = struct {
            pub fn lessThan(_: void, a: Item, b: Item) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lessThan;
        std.sort.block(Item, paths.items, {}, cmp);
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = std.fs.File.stdout().writer(&out_buf);
    const out = &out_writer.interface;

    // write the archive
    var w = Format.Writer{
        .out = out,
    };

    try w.begin();
    for (paths.items) |item| {
        std.debug.print("{s}\n", .{item.path});
        try w.append(dir, item);
    }
    try w.end();

    // TODO: ensure clean exit codes and error handling.
}

const Item = struct {
    const Kind = enum(u8) {
        file,
        dir,
    };

    path: []const u8,
    kind: Kind,
};

const Format = struct {
    const version: u8 = 1;
    const magic = "ingot";

    comptime {
        assert(@alignOf(Header) == 1);
    }

    const end_of_archive = &[_]u8{0xff} ** @sizeOf(Format.Header);

    const Header = struct {
        version: u8 = 0,
        kind: u8 = 0,
        mode: [4]u8 = .{0} ** 4, // TODO: is this needed? current thinking is a executable file must be preserved, but is it needed for dirs?
        path_size: [4]u8 = .{0} ** 4,
        file_size: [8]u8 = .{0} ** 8,
        // TODO: checksum?

        fn write(self: *Header, kind: Item.Kind, mode: u32, path_len: usize, file_len: usize) void {
            self.version = version;

            const kind_int: u8 = @intFromEnum(kind);
            self.kind = kind_int;

            std.mem.writeInt(u32, &self.mode, mode & 0o777, .big);

            const path_size: u32 = @intCast(path_len);
            std.mem.writeInt(u32, &self.path_size, path_size, .big);

            const file_size: u32 = @intCast(file_len);
            std.mem.writeInt(u64, &self.file_size, file_size, .big);
        }

        fn get_kind(self: *const Header) Item.Kind {
            const v: Item.Kind = @enumFromInt(self.kind);
            return v;
        }

        fn get_mode(self: *const Header) u32 {
            const v = std.mem.readInt(u32, &self.mode, .big);
            return v;
        }

        fn get_path_size(self: *const Header) u32 {
            const v = std.mem.readInt(u32, &self.path_size, .big);
            return v;
        }

        fn get_file_size(self: *const Header) u64 {
            const v = std.mem.readInt(u64, &self.file_size, .big);
            return v;
        }
    };

    const Writer = struct {
        out: *std.Io.Writer = undefined,
        reader_buf: [64 * 1024]u8 = undefined,

        fn begin(self: *Writer) !void {
            try self.out.writeAll(magic);
        }

        fn end(self: *Writer) !void {
            try self.out.writeAll(end_of_archive);
            // TODO: add hash of whole archive at the end. For integrity and also to detect non-determinism
            try self.out.flush();
        }

        fn append(self: *Writer, base_dir: std.fs.Dir, item: Item) !void {
            switch (item.kind) {
                .file => try self.append_file(base_dir, item),
                .dir => try self.append_dir(base_dir, item),
            }
        }

        fn append_dir(self: *Writer, base_dir: std.fs.Dir, item: Item) !void {
            var dir = try base_dir.openDir(item.path, .{});
            defer dir.close();

            const stat = try dir.stat();

            const mode: u32 = @intCast(stat.mode);

            var hdr = Header{};
            hdr.write(.dir, mode, item.path.len, 0);

            try self.out.writeAll(std.mem.asBytes(&hdr));
            try self.out.writeAll(item.path);
        }

        fn append_file(self: *Writer, base_dir: std.fs.Dir, item: Item) !void {
            const file = try base_dir.openFile(item.path, .{});
            defer file.close();

            const stat = try file.stat();

            const mode: u32 = @intCast(stat.mode);

            var hdr = Header{};
            hdr.write(item.kind, mode, item.path.len, stat.size);

            try self.out.writeAll(std.mem.asBytes(&hdr));
            try self.out.writeAll(item.path);

            var reader = file.reader(&self.reader_buf);
            _ = try self.out.sendFileAll(&reader, .unlimited);
        }
    };
};
