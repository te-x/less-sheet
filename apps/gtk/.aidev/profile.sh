# aidev language profile — C + GTK4 (Meson), gated inside a Linux GNOME container
LANG_NAME="C/GTK4 (Meson)"
ARCHITECTURE_PATHS=( )                   # architecture is owned at the workspace root (docs/architecture)
FROZEN_PATHS=( "include" "tests" )
IMPLEMENTATION_PATHS=( "src" )
# Protected build/dependency files. meson.build is the build graph; .ci/Dockerfile
# PINS the toolchain image (GTK/libadwaita versions = ARCH decision-7 floor), so an
# implementer may not silently change the gate environment. No globs; both exist.
DEPENDENCY_PATHS=( "meson.build" ".ci/Dockerfile" )

# THE WHOLE GATE RUNS IN A PINNED LINUX GNOME CONTAINER (ARCH gtk-frontend
# decision 5/6 + the 2026-07-17 amendment): the dev Mac has no GTK/Meson
# toolchain, only Docker/Podman. Both CONFORMANCE (Meson compile, -Werror) and
# BEHAVIOR (Meson test) execute inside less-sheet-gtk-ci:fedora42 (built once from
# .ci/Dockerfile; GTK 4.18 / libadwaita 1.7 / meson 1.7 / gcc 15).
#
# The Zig core is cross-built to the container's arch as a GLIBC static archive
# (NOT musl — the container's GTK stack is glibc) into .core-linux/ before Meson
# runs, and linked by meson.build. The target is arch-adaptive: the podman VM /
# CI host arch selects aarch64-linux-gnu or x86_64-linux-gnu, and the SAME
# --platform is used for the container, so it always runs NATIVE (no emulation).
#
# `docker` on this Mac is a symlink to `podman`; the commands use whichever of
# docker/podman is on PATH. `--security-opt label=disable` keeps the bind-mount
# readable under the podman-machine VM's SELinux. `set -e` is wrapped in a
# subshell so the gate's own shell is unaffected.
CONFORMANCE_CMD='( set -e
  CTR="$(command -v docker || command -v podman)"
  case "$(uname -m)" in
    arm64|aarch64) ZT=aarch64-linux-gnu; PLAT=linux/arm64 ;;
    x86_64|amd64)  ZT=x86_64-linux-gnu;  PLAT=linux/amd64 ;;
    *) echo "GATE: unsupported host arch $(uname -m)" >&2; exit 1 ;;
  esac
  CORE_OUT="$PWD/.core-linux"; REPO="$(cd ../.. && pwd)"; IMG=less-sheet-gtk-ci:fedora42
  ( cd ../../backend && zig build -Dtarget="$ZT" -Doptimize=ReleaseFast -p "$CORE_OUT" )
  "$CTR" image inspect "$IMG" >/dev/null 2>&1 || "$CTR" build --platform "$PLAT" -t "$IMG" -f .ci/Dockerfile .ci
  "$CTR" run --rm --platform "$PLAT" --security-opt label=disable -v "$REPO":/src -w /src/apps/gtk "$IMG" \
    sh -c "rm -rf build && meson setup build && meson compile -C build" )'
# QUALITY_CMD deferred: needs a project .clang-format (GNU-based, ColumnLimit tuned) + a reformat pass —
# LLVM/GNU defaults diverge from the hand-written style (GNU=4613 hunks), so it is its own slice, not a
# mechanical reformat. NB: -Werror compilation is ALREADY enforced above in CONFORMANCE. Host-run once configured:
# QUALITY_CMD="clang-format --dry-run -Werror src/*.c include/*.h"
BEHAVIOR_CMD='( set -e
  CTR="$(command -v docker || command -v podman)"
  case "$(uname -m)" in
    arm64|aarch64) PLAT=linux/arm64 ;;
    x86_64|amd64)  PLAT=linux/amd64 ;;
    *) echo "GATE: unsupported host arch $(uname -m)" >&2; exit 1 ;;
  esac
  REPO="$(cd ../.. && pwd)"; IMG=less-sheet-gtk-ci:fedora42
  "$CTR" run --rm --platform "$PLAT" --security-opt label=disable -v "$REPO":/src -w /src/apps/gtk "$IMG" \
    meson test -C build --print-errorlogs )'
CONTRACT_HOWTO="Contract: function prototypes + structs in frozen include/*.h — the planner's headers ARE the signatures; compile with -Werror so drift fails compilation. include/lesssheet.h is a SYMLINK to the workspace-frozen ../../../api/lesssheet.h (single source of truth, never a copy; matches apps/macos). Tests: GLib g_test under tests/, linked against the Zig core. Implementations under src/. THE WHOLE GATE RUNS IN A LINUX CONTAINER (see CONFORMANCE_CMD/BEHAVIOR_CMD above): GTK needs a real toolchain the Mac lacks. The core is cross-built by zig to a glibc static archive (.core-linux/, arch-matched to the container) and linked by meson. Real GUI/visual checks are the author's human pass on a GNOME desktop, never headless."
