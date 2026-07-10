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

    // csv-corpus (ARCH-csv-corpus): the frozen sweep in tests/all_tests.zig
    // reads a GENERATED corpus + manifest.json via an injected `corpus` options
    // module (`corpus.dir` = the directory holding the light corpus).
    //
    // RED SEED (planner freeze): the `corpus` module EXISTS so the frozen test
    // COMPILES, but the generator run is deliberately NOT wired, so `corpus.dir`
    // points at a path with no manifest.json -> the sweep fails at runtime with
    // error.CorpusNotGenerated (behavior RED, not a compile/import failure).
    //
    // IMPLEMENTER makes it GREEN (this file is NOT frozen): run the generator
    // into a build-cache dir, inject that dir as `corpus.dir`, and gate the
    // behavior-test run on it -- e.g. replacing the placeholder addOption below:
    //   const gen = b.addSystemCommand(&.{ "python3",
    //       b.pathFromRoot("../tools/csvgen/gen.py"), "--all", "--seed", "1337", "--out" });
    //   const corpus_dir = gen.addOutputDirectoryArg("corpus");
    //   corpus_opts.addOptionPath("dir", corpus_dir);        // <- replaces addOption
    //   run_behavior_tests.step.dependOn(&gen.step);         // <- generate before tests
    // and run tools/csvgen/selftest.py as the AC7 oracle guard (fail-fast).
    // Nothing generated is committed; python3 is a documented gate prerequisite.
    const corpus_opts = b.addOptions();
    corpus_opts.addOption([]const u8, "dir", "/nonexistent/lesssheet-corpus--generate-step-not-wired");
    const corpus_mod = corpus_opts.createModule();

    // Behavior tests (planner-owned, tests/) import only the contract module
    // (`api`) and the injected corpus locator (`corpus`).
    const behavior_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "api", .module = api_mod },
                .{ .name = "corpus", .module = corpus_mod },
            },
        }),
    });
    const run_behavior_tests = b.addRunArtifact(behavior_tests);
    const test_step = b.step("test", "Run behavior tests");
    test_step.dependOn(&run_behavior_tests.step);
}
