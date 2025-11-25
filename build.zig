const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ascii_me_this",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addIncludePath(b.path("libs/stb"));

    exe.root_module.addCSourceFile(.{
        .file = b.path("libs/stb/stb_image.c"),
        .flags = &.{},
    });

    exe.root_module.addCSourceFile(.{
        .file = b.path("libs/stb/stb_image_write.c"),
        .flags = &.{},
    });

    exe.root_module.addCSourceFile(.{
        .file = b.path("libs/stb/stb_truetype.c"),
        .flags = &.{},
    });

    exe.linkLibC();
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
