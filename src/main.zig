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
    // - Collect file metadata (path, size, permissions).
    // - Apply deterministic rules:
    //   - Sort files lexicographically.
    //   - Normalize timestamps (e.g., set to epoch 0).
    //   - Strip or fix user/group IDs.
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

    var tw = try TarWriter.init(std.fs.File.stdout());
    for (paths.items) |item| {
        tw.append(item);
        std.debug.print("{s}\n", .{item});
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

// based on https://github.com/rui314/mold/blob/main/lib/tar.cc
const TarWriter = struct {
    const block_size: i64 = 512;

    out: std.fs.File = undefined,

    // A tar file consists of one or more Ustar header followed by data.
    // Each Ustar header represents a single file in an archive.
    //
    // tar is an old file format, and its `name` field is only 100 bytes long.
    // If `name` is longer than 100 bytes, we can emit a PAX header before a
    // Ustar header to store a long filename.
    //
    // For simplicity, we always emit a PAX header even for a short filename.
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

    fn init(out: std.fs.File) !TarWriter {
        return TarWriter{
            .out = out,
        };
    }

    fn append(self: *TarWriter, path: []const u8) void {
        _ = self;
        _ = path;
    }
};

const stringSortFn = struct {
    pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};
