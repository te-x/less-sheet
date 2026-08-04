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
# BEHAVIOR runs the frozen suite TWICE: natively, and again on LINUX in a container.
#
# The Linux leg is not belt-and-braces -- it is the ONLY enforcement for the wave (g)
# source-fault locks. Measured (C probe, 4 shrink methods x pretouched/cold x
# +/-madvise): truncating under a live MAP_PRIVATE mapping raises SIGBUS on Linux on
# all 12 truncate arms but produces NO fault on macOS 26/APFS on all 16 -- the pages
# keep serving the original bytes. So sigbus_g1_foreground and sigbus_g1_scan can only
# FAIL on Linux, and we ship the GTK frontend there. the author approved making it
# permanent (2026-08-04) rather than relying on remembering to check by hand.
#
# The cross build produces the ELF at a stable installed path and does NOT run it
# (skip_foreign_checks), so it exits 0 having verified nothing -- which is why the
# container run asserts BOTH a zero exit AND that the binary printed a real
# "All N tests passed" line. A leg that silently stops running is worse than no leg.
#
# Container flags, each load-bearing and each verified:
#   --user 1000:1000            root can read its own mode-000 fixture, so the
#                               carry permission_denied arm fails as root
#   --tmpfs .../.zig-cache/tmp  a mode-000 file cannot be CREATED on the virtiofs
#                               bind mount by any user, and testing.tmpDir needs a
#                               writable dir; mode=1777 because the podman default is
#                               not writable by uid 1000
#   --ulimit core=0             the deliberately-killed fork children drop
#                               qemu_test_*.core into cwd under emulation
#   -w /repo/backend            the corpus path baked into the binary is RELATIVE
#                               (.zig-cache/o/<hash>/corpus), so never tmpfs
#                               .zig-cache wholesale or the corpus disappears
#
# HOST ARCH ONLY, stated rather than silently dropped: the other Linux arch runs under
# qemu and costs minutes. Cross-COMPILATION of both is still verified every run by the
# CONFORMANCE leg; running the x86_64 SUITE is an occasional manual check --
#   zig build test -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
#   podman run --rm --platform linux/amd64 --user 1000:1000 --ulimit core=0 \
#     -v "$PWD/../:/repo:Z" --tmpfs /repo/backend/.zig-cache/tmp:rw,mode=1777 \
#     -w /repo/backend registry.fedoraproject.org/fedora:43 \
#     ./zig-out/bin/behavior-tests-x86_64-linux-musl
BEHAVIOR_CMD='( set -e
  zig build test -Doptimize=ReleaseSafe
  CTR="$(command -v docker || command -v podman)"
  case "$(uname -m)" in
    arm64|aarch64) ZT=aarch64-linux-musl; PLAT=linux/arm64 ;;
    x86_64|amd64)  ZT=x86_64-linux-musl;  PLAT=linux/amd64 ;;
    *) echo "GATE: unsupported host arch $(uname -m)" >&2; exit 1 ;;
  esac
  echo "GATE: behavior -> linux ($ZT) in a container: sole enforcement for the wave (g) source-fault locks"
  zig build test -Dtarget="$ZT" -Doptimize=ReleaseSafe
  BIN="./zig-out/bin/behavior-tests-$ZT"
  test -x "$BIN" || { echo "GATE: cross test binary missing at $BIN" >&2; exit 1; }
  REPO="$(cd .. && pwd)"
  OUT="$("$CTR" run --rm --platform "$PLAT" --user 1000:1000 --ulimit core=0 \
    --security-opt label=disable -v "$REPO":/repo:Z \
    --tmpfs /repo/backend/.zig-cache/tmp:rw,mode=1777 \
    -w /repo/backend registry.fedoraproject.org/fedora:43 "$BIN" 2>&1)"
  echo "$OUT" | tail -3
  echo "$OUT" | grep -qE "All [0-9]+ tests passed" || {
    echo "GATE: the linux leg did not report a passing run: it may not have run at all" >&2; exit 1; } )'
CONTRACT_HOWTO="Data types: pub const structs/enums in contracts/api.zig. Signatures: comptime assertions pinning each public fn, e.g. comptime { if (@TypeOf(impl.slugify) != fn ([]const u8, ?usize) SlugResult) @compileError(\"signature drift: slugify\"); } — the compiler is the conformance check. Tests: std.testing under tests/, importing ONLY via contracts/api.zig re-exports. Implementations under src/. If this backend exposes a C ABI consumed by other components (Swift/GTK), the frozen header lives in the workspace-level api/ directory, and export fn must match it. ZIG 0.16.0 PINNED: the language churns — verify every API against the installed std source (/opt/homebrew/opt/zig/lib/zig/std/) or a tiny compiled probe before authoring; never from memory."
