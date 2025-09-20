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
    var paths = std.ArrayListUnmanaged([]const u8){};
    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file, .directory => {
                const path = try arena.dupe(u8, entry.path);
                try paths.append(arena, path);
            },
            // TODO: handle symlinks
            else => continue,
        }
    }

    // sort paths lexicographically
    std.sort.block([]const u8, paths.items, {}, stringSortFn.lessThan);

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

const stringSortFn = struct {
    pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};

const Writer = struct {
    out: *std.Io.Writer = undefined,

    const magic_string = "ingot";
    const end_string   = "togni";

    const Header = struct {
        version: [2]u8 = undefined,
        type: u8 = undefined,
        mode: [4]u8 = undefined,
        path_size: [4]u8 = undefined,
        file_size: [4]u8 = undefined,
    };

    fn begin(self: *Writer) !void {
        try self.out.writeAll(magic_string);
    }

    fn end(self: *Writer) !void {
        try self.out.writeAll(end_string);
        try self.out.flush();
    }

    fn append(self: *Writer, dir: std.fs.Dir, path: []const u8) !void {
        const file = try dir.openFile(path, .{});
        defer file.close();

        const stat = try file.stat();

        var hdr = Header{};

        // version
        std.mem.writeInt(u16, &hdr.version, 0, .big);

        // type
        hdr.type = switch (stat.kind) {
            .file => 0,
            .directory => 1,
            else => unreachable,
        };

        // mode
        const mode: u32 = @intCast(stat.mode);
        std.mem.writeInt(u32, &hdr.mode, mode, .big);

        // path_size
        const path_size: u32 = @intCast(path.len);
        std.mem.writeInt(u32, &hdr.path_size, path_size, .big);

        // file_size
        const file_size: u32 = @intCast(stat.size);
        std.mem.writeInt(u32, &hdr.file_size, file_size, .big);

        try self.out.writeAll(std.mem.asBytes(&hdr));
        try self.out.writeAll(path);

        if (stat.kind == .file) {
            var buf: [32 * 1024]u8 = undefined;
            var reader = file.reader(&buf);
            _ = try self.out.sendFileAll(&reader, .unlimited);
        }

        try self.out.flush();
    }
};
