# ARCH — gtk-frontend (a GNOME-native GTK4 frontend at feature/interaction parity with macOS)

Status: APPROVED — signed off by the author 2026-07-17 (decisions 7 & 8 ratified; decision 5 amended to whole-gate-in-container). AMENDED 2026-07-21 (the author-signed, via `ARCH-gtk-a11y.md`): decision 6 gate container `fedora:42` → `fedora:43`; decision 7 floor → GTK 4.20 / libadwaita 1.8 (for `AdwShortcutsDialog`). Roadmap priority #2. Greenfield new component
`apps/gtk/` (analogous to `apps/macos/`). Workspace-level ARCH.
Prerequisite MET: backend Linux portability merged to master (`4b2b338`) — the core cross-compiles and
runs on `aarch64`/`x86_64` Linux (`ARCH-backend-linux-portability.md`).

**Read first:** `docs/architecture/PROJECT.md` (brief, hard constraints, glossary), `CLAUDE.md` (workspace
guide, budgets), the frozen `api/lesssheet.h` (the entire ABI this frontend consumes), and — as the
**authoritative design baseline** — `apps/macos/` (the already-settled interaction model, the O(viewport)
grid technique, the two-lane threading discipline). This feature REPLICATES the settled macOS design on
GNOME; it does not re-derive it.

---

## Problem & scope

less-sheet has one shared native core (Zig, behind the frozen C ABI) and, today, one frontend (macOS /
Swift). Roadmap #2 is a **second frontend for GNOME/Linux at feature- and interaction-parity with the
macOS app**, reusing the core over `api/lesssheet.h` with **zero re-implementation** of the matcher,
copy, network, windowing, or type inference. The macOS frontend is the settled reference: its design,
interaction model, and performance philosophy are **GIVENS**, identical for Linux, and are recorded here
as inherited — not questioned.

**In scope (v1 = full macOS parity):** a new `apps/gtk/` component — C + GTK4 + libadwaita over the
frozen ABI — that opens local and network (HTTP/S, `.csv` / `.csv.gz`) delimited files instantly, renders
a virtualized O(viewport) grid, and provides find (text + typed predicate), jump-to-row,
filter-to-matches, streaming rectangular copy, column configuration (Settings), dialect override, a launch
screen, keyboard shortcuts, row-count/scan progress, and error reporting — behaving equivalently to macOS.

**Non-goals (explicit):**
- **NOT changing the ABI.** `api/lesssheet.h` is consumed unchanged; this is a pure consumer, no
  additions, no two-key amendment. Any perceived gap is a separate feature, not part of this one.
- **NOT re-implementing core data logic.** Matching, search/nav counts, filtered views, windowed reads,
  jump/scan, dialect sniffing, encoding detection/transcode, column-type inference, match-flags, and
  streaming TSV copy all come from the core (`ls_*`). The frontend owns only presentation and event glue.
- **Accessibility is DEFERRED to a later pass** (the author, 2026-07-16). v1 ships without an AT-SPI accessible
  tree over the custom grid; the design keeps that pass cheap (standard Adwaita chrome is accessible for
  free; the custom canvas gets `GtkAccessible` roles later — GTK4 supports non-widget accessible children).
  Keyboard-driven interaction (find/jump/copy/nav shortcuts) still ships in v1 as ordinary UX.
- **NOT pixel-identical to macOS.** The bar is INTERACTION parity, not pixel parity. GNOME-native chrome
  (Adwaita) replaces the macOS chromeless Liquid-Glass look (Liquid Glass has no GTK equivalent).
- **NOT Windows.** Out of scope (the core's Windows Source seam is unbuilt; `ARCH-backend-linux-portability.md`).
- **NOT a TUI.** A separate future possibility.

---

## Inputs / Outputs

**Inputs.** Identical to macOS, all mediated by the ABI:
- A local file path (`ls_open`) from: `argv`, the file manager (open/associate), drag-onto-window, or the
  in-app open dialog (`GtkFileDialog`).
- A URL string (`ls_open_url_start`) for HTTP/S `.csv` / `.csv.gz`, via an in-app "Open URL" entry.
- User gestures: scroll/keyboard navigation, find queries (text substring or column predicate
  `= ≠ < > ≤ ≥`), jump target (row number), filter set/clear, rectangular/row/column selection + copy,
  dialect overrides (separator / quote / header / encoding), column config (visibility / type override /
  null sentinel / width / number-format / date-preset).

**Outputs.**
- On-screen: the virtualized grid (header row + row-number gutter + cells), find highlights, selection,
  progress/estimate indicators, banners/toasts, error panels — all drawn from theme colors.
- To the system clipboard: TSV built by the core's streaming copy (`ls_copy_*`), byte-identical framing
  across frontends (the core owns TAB/LF/quoting; the frontend writes the assembled bytes to
  `GdkClipboard`).
- Presentation transforms the frontend owns (never the source, never the core): locale-aware number/date
  formatting, column width heuristics, row-count abbreviation, error fact/fix strings.

**Error cases** (parity with macOS taxonomy): open failures map from `ls_status`
(`LS_ERROR_NOT_FOUND` / `PERMISSION_DENIED` / `IO` / `INVALID_ARGUMENT`) to specific in-window fact+fix
panels; network opens surface the net status taxonomy (unreachable / TLS / HTTP status / not-found /
too-large / decode / cancelled) with their own panel/banner. An empty document opens as a valid 0-row grid.

---

## Functional requirements

Every item below is INHERITED from `apps/macos/` and must behave equivalently (interaction parity):

1. **Instant open + virtual scroll.** Open local or network; first rows visible within the cold-start
   budget; scroll smoothly over multi-GB / millions-of-rows files with no stall. Only the visible window
   (+ scroll buffer) is ever materialized.
2. **Grid rendering.** Sticky header row, row-number gutter (original row number under a filter, via
   `ls_source_row`), per-column alignment, truncation markers (`ls_cell_truncated`), oversized-row markers
   (`ls_row_oversized`), type-aware display formatting, column resize + auto-fit.
3. **Find.** Text mode (smart-case substring over visible columns) and predicate mode (column + operator +
   value); live match count (`n of m`), scanning progress + cancel, wrap-to-start/end notices. Highlights
   sourced from `ls_window_match_flags` (subtle for in-scope matches, strong for the current match) — no
   frontend matcher.
4. **Filter to matches.** Toggle in the find UI; filtered view swaps the gutter to original row numbers;
   a banner shows "Filtered — N of ~M rows" / "no matching rows".
5. **Jump to row.** Digit entry; asynchronous scan with progress + cancel; rejection feedback; under a
   filter the target is an original row number and lands on the filtered index.
6. **Streaming copy.** Rectangular cell selection, whole-row (gutter), whole-column (header) selection;
   `Ctrl+C` streams TSV off the UI thread via `ls_copy_*` with a progress/cancel notice; frontier stalls
   handled via `ls_jump_start` + resume; single-cell raw special-case preserved.
7. **Column configuration (Settings).** A parsing section (header toggle, separator, quote, encoding) plus
   a searchable column list (visibility) and a per-column inspector (visibility, type override + datetime
   semantics + reset-to-auto, status, null sentinel, width + auto-fit, number-format grouping/fraction
   digits, date preset). Backed by `ls_column_*`.
8. **Dialect override.** Separator / quote / header changed from the main UI (re-open under the hood);
   encoding changed in Settings. Guess indicators show sniffed-vs-forced.
9. **Launch screen.** With no document open, a status page naming the two shortcuts (Open / Open URL); does
   not auto-open a dialog.
10. **Keyboard shortcuts & menu.** GNOME conventions (Ctrl, not Cmd): Open, Open URL, Find, Find Next/Prev,
    Jump, Select-All, Copy, Escape, arrow / shift-arrow selection.
11. **Progress & no silent stalls.** Every non-instant operation (indexing, jump-scan, search, filter-scan,
    network fetch, copy) shows constant feedback from t0 and never blocks the UI thread.

---

## Non-functional constraints (verified by measurement, not claim)

- **Cold-start is a CEILING to beat, not a target.** launch → first rows visible **< 500 ms** on
  commodity Linux hardware; recommend for the lowest achievable, not merely "under 500 ms". Open is
  **O(viewport), never O(file)**: no path reads/parses/copies the whole file before first paint
  (guaranteed structurally by the ABI's O(head) open + the viewport-only draw).
- **Viewport-only materialization.** The grid NEVER enumerates or realizes all rows/cells. It materializes
  only the visible window (~1000 cells) plus a scroll buffer via `ls_window_set`, and only the visible
  horizontal column window (wide 100k-col docs stay O(hundreds of columns), never O(column_count)).
- **Steady-state memory** scales with the materialized window + the core's sparse index, never with file
  size or row count (an inherited core guarantee; the frontend adds only O(viewport) widgets/buffers).
- **Two-lane threading honored.** The window lane (`ls_window_set` + cell reads) is caller-serialized; the
  poll/control lane is any-thread. The UI runs on the GLib main loop; a worker polls the core (~100 ms) and
  folds snapshots back via the main context; long operations (copy, open) run off the UI thread. Distinct
  locks for the window lane vs the copy/control lane (mirroring macOS) so a background copy runs concurrent
  with live scrolling; `ls_close` acquires both in a fixed order.
- **Binary size** stays within the project's single-digit-MB budget (informs the ICU decision below).
- **Theming, no hardcoded colors.** Follows GNOME light/dark and the system accent live; all grid colors
  pull from the active theme (accent for highlights, a muted theme color for selection).

---

## Component decomposition & data flow

New component `apps/gtk/` (greenfield, scaffolded via the `c-gtk` aidev profile after sign-off). Layered to
mirror the macOS separation (binding shim → core session wrapper → pure logic → widgets/app), so the
non-GUI logic is unit-testable headlessly and only rendering needs a display.

- **C ABI shim (`include/` + the binding).** `include/lesssheet.h` is a **checked-in symlink** to the
  frozen `../../api/lesssheet.h` (single source of truth, exactly as macOS's `CLessSheet` does — never a
  copy). The frontend `#include`s it and links `liblesssheet.a`.
- **Core session wrapper (`src/core_session.*`).** The single place that calls `ls_*` (mirrors
  `CoreDocumentSession.swift`): open/close, window-lane reads (window/cell/source-row/match-flags),
  poll/control-lane calls (index/jump/search/filter/column/net/copy). Owns the two lane locks (`GMutex`),
  copies every borrowed `ls_str`/flag buffer out immediately (invalid UTF-8 → U+FFFD), and runs
  copy/open on worker threads (`GTask` / `GThread`).
- **Pure view-model logic (`src/*_logic.*`).** Display-only, no widgets, no display server — unit-testable
  with `g_test`: window-poll decision (materialize/keep-polling), find/filter/jump control state machines,
  streaming-copy chunk assembly + clipboard-string build, column-config reducers, dialect compose, column
  layout / width math, selection rect algebra, and the locale number/date formatter. Direct C analogs of
  the macOS `LessSheetKit` logic files.
- **Grid widget (`src/grid.*`).** A custom `GtkDrawingArea` painting via Cairo + PangoCairo (its `draw_func`, GSK-composited) with Pango text,
  driven by a hand-managed `GtkAdjustment` + `GtkScrollbar` (uniform row height ⇒ O(1) geometry; content
  height = `row_estimate * row_height`; the filler/overscroll strip below EOF). It hand-draws the header,
  gutter, cells, hairlines, highlights (from `ls_window_match_flags`), selection, and markers; implements
  its own x→column hit-testing and key/scroll/gesture handling (`GtkGestureClick`, `GtkEventControllerKey`,
  `GtkEventControllerScroll`, motion). `clip`/adjustment changes trigger a viewport-changed callback →
  materialize only the visible window/columns. Estimate changes adjust the `GtkAdjustment` upper (O(1),
  deferred during kinetic/overscroll to avoid perturbing the scroll).
- **Chrome / app shell (`src/app.*`, `src/window.*`, `src/settings.*`).** `AdwApplication` +
  `AdwApplicationWindow` + `AdwToolbarView` + `AdwHeaderBar`; find/jump as `GtkPopover`; filter and
  network-open state as `AdwBanner`; copy/dialect notices as `AdwToast`; launch/empty/error states as
  `AdwStatusPage`; Settings as an `AdwPreferencesDialog` (decision 3, amended 2026-07-20; a "Parsing" page +
  a "Columns" page of per-column inspectors via `AdwExpanderRow`/`AdwComboRow`/`AdwSwitchRow`/`AdwSpinRow`).
  Actions via `GAction` + `GtkShortcutController`.

**Data flow (unchanged from macOS):** UI gesture → session wrapper → `ls_*` (control lane) → worker poll
folds the resulting snapshot on the main loop → view-model decides repaint/materialize → grid reads the
freshly materialized window (window lane) + match-flags → snapshot paint. Cold open runs `ls_open` off the
UI thread; the first window is served from the core's post-open frontier (O(head)).

**Reused (from the core, unchanged):** the entire `ls_*` surface. **Reused (from macOS as a design
template, re-expressed in C):** the layer boundaries, the poll/decide loop, the O(viewport) grid technique,
the width-heuristic trick, the two-lock discipline. **Added (new, this feature):** all of `apps/gtk/`.
**Deleted:** nothing.

---

## External interfaces

- **Consumes `api/lesssheet.h`** (frozen; zero change). All of: `ls_open`/`ls_close`/`ls_open_options`/
  `ls_dialect_get`/`ls_column_count`/`ls_row_count_get`/`ls_index_poll`; `ls_open_url_*`/`ls_net_open_*`;
  `ls_window_set`/`ls_cell`/`ls_cell_truncated`/`ls_row_oversized`/`ls_header_cell`/`ls_header_cell_truncated`/
  `ls_source_row`/`ls_window_match_flags`; `ls_jump_*`; `ls_search_*`; `ls_filter_*`; `ls_cell_copy`;
  `ls_copy_open`/`ls_copy_next`/`ls_copy_close`; `ls_column_*`.
- **Links `liblesssheet.a`** — the now-Linux-portable static library produced by `zig build` for the
  native Linux target (glibc). No IPC, no helper process (a process boundary would blow cold-start).
- **System / GNOME:** GTK4, libadwaita, GLib/GIO/GObject, Pango, GDK; `GdkClipboard`, `GtkFileDialog`,
  `AdwStyleManager` (dark/light + accent), `GSettings` (window state / preferences persistence),
  `GDateTime` + the C-library locale for formatting. The desktop-file / icon for file association.

---

## Technology decisions (chosen option, alternatives, rationale)

Decisions 1–4 were made WITH the author (2026-07-16→17) and are settled. Decisions 5–6 are engineering choices
baked in here. Decisions 7–8 (**marked ▶ CONFIRM AT SIGN-OFF**) carry my recommendation; the author confirms
them when he signs off this ARCH (no separate question round).

1. **Stack = C + GTK4 + libadwaita.** Direct C-ABI call into `liblesssheet.a` with zero FFI shim (the
   frontend is a pure consumer that reimplements nothing), the smallest binary (size budget), and it
   matches the workspace's existing `c-gtk` aidev profile. *Alternatives rejected:* **Rust + gtk4-rs**
   (memory safety we don't need for a thin caller, at the cost of an FFI wrapper + a large cargo tree +
   bigger binary); **Vala** (ergonomic but niche tooling, compiles through C anyway). *(the author.)*
2. **Grid = custom `GtkDrawingArea`** (Cairo + PangoCairo via its `draw_func`, GSK-composited; hand-driven `GtkAdjustment` + `GtkScrollbar`,
   uniform row height, viewport-only via `ls_window_set`, deferred estimate adjustment). The direct analog
   of the proven macOS NSTableView-shell technique. *Alternative rejected:* **GtkColumnView** — it requires
   an N-item `GListModel` (enumerates all rows), instantiates a factory widget per visible cell per column,
   and has documented fast-scroll jank and broken scrollbar estimation on estimated/uneven row counts; it
   structurally fights "materialize only the viewport." *(the author; corroborated by the survey + GTK docs.)*
   **AMENDED 2026-07-18 (the author-ratified per the Slice-1 reviewer's `[design]` finding):** the literal
   "GtkSnapshot/GSK" was internally inconsistent — a `GtkDrawingArea`'s only paint API is the Cairo
   `draw_func` (GSK snapshot nodes need a `GtkWidget` subclass `snapshot` vfunc, i.e. NOT a GtkDrawingArea).
   The realization is therefore **Cairo + PangoCairo, GSK-composited by GtkDrawingArea internally**; paint is
   viewport-bounded (~visible cells per frame, never O(rows)), analogous to the macOS CoreGraphics/CoreText
   cell draw. The GSK-vfunc-subclass alternative was considered and deferred; the perf verdict is the **H4
   human GUI pass** — if scroll janks on real GNOME hardware, revisit.
3. **Window chrome = native Adwaita** (`AdwHeaderBar` + `GtkPopover` find/jump + `AdwBanner` + `AdwToast` +
   `AdwStatusPage` + `AdwPreferencesDialog`). Satisfies "look native in GNOME / as default as possible";
   interaction parity (not pixel parity) is the bar. *Alternative rejected:* replicating the macOS
   chromeless Liquid-Glass floating overlay (non-native; no GTK equivalent; custom-drawn approximation).
   *(the author, option A.)* **AMENDED 2026-07-20 (the author-confirmed, relayed): Settings container =
   `AdwPreferencesDialog`, NOT `AdwPreferencesWindow`.** `AdwPreferencesWindow` was deprecated at our
   libadwaita 1.6 floor in favor of `AdwPreferencesDialog` (presented sheet-like, attached to the main
   window); per "prefer native and latest" we adopt the current idiom, accepting the small delta from
   macOS's separate Settings window. See `ARCH-gtk-settings-dialect.md` decision B (the "Settings + dialect
   override" slice) for the two-page ("Parsing" + "Columns") structure.
4. **v1 scope = full macOS feature parity**, with **accessibility the single deferred item** (later pass).
   *(the author.)*
5. **Build = Meson** (GNOME default; matches the `c-gtk` profile: frozen `include/` + `tests/`, impl under
   `src/`, deps in `meson.build`). **AMENDED 2026-07-17 (the author-confirmed): the WHOLE gate — compile-level
   conformance AND behavior — runs inside the Linux container, not split onto macOS.** The dev Mac has no
   GTK/Meson toolchain installed and Docker + Podman are present, so both conformance (Meson compile,
   `-Werror`) and behavior run in a pinned Linux GNOME container where GTK and the cross-built Linux `.a`
   naturally live; nothing GTK is installed on macOS.
6. **Headless behavior gate in a Linux container** (Docker + Podman both present locally). GTK needs a
   display, and the workspace forbids TCC/GUI-automation prompts and hands visual checks to the author (as on
   macOS). So the gate splits: (i) **display-free logic** — the pure view-model layer — under `g_test`;
   (ii) a **headless GTK smoke** (init GTK + open a small CSV + render one frame) under a virtual display
   (Xvfb or the Broadway backend) in the container; (iii) the **real GUI/visual pass is the author's**, on a
   real GNOME desktop. The core links as the native-Linux archive (glibc), built by `zig build`.
   **AMENDED 2026-07-21 (the author-signed, by the a11y slice `ARCH-gtk-a11y.md`): the pinned gate-container
   image bumps `fedora:42` → `fedora:43`** (GTK 4.20 / libadwaita 1.8.1 / GNOME 49). Reason: the a11y slice
   adopts `AdwShortcutsDialog`, which requires libadwaita 1.8 (see decision 7's amendment); fedora:42 ships
   only libadwaita 1.7, so the symbol is absent there. The planner re-pins the `.ci/Dockerfile` base to
   `fedora:43` with a fresh digest during that slice's freeze.
7. **CONFIRMED (the author 2026-07-17) — Minimum versions = GTK 4.16 / libadwaita 1.6 (GNOME 47, Sept 2024) floor;
   build against latest stable (GTK 4.22 / libadwaita 1.9 / GNOME 50).** Rationale: following the *system
   accent color* (a stated requirement) needs `AdwStyleManager:accent-color` / `:accent-color-rgba` /
   `:system-supports-accent-colors`, introduced in **libadwaita 1.6**; that fixes the floor. Per the
   "prefer native and latest" workspace rule, we target the current stable and treat 1.6 as the minimum a
   distro must ship. *Alternative considered:* an older floor (e.g. 1.4) — rejected because it loses the
   accent-color API and forces hardcoding, violating the no-hardcoded-color requirement.
   **AMENDED 2026-07-21 (the author-signed, by the a11y slice `ARCH-gtk-a11y.md`): the floor bumps to GTK 4.20 /
   libadwaita 1.8 (GNOME 49, Sept 2025).** The a11y slice's shortcuts surface adopts `AdwShortcutsDialog`
   (introduced in libadwaita 1.8; the native replacement for `GtkShortcutsWindow`, which was deprecated in
   GTK 4.18 and is removed in GTK 5). libadwaita 1.8 is paired to its GNOME-49-cycle GTK, so the GTK floor
   rises to 4.20 alongside it. *Accepted trade-off (the author):* the minimum supported distro base narrows by
   ~1 year (drops GNOME 47/48 — e.g. Debian trixie / older Ubuntu LTS); accepted under "prefer native and
   latest" over building on a GTK-5-removed widget. The planner sets `gtk4 >= 4.20` / `libadwaita-1 >= 1.8`
   in `apps/gtk/meson.build` during the a11y freeze (confirming the exact minimums libadwaita 1.8 pulls
   in-container). "Build against latest stable" is unchanged.
8. **CONFIRMED (the author 2026-07-17) — Locale/number-format stack = GLib/GIO + the C-library locale + `GDateTime`,
   NOT ICU.** The lossless exact-decimal round-trip that macOS gets from `Decimal.FormatStyle` is
   **arithmetic** (parse under the shared numeric grammar the core already defines, verify round-trip,
   render raw if not safely representable) and is reproduced directly in C — it does NOT need ICU. Only the
   *locale presentation glyphs* (grouping/decimal separators, date format) come from the platform: the
   C-library locale (`localeconv`/`nl_langinfo`) for numbers and `GDateTime`/`g_date_time_format` for dates.
   *Alternative rejected:* **ICU** — the most correct/CLDR-complete option (and what Foundation uses under
   the hood), but it pulls tens of MB of library + data, decisively breaking the single-digit-MB budget for
   a viewer. *Accepted trade-off (noted for sign-off):* subtle locale-format edge cases may differ from
   macOS's ICU/CLDR output; acceptable because the bar is interaction parity + correct losslessness, not
   glyph-identical cross-platform formatting. (glibc — not musl — backs the desktop app, so locale data is
   available; musl-static is only the separate bench/portability path.)

---

## Acceptance criteria (testable; grouped by who verifies)

### GATE — deterministic, headless, run in-gate (Linux container)

- **G1 — Builds & links.** `zig build` (cross to Linux) produces `liblesssheet.a`; inside the container
  `meson setup && meson compile` builds `apps/gtk/` and links the core; the app binary is produced.
  `-Werror` so any signature drift against the frozen header fails compilation.
- **G2 — Zero ABI change.** `api/lesssheet.h` is byte-identical to its pre-feature state (root-gate `api/`
  integrity); `apps/gtk/include/lesssheet.h` is a symlink to it, not a copy. No new dependency touches the
  contract.
- **G3 — Logic parity (display-free `g_test`).** The pure view-model layer passes: window-poll
  materialize/keep-polling decisions; find (text smart-case + predicate `= ≠ < > ≤ ≥`) and filter and jump
  control state machines; streaming-copy chunk assembly equals the core's TSV byte-for-byte across the copy
  fixtures; column-config reducers; dialect compose; column layout/width math; selection rect algebra;
  number/date formatter losslessness (round-trip: `"2.0"`==`"2"`, `"1e2"`==`"100"`, 40-digit ints, no
  binary-float rounding; unrepresentable → raw).
- **G4 — Viewport-only, no O(file)/O(rows).** A probe asserts that open + a scripted scroll over a large
  synthetic CSV issue `ls_window_set` only for bounded windows (≤ `LS_WINDOW_MAX_ROWS`) and never enumerate
  all rows; the horizontal column window stays O(visible columns) on a wide (100k-col) doc; no code path
  reads the whole file before the first materialized window.
- **G5 — Cold-start structure + recorded timing.** The open path is O(head) (asserted via the core's
  post-open frontier / `ls_index_poll` bound — first window served without a full scan); a launch→first-rows
  timing is recorded on the CI host (structural budget enforced in-gate; the < 500 ms wall-clock on target
  hardware is H2).
- **G6 — Headless GTK smoke.** Under a virtual display (Xvfb/Broadway) the app initializes GTK+libadwaita,
  opens a small CSV, and renders one frame without crashing or leaking (no synthetic input events; no TCC).
- **G7 — Theming discipline.** The grid paint path contains no literal color constants; all colors resolve
  from the active theme (accent for highlights, a muted theme color for selection) — structural check +
  a light/dark snapshot under the headless display asserting the two differ.
- **G8 — No leaks / clean cancel.** Open/close, copy cancel mid-stream, and search/filter/jump cancel leak
  nothing and are safe against a concurrent `ls_close` (the two-lock discipline), under the container's
  leak check.

### HUMAN GUI PASS — the author, on a real GNOME desktop (recorded, not gate-blocking)

- **H1 — Native look & theming.** Standard Adwaita chrome (`AdwHeaderBar` etc.); follows GNOME light/dark
  and the system accent color LIVE (change the system accent → the grid highlights follow without restart).
- **H2 — Cold-start < 500 ms (lower is better).** launch → first rows on commodity Linux hardware, and a
  multi-GB CSV opens as fast as a tiny one (O(viewport)).
- **H3 — Interaction parity.** Find (text + predicate, live count, wrap notices), jump (progress + reject),
  filter-to-matches (banner + original-row gutter), streaming copy (rect/row/column, notice + cancel),
  column-config Settings (parsing + list + inspector), dialect override, launch screen, and the GNOME
  keyboard shortcuts all behave equivalently to macOS.
- **H4 — Smooth virtual scroll.** Fluid scrolling and jumps over a millions-row / multi-GB file; no stall
  when the row-count estimate jumps by millions; no visual glitch on overscroll.
- **H5 — Network open.** A real HTTPS `.csv` and `.csv.gz` open with an always-visible progress banner and
  cancel; TLS verifies against a real host (the Linux net/TLS path).
- **H6 — Accessibility (deferred, tracked).** NOT required for v1; recorded as the immediate follow-up
  (AT-SPI roles over the custom grid + full keyboard-nav audit). The chrome is already accessible via
  Adwaita; the grid gets `GtkAccessible` GRID/ROW/GRID_CELL/COLUMN_HEADER roles in that pass.

---

## Open Questions

None. All scoping forks (stack, grid primitive, window chrome, v1 scope, accessibility deferral,
performance/viewport/cold-start philosophy) are resolved. The two remaining engineering recommendations
(minimum version floor — decision 7; locale/format stack — decision 8) are baked in with rationale and
flagged ▶ CONFIRM AT SIGN-OFF for the author to ratify when signing this ARCH.
