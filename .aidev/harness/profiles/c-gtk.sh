# aidev language profile — C + GTK4 (Meson)
LANG_NAME="C/GTK4 (Meson)"
ARCHITECTURE_PATHS=( "docs/architecture" )
FROZEN_PATHS=( "include" "tests" )
IMPLEMENTATION_PATHS=( "src" )
# List nested meson.build and repo-specific subprojects/*.wrap files explicitly; do not use globs or protect downloaded trees.
DEPENDENCY_PATHS=( "meson.build" "meson.options" "meson_options.txt" )
CONFORMANCE_CMD="([ -d build ] || meson setup build) && meson compile -C build"
# Strict variant (warnings as errors): CONFORMANCE_CMD="([ -d build ] || meson setup build -Dwerror=true) && meson compile -C build"
# Optional deterministic quality gate — enable during init ONLY after verifying the tool runs here:
# QUALITY_CMD="clang-format --dry-run -Werror src/*.c include/*.h"
BEHAVIOR_CMD="meson test -C build --print-errorlogs"
CONTRACT_HOWTO="Contract: function prototypes + structs in frozen include/*.h — the planner's headers ARE the signatures; compile with -Werror so drift fails compilation. Tests: GLib g_test under tests/, linked against the library. Implementations under src/. Platform note: on macOS 'brew install gtk4' allows compile-level conformance; run the behavior gate where GTK really runs (Linux container or CI)."
