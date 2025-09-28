const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    comptime {
        const need = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 1 };
        const have = builtin.zig_version;
        if (need.order(have) != .eq) {
            @compileError(std.fmt.comptimePrint("unsupported zig version: need {f}, have {f}", .{ need, have }));
        }
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug information") orelse switch (optimize) {
        .Debug, .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };

    const opts = std.Build.Module.CreateOptions{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .strip = strip,
    };

    const exe = b.addExecutable(.{
        .name = "ingot",
        .root_module = b.createModule(opts),
    });
    b.installArtifact(exe);

    const release = b.step("release", "Make a binary release");
    const release_targets = [_]std.Target.Query{
        .{ .os_tag = .linux, .cpu_arch = .x86_64 },
        .{ .os_tag = .linux, .cpu_arch = .aarch64 },
        .{ .os_tag = .macos, .cpu_arch = .aarch64 },
        .{ .os_tag = .macos, .cpu_arch = .x86_64 },
        .{ .os_tag = .windows, .cpu_arch = .aarch64 },
        .{ .os_tag = .windows, .cpu_arch = .x86_64 },
    };

    for (release_targets) |target_query| {
        const resolved_target = b.resolveTargetQuery(target_query);
        const t = resolved_target.result;

        var rel_opts = opts;
        rel_opts.strip = true;
        rel_opts.target = resolved_target;
        rel_opts.optimize = if (optimize != .Debug) optimize else .ReleaseFast;
        const rel_exe = b.addExecutable(.{
            .name = "ingot",
            .root_module = b.createModule(rel_opts),
        });

        const install = b.addInstallArtifact(rel_exe, .{});
        install.dest_dir = .prefix;
        install.dest_sub_path = b.fmt("{s}/{s}-{s}-{s}", .{
            @tagName(rel_opts.optimize.?),
            rel_exe.name,
            @tagName(t.os.tag),
            @tagName(t.cpu.arch),
        });

        release.dependOn(&install.step);
    }
}
