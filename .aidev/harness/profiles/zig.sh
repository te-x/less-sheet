# aidev language profile — Zig
LANG_NAME="Zig"
ARCHITECTURE_PATHS=( "docs/architecture" )
FROZEN_PATHS=( "contracts" "tests" )
IMPLEMENTATION_PATHS=( "src" )
DEPENDENCY_PATHS=( "build.zig" "build.zig.zon" )
# Zig analyzes lazily; build + test compilation fires the comptime signature assertions.
CONFORMANCE_CMD="zig build"
# Optional deterministic quality gate — enable during init ONLY after verifying the tool runs here:
# QUALITY_CMD="zig fmt --check src build.zig"
BEHAVIOR_CMD="zig build test"
CONTRACT_HOWTO="Data types: pub const structs/enums in contracts/api.zig. Signatures: comptime assertions pinning each public fn, e.g. comptime { if (@TypeOf(impl.slugify) != fn ([]const u8, ?usize) SlugResult) @compileError(\"signature drift: slugify\"); } — the compiler is the conformance check. Tests: std.testing under tests/, importing ONLY via contracts/api.zig re-exports. Implementations under src/. If this backend exposes a C ABI consumed by other components (Swift/GTK), the frozen header lives in the workspace-level api/ directory, and export fn must match it."
