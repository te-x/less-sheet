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

    // Bundle Zig's compiler-rt into the archive ON x86 ONLY.
    //
    // Not a new dependency: compiler-rt is Zig's own runtime-support code (as libgcc
    // is gcc's), it ships inside the pinned toolchain, and this is a build setting on
    // our own static library. The approved stack is unchanged; no third party is added.
    //
    // WHY. On x86 the compiler emits calls to `__zig_probe_stack` for large stack
    // frames. `std.Build`'s default for this field is `null` = "let the compiler
    // decide", which bundles compiler-rt only for an exe or a dynamic library
    // (Step/Compile.zig) -- so our STATIC library referenced that symbol without
    // defining it. Measured with `nm` on the installed liblesssheet.a:
    //
    //   x86_64-linux-gnu / -musl   1 undefined, 0 defined
    //   aarch64-linux-gnu / -musl  0 undefined, 0 defined  (that arch emits no probes)
    //   aarch64-macos              0 undefined, 0 defined
    //
    // It stayed hidden because every previously verified Linux link was performed BY
    // ZIG (lld), which supplies compiler-rt for the final executable itself. The GTK
    // frontend instead links this archive with gcc/ld.bfd against glibc, and nothing
    // there provides a Zig-specific symbol -- so x86_64 Linux, the majority desktop
    // architecture, could not be linked at all. Verified in a fedora:43 amd64
    // container with gcc 15.3.1 / GNU ld 2.45.1: before, four `undefined reference to
    // '__zig_probe_stack'` errors and no binary; after, the link succeeds and runs.
    // Fixing it in the archive fixes every consumer and every linker at once, instead
    // of pushing a `-fcompiler-rt`-shaped workaround into each frontend's build.
    //
    // WHY x86 ONLY, and not simply always. compiler-rt arrives as ONE archive member,
    // so a linker that needs any symbol from it pulls all ~1.1 MiB in; `--gc-sections`
    // recovers only ~180 KiB of that (measured). aarch64 already resolves the two
    // builtins it actually uses (`__divti3`, `__udivti3`) from libgcc, so bundling
    // there is pure cost: it grew the linked aarch64 binary 8322896 -> 9437272 bytes
    // (+13.4%) while ALSO silently displacing libgcc's division routines with Zig's
    // weak ones -- an unforced change to the aarch64 path that was verified on real
    // hardware (ARCH-backend-linux-portability, commit e3d9b6e). Scoping the setting
    // to the architecture that has the defect keeps every non-x86 artifact
    // byte-for-byte identical to that proven one: the field stays `null` there, so no
    // flag is added to the command line at all (deliberately not `= false`, which
    // would pass `-fno-compiler-rt` and perturb a working build for no reason).
    //
    // `isX86()` covers x86_64 plus 32-bit x86, i.e. wherever the stack-probe call is
    // emitted -- including a future x86_64 Windows or Intel-macOS target. Should some
    // other architecture ever need a Zig runtime symbol, it fails the way this did:
    // a loud undefined-reference at frontend link time, never silent misbehavior.
    //
    // Safe on the targets it does apply to: every externally visible symbol in
    // compiler_rt.o is a WEAK definition (measured: 461 weak, 0 strong globals), so
    // its `memcpy`/`memset`/`memmove`/`memcmp` and math builtins cannot collide with
    // glibc, musl, libgcc or libSystem -- their strong definitions still win.
    if (target.result.cpu.arch.isX86()) lib.bundle_compiler_rt = true;

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

    // Stable, per-target install path for the test binary
    // (ARCH-security-hardening (g), source-fault guard).
    //
    // The two locks that PROVE the SIGBUS guard -- `sigbus_g1_foreground` and
    // `sigbus_g1_scan` -- are only enforceable on Linux: truncating a file under a
    // live MAP_PRIVATE mapping keeps serving the original bytes on macOS 26/APFS
    // (measured, 16 arms) while Linux faults on all 12 truncate arms. So the suite
    // also runs on Linux, in a container, from a binary CROSS-BUILT here.
    //
    // That container leg has to NAME the binary. Zig otherwise leaves it at a
    // content-hashed cache path (.zig-cache/o/<hash>/test) whose hash changes with
    // every source edit, so the only way to find it was to scrape it out of the
    // build's FAILURE message -- a gate leg resting on a non-zero exit and an error
    // format, i.e. one that could one day match nothing and pass silently. Install
    // it instead, under a predictable basename. The target triple is part of the
    // name so the native leg and the two cross legs never overwrite each other:
    //
    //   zig build test                                 -> zig-out/bin/behavior-tests-aarch64-macos-none
    //   zig build test -Dtarget=aarch64-linux-musl ... -> zig-out/bin/behavior-tests-aarch64-linux-musl
    //   zig build test -Dtarget=x86_64-linux-musl ...  -> zig-out/bin/behavior-tests-x86_64-linux-musl
    //
    // Attached to the `test` step only, never to `b.getInstallStep()`: a bare
    // `zig build` (the conformance leg) keeps building just the library, with no
    // new dependency on the python3 corpus generator.
    const install_behavior_tests = b.addInstallArtifact(behavior_tests, .{
        .dest_sub_path = b.fmt("behavior-tests-{s}-{s}-{s}", .{
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            @tagName(target.result.abi),
        }),
    });

    const run_behavior_tests = b.addRunArtifact(behavior_tests);
    run_behavior_tests.step.dependOn(&gen.step); // corpus must exist before tests run

    // A foreign suite can only be PRODUCED here, not executed: skip -- rather than
    // fail -- the run when the host cannot spawn the target binary, so
    // `zig build test -Dtarget=*-linux-musl` exits 0 with the ELF installed above
    // and the container leg does the running. This does NOT weaken the native leg:
    // for a host target the binary spawns and runs, and a failing test fails the
    // build exactly as before (verified against the installed 0.16.0 std --
    // Step.Run reaches this only from the `error.InvalidExe` spawn path, where the
    // `.bad_os_or_cpu` branch then returns `MakeSkipped` instead of `step.fail`,
    // and a skipped step is counted apart from failures by the build runner). If a
    // foreign executor IS configured (rosetta / -fqemu / binfmt_misc), the tests
    // still actually run.
    run_behavior_tests.skip_foreign_checks = true;

    const test_step = b.step("test", "Run behavior tests (foreign target: build + install only)");
    test_step.dependOn(&install_behavior_tests.step);
    test_step.dependOn(&run_behavior_tests.step);
}
