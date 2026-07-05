const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "lesssheet",
        .linkage = .static,
        .root_module = core_mod,
    });
    b.installArtifact(lib);

    const behavior_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lesssheet", .module = core_mod }},
        }),
    });
    const run_behavior_tests = b.addRunArtifact(behavior_tests);
    const test_step = b.step("test", "Run behavior tests");
    test_step.dependOn(&run_behavior_tests.step);
}
