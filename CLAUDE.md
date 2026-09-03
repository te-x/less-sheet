# less-sheet — workspace guide for agents

less-sheet is a read-only viewer for spreadsheet-sized CSV: plain, gzipped, or over HTTP. One Zig core
behind a frozen C ABI, two native frontends (macOS, GNOME). Open is O(viewport), never O(file).

Read `docs/architecture/PROJECT.md` (the project brief) before designing or planning anything. Every
signed design lives in `docs/architecture/ARCH-*.md`; every build cell's verdict in `review/`. This
workspace runs the aidev pipeline (roles + deterministic gate); its user-level harness and full
workflow reference live at `~/.claude/aidev/README.md`.

## Map
- `api/` — the frozen, language-neutral C header (`lesssheet.h`): the cross-component contract.
  Owned by the root planner only. Both frontends' `include/lesssheet.h` are symlinks to it.
- `backend/` — Zig **0.16.0** core, static library. Nested aidev project: frozen `contracts/`,
  `tests/`, `build.zig`; implement in `src/`.
- `apps/macos/` — Swift 6 / SwiftPM app, macOS 26+. Nested aidev project: frozen `Sources/Contracts`,
  `Tests`, `Package.swift`; implement in `Sources/LessSheetApp`, `Sources/LessSheetKit`, `Sources/CLessSheet`.
- `apps/gtk/` — C + GTK4/libadwaita GNOME app (Meson). Nested aidev project: frozen `include/`, `tests/`;
  protected build files `meson.build`, `.ci/Dockerfile`, `.clang-format`; implement in `src/`. Its
  WHOLE gate runs inside a pinned Fedora container — the Mac has no GTK toolchain.
- `docs/architecture/` — brief + signed ARCH docs (root-protected). `review/` — review records.
  `tools/` — fuzzing (`fuzz/`), fixture generator (`csvgen/`), release scripts (`release/`),
  screenshot tooling (`shots/`). `site/` — landing page. `branding/icon.svg` — the ONE icon source;
  every platform icon is generated from it. `packaging/` — Homebrew cask + Flatpak manifests.

## Toolchain (exact versions matter)
- Zig **0.16.0** exactly — the backend gate asserts it. Homebrew installs it at `/opt/homebrew/opt/zig`.
- macOS: Xcode with the Swift 6 toolchain, deployment target macOS 26; `swiftlint`.
- GTK and the backend's Linux leg: `docker` or `podman` (the GTK image is built once from
  `apps/gtk/.ci/Dockerfile`; the backend's Linux tests run in a stock `fedora:43`); `clang-format`.
- `python3` (stdlib only) for `tools/csvgen`.

## Build, test, run — per component (what the gates run)
- **Backend** (`cd backend`): `zig build -Doptimize=ReleaseSafe` · tests `zig build test -Doptimize=ReleaseSafe`
  (the gate also cross-builds `aarch64-/x86_64-linux-musl` and runs the Linux test binary in a
  container) · format `zig fmt --check src contracts tests build.zig`.
  **ReleaseSafe is the shipped mode** — this app ingests untrusted files and URLs; never "optimize" back
  to ReleaseFast.
- **macOS** (`cd apps/macos`): `swift build -Xswiftc -warnings-as-errors` · `swift test` ·
  `swiftlint lint --strict Sources` (zero violations, nothing relaxed). App bundle:
  `bash apps/macos/scripts/assemble-app.sh` — the only thing that refreshes the `.app`; the user runs
  the assembled bundle, so reassemble after a frontend change before asking for a visual check. SwiftPM
  does not track the Zig `.a`: after rebuilding the backend,
  delete `.build/*/{debug,release}/LessSheet` (the gate does) or you test a stale link.
- **GTK** (`cd apps/gtk`): the gate cross-builds the core to `.core-linux/` (glibc, arch-matched), then
  `meson setup build && meson compile -C build && meson test -C build` inside `less-sheet-gtk-ci:fedora43`
  · format `clang-format --dry-run -Werror src/*.c include/lsg_*.h`. Headless look: run `build/less-sheet-gtk`
  under `Xvfb` in a throwaway container derived from the CI image with `GSK_RENDERER=cairo GTK_A11Y=none`
  (`ADW_DEBUG_COLOR_SCHEME=prefer-dark` for dark).
- **Headless macOS verification**: `LESSSHEET_DUMP_FRAME=<png> LESSSHEET_DUMP_SCENE=<scene>` renders a
  scene off-screen (`FrameDump.swift` lists them; `launch` needs no file). Never use screen capture or
  anything that fires a macOS permission (TCC) prompt; hand visual checks to the user.

## Gates — the enforcement
- Component gates: `bash backend/.aidev/gate.sh backend` · `bash apps/macos/.aidev/gate.sh apps/macos` ·
  `bash apps/gtk/.aidev/gate.sh apps/gtk`.
- Root gate (api/ + docs/architecture + harness integrity, then every component gate): `bash .aidev/gate.sh`.
  Run it at every cell boundary; a green component gate says nothing about the root's protected surface.
- `.aidev/gate.sh` and `.aidev/freeze.sh` are thin wrappers that exec the user-level harness at
  `~/.claude/aidev/`. Without the harness, run the per-component commands above by hand; the frozen-path
  rules below still apply.
- A green gate is necessary, not sufficient: reviewers have caught real bugs (an invalid-UTF-8 data-loss
  path, a hang the tests could not express) that a green gate missed. Look at the output and the image.

## How work happens (aidev pipeline)
- Roles, configured in `.aidev/roles.json` and materialized as `.claude/agents/*.md`: **architect**
  (designs live with the user → signed ARCH doc), **planner** (freezes the contract: types + signatures +
  tests, and commits it — git arms the anti-tamper gate), **implementer** (fills bodies; may not touch
  frozen paths or `.aidev/*` except `CHANGE-REQUEST.md`), **reviewer** (independent verdict, never edits).
- New feature: `/aidev:feature <name + description>` then `/aidev:build <name>`. The orchestrator itself
  runs `bash .aidev/gate.sh` to accept success — never take a role's word for it.
- Contract change = a two-key `.aidev/CHANGE-REQUEST.md` (implementer + reviewer) adjudicated by the
  planner. After any approved change to a protected surface, re-pin its baseline with
  `bash <component>/.aidev/freeze.sh <component>` (root: `bash .aidev/freeze.sh .`) and commit it.
- Pre-release, no external ABI consumers: changing a frozen surface means deleting the old shape, not
  adding a compatibility layer. Retire dead behavior fully.

## Zig 0.16.0 — docs first, memory last (MANDATORY)
Zig is pinned to **0.16.0** and the language churns faster than training data — pre-0.16 idioms
(build API, ArrayList, io reader/writer, mem …) are often wrong now. Before writing or reviewing ANY Zig:
1. **Grep the installed std source** at `/opt/homebrew/opt/zig/lib/zig/std/` — the authoritative
   0.16.0 API (e.g. `grep -n "pub fn addLibrary" /opt/homebrew/opt/zig/lib/zig/std/Build.zig`).
2. `zig std` serves the std docs locally; `zig build --help` lists current build options.
3. Language reference for exactly this version: https://ziglang.org/documentation/0.16.0/
4. Still unsure? Compile a tiny probe — the compiler is the final word.

## Standing rules
- **Cold-start budget**: launch → first rows visible in **< 500 ms** on every frontend; open is
  O(viewport). No file type may read the whole file before first paint; network sources fetch by range.
  Any change that reads a whole file before first paint is a performance bug.
- **Works or fails gracefully**: never a crash, silent wrong data, or undefined behavior. Malformed input
  → a clean error. Fuzz the parser (`tools/fuzz`) when touching it; a ReleaseSafe panic still counts as a crash.
- **Performance is measured**: any perf-relevant change gets a before/after on the same build session,
  reported as a delta. Reclaim speed by safe restructuring, never by removing safety checks.
- **Per-document state is session-only**: dialect, columns, filters, find, jump are never persisted.
- **Long operations show progress**: anything over ~500 ms shows a progress or loading state; the UI
  never blocks silently.
- **Native and current**: default platform UI over custom, latest stable toolchains; the macOS app is the
  design template for other frontends — port its settled decisions, interview only platform deltas.
- **One source of truth per knob**: a tunable is one named constant plus one resolver; consumers read it.
- **Commit hygiene**: no AI co-author trailers; no personal names, machine hostnames, LAN addresses or
  home paths anywhere in files or messages. Verify with the identity sweep before pushing.
