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

    // File Walker
    // - Recursively traverse the input directory.
    // - Collect file paths.
    // - Apply deterministic rules:
    //   - Sort files lexicographically.
    // - Pass a clean, ordered list of files downstream.

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(arena);
    defer walker.deinit();

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

    std.sort.block([]const u8, paths.items, {}, stringSortFn.lessThan);

    var out_buf: [32 * 1024]u8 = undefined;
    var out_writer = std.fs.File.stdout().writer(&out_buf);
    const out = &out_writer.interface;

    // TODO: collect permissions

    var tw = TarWriter{
        .out = out,
    };
    for (paths.items) |item| {
        const file = try dir.openFile(item, .{});
        defer file.close();
        const stat = try file.stat();
        try tw.append(item, stat);
    }

    // Archive Writer
    // - Tar writer (MVP):
    //   - For each file, write a tar header + file contents.
    //   - Stream sequentially — no need to buffer the whole archive.
    // - Keep it stream‑oriented so large builds don’t blow up memory.
    // - Output goes to a generic “writer” interface (so you can swap compression in/out).

    // Output Sink
    // - Write to:
    //   - File (out.tar).
    //   - Or stdout (for piping into artifact uploaders).
    // - Ensure clean exit codes and error handling.
}

// TODO: based on https://github.com/rui314/mold/blob/main/lib/tar.cc
//
// A tar file consists of one or more Ustar header followed by data.
// Each Ustar header represents a single file in an archive.
//
// tar is an old file format, and its `name` field is only 100 bytes long.
// If `name` is longer than 100 bytes, we can emit a PAX header before a
// Ustar header to store a long filename.
//
// For simplicity, we always emit a PAX header even for a short filename.
const TarWriter = struct {
    const block_size: i64 = 512;

    out: *std.Io.Writer = undefined,

    const UstarHeader = struct {
        name: [100]u8 = undefined,
        mode: [8]u8 = undefined,
        uid: [8]u8 = undefined,
        gid: [8]u8 = undefined,
        size: [12]u8 = undefined,
        mtime: [12]u8 = undefined,
        checksum: [8]u8 = undefined,
        typeflag: [1]u8 = undefined,
        linkname: [100]u8 = undefined,
        magic: [6]u8 = undefined,
        version: [2]u8 = undefined,
        uname: [32]u8 = undefined,
        gname: [32]u8 = undefined,
        devmajor: [8]u8 = undefined,
        devminor: [8]u8 = undefined,
        prefix: [155]u8 = undefined,
        pad: [12]u8 = undefined,
    };

    comptime {
        assert(@sizeOf(UstarHeader) == block_size);
    }

    fn append(self: *TarWriter, path: []const u8, stat: std.fs.File.Stat) !void {
        // encode pax only when path and size do not fit in the ustar header

        const ustar_max_filename = 100;
        const ustar_max_dirname = 155;

        const base = std.fs.path.basename(path);
        const dir = std.fs.path.dirname(path) orelse "";

        if (base.len > ustar_max_filename or dir.len > ustar_max_dirname)
            try self.encode_path(path);

        const ustar_max_size: usize = 8 * 1024 * 1024 * 1024 - 1;

        if (stat.size > ustar_max_size)
            try self.encode_size(stat.size);

        // TODO: write ustar header
        // TODO: write file content
    }

    // Based on https://pubs.opengroup.org/onlinepubs/9699919799/utilities/pax.html#tag_20_92_13_03
    //
    // In short:
    //
    // "%d %s=%s\n", <length>, <keyword>, <value>
    //
    // <length> = decimal length of the extended header record in octets, including the trailing <newline>
    // <keyword> = any UTF-8 characters, e.g. path
    // <value> = based on <keyword>
    //
    // we need only path and size keyword:
    //
    // path = pathname of the following file, this shall override the name and prefix fields in the following header block(s)
    // size = size of the file in octets, expressed as a decimal number using digits, this shall override the size field in the following header block(s)
    //

    fn encode_path(self: *TarWriter, path: []const u8) !void {
        const known_part = " path=\n";

        // used for temporary int->string conversions
        var str_buf: ToStringBuf = undefined;

        // Construct a string which contains something like "16 path=foo/bar\n" where 16 is the size of the string including the size string itself
        const len = known_part.len + path.len;
        var total = to_string(len, &str_buf).len + len;
        total = to_string(total, &str_buf).len + len;

        try self.out.print("{d} path={s}\n", .{ total, path });
        try self.out.flush();
    }

    fn encode_size(self: *TarWriter, size: usize) !void {
        const known_part = " size=\n";

        // used for temporary int->string conversions
        var str_buf: ToStringBuf = undefined;

        // Construct a string which contains something like "11 size=42\n" where 11 is the size of the string including the size string itself
        const len = known_part.len + to_string(size, &str_buf).len;
        var total = to_string(len, &str_buf).len + len;
        total = to_string(total, &str_buf).len + len;

        try self.out.print("{d} size={d}\n", .{ total, size });
        try self.out.flush();
    }
};

const stringSortFn = struct {
    pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};

const ToStringBuf = [20]u8;

fn to_string(num: u64, buf: []u8) []u8 {
    return std.fmt.bufPrint(buf, "{}", .{num}) catch {
        @panic("should happend!");
    };
}
