const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug information") orelse switch (optimize) {
        .Debug, .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };

    var mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .strip = strip,
        .link_libc = true,
    });
    mod.addCSourceFiles(.{
        .files = &[_][]const u8{"lz4.c"},
    });

    const exe = b.addExecutable(.{
        .name = "ingot",
        .root_module = mod,
    });

    b.installArtifact(exe);
}
