# aidev language profile — Zig
LANG_NAME="Zig"
FROZEN_PATHS=( "contracts" "tests" )
ARCHITECTURE_PATHS=( )                   # architecture is owned at the workspace root (docs/architecture)
DEPENDENCY_PATHS=( "build.zig" )         # Zig build graph (stdlib-only; no build.zig.zon)
IMPLEMENTATION_PATHS=( "src" )
# Zig analyzes lazily; build + test compilation fires the comptime signature assertions.
#
# CONFORMANCE = version pin + native build + Linux cross-compile assertion
# (ARCH-backend-linux-portability, G1/G2). The two `-Dtarget=*-linux-musl
# -Doptimize=ReleaseFast` builds are the EXACT step `tools/bench/bench_lesssheet_on`
# and `tools/netprobe/netprobe_on` perform to ship a musl-static binary, so a green
# gate means the full static library (net.zig included) cross-compiles + archives for
# both official Linux targets. Compile-only: cross tests are non-executable on the host
# and Linux TLS is not headless-verifiable — those are the human-runtime ACs (H1-H3).
# `&&`/`||` are left-associative & equal-precedence: (version || {msg;false}) && native
# && aarch64 && x86_64 — any failure fails conformance.
CONFORMANCE_CMD='[ "$(zig version)" = "0.16.0" ] || { echo "zig 0.16.0 required, found $(zig version)"; false; } && zig build && echo "GATE: cross -> aarch64-linux-musl (ReleaseFast)" && zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast && echo "GATE: cross -> x86_64-linux-musl (ReleaseFast)" && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast'
BEHAVIOR_CMD="zig build test"
CONTRACT_HOWTO="Data types: pub const structs/enums in contracts/api.zig. Signatures: comptime assertions pinning each public fn, e.g. comptime { if (@TypeOf(impl.slugify) != fn ([]const u8, ?usize) SlugResult) @compileError(\"signature drift: slugify\"); } — the compiler is the conformance check. Tests: std.testing under tests/, importing ONLY via contracts/api.zig re-exports. Implementations under src/. If this backend exposes a C ABI consumed by other components (Swift/GTK), the frozen header lives in the workspace-level api/ directory, and export fn must match it. ZIG 0.16.0 PINNED: the language churns — verify every API against the installed std source (/opt/homebrew/opt/zig/lib/zig/std/) or a tiny compiled probe before authoring; never from memory."
