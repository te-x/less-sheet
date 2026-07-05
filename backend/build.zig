const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Implementation module (implementer-owned, src/).
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Frozen contract module (planner-owned, contracts/). It imports the
    // implementation to run the comptime signature pins, and the
    // implementation imports it for the shared ABI types.
    const api_mod = b.createModule(.{
        .root_source_file = b.path("contracts/api.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_mod.addImport("core", core_mod);
    core_mod.addImport("api", api_mod);

    // The static library is rooted at the CONTRACT: building it compiles the
    // pins (conformance) and emits the `ls_*` C-ABI exports from src/.
    const lib = b.addLibrary(.{
        .name = "lesssheet",
        .linkage = .static,
        .root_module = api_mod,
    });
    b.installArtifact(lib);

    // Behavior tests (planner-owned, tests/) import only the contract module.
    const behavior_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "api", .module = api_mod }},
        }),
    });
    const run_behavior_tests = b.addRunArtifact(behavior_tests);
    const test_step = b.step("test", "Run behavior tests");
    test_step.dependOn(&run_behavior_tests.step);
}
