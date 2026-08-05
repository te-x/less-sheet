//! tools/fuzz — dev-only build graph for the security-hardening wave (c) fuzz
//! harness. NOT part of any gate (AC-c3: "not gate-blocking, one-time cadence").
//!
//! Why a build graph of its own rather than a step in `backend/build.zig`:
//! `backend/build.zig` is a FROZEN dependency path (`backend/.aidev/profile.sh`
//! `DEPENDENCY_PATHS=( "build.zig" )`) and an implementer may not edit it. This
//! file reaches into the component instead, exactly the way the component
//! already reaches out to `tools/csvgen` — it rebuilds the same two-module graph
//! `backend/build.zig` builds (implementation `src/root.zig` <-> frozen contract
//! `contracts/api.zig`, mutually imported, libc linked), so the harness compiles
//! the SAME code the shipped static library compiles, including the contract's
//! comptime C-ABI signature pins.
//!
//! Optimize mode defaults to ReleaseSafe — the shipped mode, and the mode AC-c1
//! requires the campaign to run in. `-Doptimize=` stays available for A/B work.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;

    // --- the backend core, wired exactly as backend/build.zig wires it -------
    const core_mod = b.createModule(.{
        .root_source_file = b.path("../../backend/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const api_mod = b.createModule(.{
        .root_source_file = b.path("../../backend/contracts/api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    api_mod.addImport("core", core_mod);
    core_mod.addImport("api", api_mod);

    // --- the fuzz target binary --------------------------------------------
    // Named `lsfuzz` on purpose: `--fuzz` REBUILDS the test binary with
    // `-ffuzz` into `.zig-cache/o/<hash>/lsfuzz`, and `covreport` has to find
    // that exact rebuilt binary to resolve PCs to source lines. A distinctive
    // name makes the lookup unambiguous (see fuzz.sh).
    // `-Donly=<substr>` restricts the binary to the matching fuzz target(s).
    // Essential for triage: a hang or crash in one target otherwise blocks every
    // other target's replay and campaign, and "which target" is the first
    // question a finding raises.
    const only = b.option([]const u8, "only", "Only build/run targets whose test name contains this substring");

    // `-Dseed-limit=N` replays only the first N entries of each pack (0 = all).
    // Triage lever: it is what distinguishes "this target is slow" from "this
    // target is wedged" — time N=1, 10, 70 and look at the scaling. Also gives a
    // fast smoke replay without touching the committed corpus.
    const seed_limit = b.option(usize, "seed-limit", "Replay only the first N corpus entries per target (0 = all)") orelse 0;
    const opts = b.addOptions();
    opts.addOption(usize, "seed_limit", seed_limit);

    const harness = b.addTest(.{
        .name = "lsfuzz",
        .filters = if (only) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "api", .module = api_mod },
                .{ .name = "build_options", .module = opts.createModule() },
            },
        }),
    });
    const run_harness = b.addRunArtifact(harness);
    // The corpus replay must re-run on demand, not report a cache hit; and
    // `--fuzz` only discovers fuzz tests from a run step that actually ran.
    run_harness.has_side_effects = true;
    const test_step = b.step("test", "Replay the committed seed corpus once per entry (no fuzzing)");
    test_step.dependOn(&run_harness.step);
    b.default_step.dependOn(&run_harness.step);

    // --- the matcher differential oracle -----------------------------------
    // A VALUE oracle, unlike the four crash-oriented targets above: it pins that
    // the streaming matcher, the whole-cell matcher and a naive reference agree
    // on every verdict (see matcher_diff.zig). It needs matcher.zig's internals
    // (StreamCell / cellMatches / Query), which the C ABI does not expose, so
    // it reaches them through the ONE dev-tool re-export in src/root.zig
    // (`matcher_internals`) — a module rooted at src/matcher.zig is impossible
    // here, because every src file would then belong to two modules at once
    // (`api` already pulls src/root.zig in as `core`).
    const diff = b.addTest(.{
        .name = "lsdiff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("matcher_diff.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "core", .module = core_mod }},
        }),
    });
    const run_diff = b.addRunArtifact(diff);
    run_diff.has_side_effects = true;
    const diff_step = b.step("diff", "Run the matcher differential oracle (deterministic sweep; add --fuzz to explore)");
    diff_step.dependOn(&run_diff.step);
    // Part of `test` too: the oracle is cheap and a mismatch is a real defect.
    test_step.dependOn(&run_diff.step);

    // --- the coverage report tool ------------------------------------------
    const covreport = b.addExecutable(.{
        .name = "covreport",
        .root_module = b.createModule(.{
            .root_source_file = b.path("covreport.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(covreport);
    const cov_step = b.step("covreport", "Build the coverage-report decoder");
    cov_step.dependOn(&b.addInstallArtifact(covreport, .{}).step);

    // --- the seed-corpus generator -----------------------------------------
    const seedgen = b.addExecutable(.{
        .name = "seedgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("seedgen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(seedgen);
    const seedgen_step = b.step("seedgen", "Build the seed-corpus generator");
    seedgen_step.dependOn(&b.addInstallArtifact(seedgen, .{}).step);
}
