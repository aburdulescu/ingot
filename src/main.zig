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

    var tw = TarWriter{
        .out = out,
    };
    for (paths.items) |path| {
        try tw.append(arena, dir, path);
    }
    try tw.close();

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

// A tar file consists of one or more Ustar header followed by data.
// Each Ustar header represents a single file in an archive.
//
// tar is an old file format, and its `name` field is only 100 bytes long.
// If `name` is longer than 100 bytes, we can emit a PAX header before a
// Ustar header to store a long filename.
//
// Similary the file size is limited to ~8GB.
//
// For simplicity, we always emit a PAX header even for a short filename or short file size.
//
const TarWriter = struct {
    const block_size: usize = 512;
    const zero_block = [_]u8{0} ** block_size;

    out: *std.Io.Writer = undefined,

    const UstarHeader = struct {
        name: [100]u8 = [_]u8{0} ** 100,
        mode: [8]u8 = [_]u8{0} ** 8,
        uid: [8]u8 = [_]u8{0} ** 8,
        gid: [8]u8 = [_]u8{0} ** 8,
        size: [12]u8 = [_]u8{0} ** 12,
        mtime: [12]u8 = [_]u8{0} ** 12,
        checksum: [8]u8 = [_]u8{0} ** 8,
        typeflag: [1]u8 = [_]u8{0},
        linkname: [100]u8 = [_]u8{0} ** 100,
        magic: [6]u8 = [_]u8{0} ** 6,
        version: [2]u8 = [_]u8{0} ** 2,
        uname: [32]u8 = [_]u8{0} ** 32,
        gname: [32]u8 = [_]u8{0} ** 32,
        devmajor: [8]u8 = [_]u8{0} ** 8,
        devminor: [8]u8 = [_]u8{0} ** 8,
        prefix: [155]u8 = [_]u8{0} ** 155,
        pad: [12]u8 = [_]u8{0} ** 12,
    };

    comptime {
        assert(@sizeOf(UstarHeader) == block_size);
    }

    fn append(self: *TarWriter, allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !void {
        // TODO: encode size as pax only if > 8GB and only for files not directories

        const file = try dir.openFile(path, .{});
        defer file.close();

        const stat = try file.stat();

        const pax_path = try encode_pax_path(allocator, path);
        const pax_size = try encode_pax_size(allocator, stat.size);

        const pax_content_len = if (stat.kind == .file) pax_path.len + pax_size.len else pax_path.len;

        // Write PAX header
        var pax = UstarHeader{};
        _ = std.fmt.printInt(&pax.size, pax_content_len, 8, .lower, .{ .width = 11, .fill = '0' });
        _ = try std.fmt.bufPrint(&pax.name, "PaxHeaders/dummy", .{});
        pax.typeflag[0] = 'x'; // extended header
        pax.version[0] = '0';
        pax.version[1] = '0';
        finalize(&pax);
        try self.out.writeAll(std.mem.asBytes(&pax));

        // Write the attributes
        try self.out.writeAll(pax_path);
        if (stat.kind == .file) try self.out.writeAll(pax_size);

        try self.out.flush();

        // make sure block alignment is kept => padd with necessary 0s
        if (pax_content_len % block_size != 0) {
            const pax_padding = block_size - pax_content_len % block_size;
            try self.out.writeAll(zero_block[0..pax_padding]);
        }

        // Write USTAR header for the actual file
        var ustar = UstarHeader{};
        _ = std.fmt.printInt(&ustar.mode, stat.mode, 8, .lower, .{ .width = 8, .fill = '0' });
        if (stat.kind == .file) {
            _ = std.fmt.printInt(&ustar.size, stat.size, 8, .lower, .{ .width = 11, .fill = '0' });
        } else {
            // do nothing for directory, already set to 0
        }
        ustar.typeflag[0] = switch (stat.kind) {
            .file => '0',
            .directory => '5',
            else => unreachable,
        };
        finalize(&ustar);
        try self.out.writeAll(std.mem.asBytes(&ustar));

        try self.out.flush();

        // Write file contents
        if (stat.kind == .file) {
            var buf: [32 * 1024]u8 = undefined;
            var reader = file.reader(&buf);
            _ = try self.out.sendFileAll(&reader, .unlimited);
        }

        // make sure block alignment is kept => padd with necessary 0s
        if (stat.size % block_size != 0) {
            const ustar_padding = block_size - stat.size % block_size;
            try self.out.writeAll(zero_block[0..ustar_padding]);
        }

        try self.out.flush();
    }

    fn close(self: *TarWriter) !void {
        // Two empty blocks at the end
        try self.out.writeAll(&zero_block);
        try self.out.writeAll(&zero_block);

        try self.out.flush();
    }

    pub fn finalize(hdr: *UstarHeader) void {
        // Fill checksum field with spaces
        @memset(&hdr.checksum, ' ');

        // magic = "ustar\0"
        hdr.magic[0..5].* = "ustar".*;
        hdr.magic[5] = 0;

        // version = "00"
        hdr.version[0] = '0';
        hdr.version[1] = '0';

        // Compute checksum
        var sum: usize = 0;
        const bytes = @as([*]u8, @ptrCast(hdr))[0..block_size];
        for (bytes) |b| sum += b;

        // Format checksum as 6-digit octal + NUL + space
        _ = std.fmt.printInt(&hdr.checksum, sum, 8, .lower, .{ .width = 6, .fill = '0' });
        hdr.checksum[6] = 0; // NUL terminator
        hdr.checksum[7] = ' '; // trailing space
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

    fn encode_pax_path(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        // Build PAX record: "<len> path=<value>\n"
        const tmp = try std.fmt.allocPrint(allocator, " path={s}\n", .{path});

        const total_len = tmp.len + std.fmt.count("{d}", .{tmp.len});

        // recompute until stable
        const final = try std.fmt.allocPrint(allocator, "{d} path={s}\n", .{ total_len, path });

        return final;
    }

    fn encode_pax_size(allocator: std.mem.Allocator, size: usize) ![]u8 {
        // Build PAX record: "<len> size=<value>\n"
        const tmp = try std.fmt.allocPrint(allocator, " size={d}\n", .{size});

        const total_len = tmp.len + std.fmt.count("{d}", .{tmp.len});

        // recompute until stable
        const final = try std.fmt.allocPrint(allocator, "{d} size={d}\n", .{ total_len, size });

        return final;
    }
};

const stringSortFn = struct {
    pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};
