const std = @import("std");

pub fn packWithThreadPool(allocator: Allocator, paths: []Path) !void {
    const POOL_SIZE = 4;
    var pool = std.ThreadPool(POOL_SIZE).init(allocator);
    defer pool.deinit();

    const queue = std.MpscQueue(Chunk).init(allocator);
    defer queue.deinit();

    // Reader task enqueues (order, buffer) tuples
    for (paths) |p, idx| {
        try pool.spawn(readerTask, .{ .path = p, .order = idx, .queue = &queue });
    }

    // Close queue once all readers spawned
    pool.wait();  // wait for all reader threads to finish enqueuing
    queue.close();

    // Main thread drains queue in sorted order
    var chunks = try queue.collectAll(allocator);
    std.sort.block(Chunk, &chunks, {}, Chunk.lessThan);

    const writer = getDeterministicWriter();
    for (chunks) |c| {
        try writer.out.writeAll(c.buf[0..c.len]);
    }
}

// Reader thread function
fn readerTask(ctx: ReaderCtx) !void {
    const f = try std.fs.cwd().openFile(ctx.path, .{});
    defer f.close();

    const sz = try f.stat().size;
    var offset: u64 = 0;
    while (offset < sz) : (offset += chunkSize) {
        const thisSize = @intCast(usize, std.math.min(sz - offset, chunkSize));
        var buf = try ctx.queue.allocBuf(thisSize);
        try f.readAll(buf, offset);
        try ctx.queue.enqueue(Chunk{ .order = ctx.order, .buf = buf, .len = thisSize });
    }
}
