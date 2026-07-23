# aidev language profile — Zig
LANG_NAME="Zig"
FROZEN_PATHS=( "contracts" "tests" )
ARCHITECTURE_PATHS=( )                   # architecture is owned at the workspace root (docs/architecture)
DEPENDENCY_PATHS=( "build.zig" )         # Zig build graph (stdlib-only; no build.zig.zon)
IMPLEMENTATION_PATHS=( "src" )
# Zig analyzes lazily; build + test compilation fires the comptime signature assertions.
#
# CONFORMANCE = version pin + native build + Linux cross-compile assertion
# (ARCH-backend-linux-portability, G1/G2), ALL in the SHIPPED optimize mode.
# Shipped core = ReleaseSafe (runtime safety checks ON) per ARCH-security-hardening
# MUST (a) + PROJECT.md "Build & gate": the gate must build AND test EXACTLY the mode
# we ship, so every build below pins `-Doptimize=ReleaseSafe` (was: Debug native +
# ReleaseFast cross — neither was the shipped-safe mode). build.zig's default is also
# ReleaseSafe, but the gate pins it explicitly so it certifies the shipped mode
# regardless of the default. The workspace shipping tools (`tools/bench/bench_lesssheet_on`,
# `tools/netprobe/netprobe_on`) and the frontends build the core ReleaseSafe too; the two
# `-Dtarget=*-linux-musl -Doptimize=ReleaseSafe` builds mirror the musl-static cross-ship
# step, so a green gate means the full static library (net.zig included) cross-compiles +
# archives for both official Linux targets. Compile-only: cross tests are non-executable on
# the host and Linux TLS is not headless-verifiable — those are the human-runtime ACs (H1-H3).
# `&&`/`||` are left-associative & equal-precedence: (version || {msg;false}) && native
# && aarch64 && x86_64 — any failure fails conformance.
CONFORMANCE_CMD='[ "$(zig version)" = "0.16.0" ] || { echo "zig 0.16.0 required, found $(zig version)"; false; } && echo "GATE: native -> ReleaseSafe (shipped mode)" && zig build -Doptimize=ReleaseSafe && echo "GATE: cross -> aarch64-linux-musl (ReleaseSafe)" && zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe && echo "GATE: cross -> x86_64-linux-musl (ReleaseSafe)" && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe'
# Strict deterministic formatting gate (all backend zig: src + the frozen contracts/tests + build).
QUALITY_CMD="zig fmt --check src contracts tests build.zig"
# Behavior tests run in the SHIPPED mode (ReleaseSafe) — the guard test
# "shipped optimize mode is ReleaseSafe" in tests/all_tests.zig goes RED under any
# other mode, so a gate that stopped pinning ReleaseSafe here would fail loudly.
BEHAVIOR_CMD="zig build test -Doptimize=ReleaseSafe"
CONTRACT_HOWTO="Data types: pub const structs/enums in contracts/api.zig. Signatures: comptime assertions pinning each public fn, e.g. comptime { if (@TypeOf(impl.slugify) != fn ([]const u8, ?usize) SlugResult) @compileError(\"signature drift: slugify\"); } — the compiler is the conformance check. Tests: std.testing under tests/, importing ONLY via contracts/api.zig re-exports. Implementations under src/. If this backend exposes a C ABI consumed by other components (Swift/GTK), the frozen header lives in the workspace-level api/ directory, and export fn must match it. ZIG 0.16.0 PINNED: the language churns — verify every API against the installed std source (/opt/homebrew/opt/zig/lib/zig/std/) or a tiny compiled probe before authoring; never from memory."
