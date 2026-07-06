const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Implementation module (implementer-owned, src/).
    // Links libc: the core opens/stats files and mmaps their head via the
    // POSIX/libc syscall layer (on macOS syscalls must go through libSystem).
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Frozen contract module (planner-owned, contracts/). It imports the
    // implementation to run the comptime signature pins, and the
    // implementation imports it for the shared ABI types.
    const api_mod = b.createModule(.{
        .root_source_file = b.path("contracts/api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
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

    // Zig's self-hosted archiver only guarantees 2-byte member alignment,
    // but Apple's ld64 requires 64-bit mach-o archive members to be 8-byte
    // aligned (whether a given build trips this depends on member sizes).
    // Re-pack the archive with Apple libtool so the installed
    // zig-out/lib/liblesssheet.a always links from Swift.
    // (The archiver also writes mode-000 member headers, so the objects are
    // extracted and chmod-ed before libtool re-archives them.)
    const repack = b.addSystemCommand(&.{
        "/bin/sh", "-c",
        "set -eu; " ++
            "case \"$0\" in /*) src=\"$0\";; *) src=\"$PWD/$0\";; esac; " ++
            "case \"$1\" in /*) out=\"$1\";; *) out=\"$PWD/$1\";; esac; " ++
            "tmp=$(mktemp -d); trap 'rm -rf \"$tmp\"' EXIT; " ++
            "cd \"$tmp\"; ar x \"$src\"; chmod 644 *.o; libtool -static -o \"$out\" ./*.o",
    });
    repack.addArtifactArg(lib);
    const repacked = repack.addOutputFileArg("liblesssheet.a");
    const install_lib = b.addInstallFile(repacked, "lib/liblesssheet.a");
    b.getInstallStep().dependOn(&install_lib.step);

    // Behavior tests (planner-owned, tests/) import only the contract module.
    const behavior_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "api", .module = api_mod }},
        }),
    });
    const run_behavior_tests = b.addRunArtifact(behavior_tests);
    const test_step = b.step("test", "Run behavior tests");
    test_step.dependOn(&run_behavior_tests.step);
}
