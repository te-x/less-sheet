const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Shipped/default optimize mode = ReleaseSafe (security-hardening MUST a,
    // ARCH-security-hardening + PROJECT.md "Build & gate"): the distributed core
    // runs with runtime safety checks ON, so a bug on untrusted CSV/gzip/network
    // input faults cleanly instead of becoming undefined behavior. `@setRuntimeSafety(false)`
    // carve-outs are added ONLY on bench-proven-over-budget loops (src/, implementer).
    //
    // We resolve `-Doptimize` MANUALLY (mirroring standardOptimizeOption's own
    // `-Doptimize` branch) rather than via `standardOptimizeOption(.{})` so that
    // (1) a bare `zig build` defaults to the shipped-safe mode, while
    // (2) `-Doptimize=<mode>` stays a valid flag: the differential C-ABI bench needs
    //     `-Doptimize=ReleaseFast` for the ReleaseSafe-vs-ReleaseFast measurement, and
    //     the gate pins `-Doptimize=ReleaseSafe` to certify exactly the shipped mode.
    // (standardOptimizeOption's `preferred_optimize_mode` would instead REMOVE
    //  `-Doptimize` in favor of `--release`, breaking those callers — verified against
    //  the installed 0.16.0 std.)
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;

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

    // Archive production is PER-TARGET (ARCH-backend-linux-portability §build.zig).
    //
    // On a macOS TARGET the installed archive is linked by SwiftPM/ld64, which
    // requires 64-bit mach-o archive members to be 8-byte aligned; Zig's
    // self-hosted archiver only guarantees 2-byte (and writes mode-000 member
    // headers). So on macOS we re-pack with Apple `ar`+`libtool` (extract,
    // chmod 644, re-archive) — the historical, SwiftPM-linking fixup.
    //
    // That step is mach-o/ld64-specific: `libtool` is a mac-only tool and the
    // 8-byte-alignment requirement is ld64's. For a non-macOS TARGET (the
    // aarch64/x86_64 -linux-musl cross-builds) it is both unnecessary and
    // impossible, so install the zig-native static archive directly — lld
    // links musl-static ELF archives without a repack. `installArtifact` of a
    // static lib installs to lib/liblesssheet.a (the same path the repack
    // writes and the bench/net cross-compile-and-ship tools expect).
    if (target.result.os.tag == .macos) {
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
    } else {
        b.installArtifact(lib);
    }

    // csv-corpus (ARCH-csv-corpus): the frozen sweep in tests/all_tests.zig
    // reads a GENERATED corpus + manifest.json via an injected `corpus` options
    // module (`corpus.dir` = the directory holding the light corpus).
    //
    // Hermetic generate-at-test (AC1): shell to the workspace-level, clean-room
    // generator (tools/csvgen/, outside this component) with a fixed seed into
    // a build-MANAGED cache dir -- never committed, never a hard-coded path --
    // and inject that dir as `corpus.dir`. zig build's cwd is the build root
    // (backend/), hence the "../tools/csvgen/..." paths resolved via
    // b.pathFromRoot.
    //
    // AC7 oracle guard: the generator's own selftest.py must pass BEFORE its
    // output is trusted, so the generate step depends on it -- a regressed
    // generator/oracle fails the build loudly instead of letting the AC2-4
    // sweeps pass vacuously against bad fixtures.
    const gen_selftest = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("../tools/csvgen/selftest.py"),
    });

    const gen = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("../tools/csvgen/gen.py"),
        "--all",
        "--seed",
        "1337",
        "--out",
    });
    gen.step.dependOn(&gen_selftest.step); // trust the oracle before generating from it
    const corpus_dir = gen.addOutputDirectoryArg("corpus");

    const corpus_opts = b.addOptions();
    corpus_opts.addOptionPath("dir", corpus_dir);
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
    run_behavior_tests.step.dependOn(&gen.step); // corpus must exist before tests run
    const test_step = b.step("test", "Run behavior tests");
    test_step.dependOn(&run_behavior_tests.step);
}
