const std = @import("std");
const assert = std.debug.assert;

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const argv = try std.process.argsAlloc(arena);

    var args = argv[1..];
    if (args.len < 1) return error.directory_not_provided;

    const dir_path = args[0];
    args = args[1..];

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(arena);
    defer walker.deinit();

    // recursively traverse the input directory and collect file and dir paths
    var paths = try std.ArrayList(Item).initCapacity(arena, 100);
    while (try walker.next()) |entry| {
        const kind: Item.Kind = switch (entry.kind) {
            .file,
            => .file,
            .directory => .dir,
            // TODO: handle symlinks
            else => continue,
        };
        const path = try arena.dupe(u8, entry.path);
        try paths.append(arena, Item{
            .path = path,
            .kind = kind,
        });
    }

    // sort paths lexicographically
    const cmp = struct {
        pub fn lessThan(_: void, a: Item, b: Item) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan;
    std.sort.block(Item, paths.items, {}, cmp);

    var out_buf: [32 * 1024]u8 = undefined;
    var out_writer = std.fs.File.stdout().writer(&out_buf);
    const out = &out_writer.interface;

    // write the archive
    var w = Writer{
        .out = out,
    };

    try w.begin();
    for (paths.items) |path| {
        try w.append(dir, path);
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

const Writer = struct {
    const version: u16 = 1;
    const magic_string = "ingot";
    const end_string = "togni";

    out: *std.Io.Writer = undefined,
    reader_buf: [32 * 1024]u8 = undefined,

    const Header = struct {
        version: [2]u8 = .{0} ** 2,
        type: u8 = 0,
        mode: [4]u8 = .{0} ** 4,
        path_size: [4]u8 = .{0} ** 4,
        file_size: [8]u8 = .{0} ** 8,
        // TODO: checksum?!
    };

    fn begin(self: *Writer) !void {
        try self.out.writeAll(magic_string);
    }

    fn end(self: *Writer) !void {
        try self.out.writeAll(end_string);
        try self.out.flush();
    }

    fn append(self: *Writer, base_dir: std.fs.Dir, item: Item) !void {
        switch (item.kind) {
            .file => try self.append_file(base_dir, item.path),
            .dir => try self.append_dir(base_dir, item.path),
        }
    }

    fn append_dir(self: *Writer, base_dir: std.fs.Dir, path: []const u8) !void {
        var dir = try base_dir.openDir(path, .{});
        defer dir.close();

        const stat = try dir.stat();

        var hdr = Header{};

        // version
        std.mem.writeInt(u16, &hdr.version, version, .big);

        // type
        hdr.type = 1;

        // mode
        const mode: u32 = @intCast(stat.mode);
        std.mem.writeInt(u32, &hdr.mode, mode & 0o777, .big);

        // path_size
        const path_size: u32 = @intCast(path.len);
        std.mem.writeInt(u32, &hdr.path_size, path_size, .big);

        // file_size
        std.mem.writeInt(u64, &hdr.file_size, 0, .big);

        try self.out.writeAll(std.mem.asBytes(&hdr));
        try self.out.writeAll(path);
    }

    fn append_file(self: *Writer, base_dir: std.fs.Dir, path: []const u8) !void {
        const file = try base_dir.openFile(path, .{});
        defer file.close();

        const stat = try file.stat();

        var hdr = Header{};

        // version
        std.mem.writeInt(u16, &hdr.version, version, .big);

        // type
        hdr.type = 0;

        // mode
        const mode: u32 = @intCast(stat.mode);
        std.mem.writeInt(u32, &hdr.mode, mode & 0o777, .big);

        // path_size
        const path_size: u32 = @intCast(path.len);
        std.mem.writeInt(u32, &hdr.path_size, path_size, .big);

        // file_size
        const file_size: u64 = @intCast(stat.size);
        std.mem.writeInt(u64, &hdr.file_size, file_size, .big);

        try self.out.writeAll(std.mem.asBytes(&hdr));
        try self.out.writeAll(path);

        var reader = file.reader(&self.reader_buf);
        _ = try self.out.sendFileAll(&reader, .unlimited);
    }
};
