# ARCH — gtk-a11y (accessibility slice: the last GTK ↔ macOS parity item)

Status: **APPROVED — signed off by the author 2026-07-21.** Interactive interview complete (5 questions answered
2026-07-21; all architect recommendations accepted). The one technology fork (Decision 1) is **resolved to
Option A — `AdwShortcutsDialog`** (the author, 2026-07-21), which bumps the parent ARCH's libadwaita floor
1.6 → 1.8 and the gate container fedora:42 → fedora:43 (both amendments recorded in `ARCH-gtk-frontend.md`).
No Open Questions remain. Ready to freeze.

Implements the deferred **H6** of `ARCH-gtk-frontend.md` (Decision 4 there deferred accessibility to a later
pass; this is that pass), **pragmatically narrowed** by the author: a *labeled region* for the grid, not a full
AT-SPI table. Pure `apps/gtk/src/main.c` (+ possibly one new pure logic module) UI work over the **frozen,
untouched** C ABI — `IMPLEMENTATION_PATHS=(src)`; `include/` + `tests/` (the frozen surface) are not changed
and the contract is not amended.

**Read first:** `docs/architecture/PROJECT.md`, `CLAUDE.md` (workspace guide + budgets),
`ARCH-gtk-frontend.md` (the signed parent — Decision 4 + H6), and — as the authoritative interaction
template — the macOS grid's keyboard-selection model (`apps/macos/Sources/LessSheetApp/NativeGridChrome.swift`,
`ViewerModel+Selection.swift`). This slice **deliberately goes one step beyond** the macOS template where
keyboard-first accessibility demands it (see FR1/FR2); those deltas are called out explicitly and were
approved by the author.

---

## Problem & scope

The GTK frontend reached full macOS **feature/interaction** parity except accessibility, which the signed
parent ARCH deferred (H6). Today:

- **Keyboard bindings** are ad-hoc `GtkEventControllerKey` handlers (`on_key_pressed` on the grid,
  `on_window_key` on the window); there are **no `GAction` accelerators** and
  `gtk_application_set_accels_for_action` is never called, so no accelerator is discoverable or centrally
  defined. `Ctrl+A` **select-all is not implemented at all** (it is FR10 of the signed parent ARCH).
- **"Keyboard Shortcuts"** is a stub `AdwPreferencesDialog` with a **hand-typed, wrong** list (shows an
  unbound `Ctrl+,`; omits Find Next/Prev, Esc, arrows/Page/Home/End, digit-to-jump, `Ctrl+L`, Copy,
  Select-All).
- **AT-SPI names**: only the 3 Where-builder controls carry accessible names. Bare (tooltip only): the (×)
  clear-filter, the jump glyph (`GtkDrawingArea`), the header "H" toggle (`GtkDrawingArea`), the separator /
  quote dropdowns, find prev/next + search entry, open-file / open-url / find buttons, and the settings gear.
- **The grid** (`app->area`, a custom Cairo `GtkDrawingArea`) has **no accessible role, name, or
  description** and exposes nothing to a screen reader — completely opaque to Orca.
- **Grid keyboard nav**: Up/Down/Page/Home/End scroll vertically; there is **no horizontal keyboard scroll**;
  **selection is mouse-drag only** (so `Ctrl+C` cannot be reached keyboard-only). No mnemonics.

**In scope** (the four settled givens, plus what falls out of them):

1. **Grid as a labeled region** (NOT a full AT-SPI GRID/ROW/CELL tree): accessible role + name +
   dynamic description, plus a **live region** that announces position / selection / filter / find-landing
   changes.
2. **Keyboard cell selection + horizontal scroll**: a keyboard **cell cursor** with Shift-extend (making
   `Ctrl+C` usable without a mouse) and Left/Right horizontal navigation.
3. **A real native shortcuts surface** on the help-overlay convention (+ `Ctrl+?` / `Ctrl+F1`), and
   **promotion of the app-level key bindings to `GAction`s** with `gtk_application_set_accels_for_action` so
   accelerators are real, centrally defined, and reflected in the surface; and the wrong/incomplete list is
   fixed. **Includes** wiring the missing `Ctrl+A` select-all (FR10).
4. **Accessible names** on every bare interactive control (names default to today's tooltip text).

**Non-goals (explicit):**

- **NOT a full AT-SPI table.** No `GRID`/`ROW`/`GRID_CELL`/`COLUMN_HEADER` per-cell accessible tree (the
  original H6 vision) — deliberately narrowed to a labeled region + live announcements. A future slice may
  deepen it; this one does not.
- **NOT touching the ABI or the frozen surface.** `api/lesssheet.h`, `apps/gtk/include/`, `apps/gtk/tests/`
  unchanged; no contract amendment; no core (`ls_*`) change. All work is presentation/event glue in `src/`.
- **NOT mnemonics** (the author, minor parity item — skipped).
- **NOT re-litigating** any settled parent-ARCH decision (stack, grid primitive, chrome, theming, threading).
- **NOT new visual design** beyond the accent focus-ring on the active cell (FR2) required for keyboard use.

---

## Inputs / Outputs

**Inputs (new/changed):**

- **Keyboard on the grid** (`app->area` focused): arrows (cursor move), Shift+arrows (extend), Page Up/Down,
  Home/End, digits 0–9 (existing jump), `Ctrl+C` (copy), `Ctrl+A` (select-all), `Esc` (existing dismiss,
  plus new lowest-priority clear).
- **Application accelerators** (any focus, GNOME conventions): `Ctrl+O`, `Ctrl+Shift+O`, `Ctrl+F`, `Ctrl+G`,
  `Ctrl+L`, `Ctrl+comma` (Preferences), `Ctrl+?` / `Ctrl+F1` (shortcuts surface). Find Next/Prev (`Enter` /
  `Shift+Enter`) remain on the find popover as today.
- **Assistive-tech queries** (Orca / AT-SPI): the grid's role, name, description, and announcements; every
  control's accessible name.

**Outputs (new/changed):**

- **On-screen:** an accent-colored focus outline on the active cell (in addition to the existing muted-gray
  selection marquee); otherwise no visual change.
- **To AT-SPI:** the grid's accessible role + name ("Data grid") + a dynamic description; per-control
  accessible names; **live announcements** (see the verbosity table in FR3) via `gtk_accessible_announce`.
- **A native shortcuts surface** listing the complete, correct accelerator set, sourced from the same table
  that registers the accelerators (no hand-typed drift).

**Error/edge cases:** empty document (0 rows) — cursor commands are no-ops, description reads "0 rows", no
announcements; incompletely-indexed huge file — select-all uses the current row-count value the model already
displays (see FR2); network doc mid-fetch — cursor moves within materialized rows; a move beyond the fetched
frontier reuses the existing `net_drive_begin` path (no new network behavior).

---

## Functional requirements

### FR1 — Keyboard cell cursor + navigation (grid-focused)

The grid's `on_key_pressed` is re-specified. The cursor is the **active corner** of the ONE shared selection
rectangle already in `App` (`sel_a_* / sel_b_*` + `sel_mode`) — anchor = the `_a_` corner, active/cursor =
the `_b_` corner, exactly the state a mouse drag already produces. Keyboard and mouse share this single state
(no parallel cursor state).

- **Seeding (seed-only, no step).** With nothing selected (`sel_mode == SEL_NONE`), the first arrow press
  seeds a 1×1 cell selection (`SEL_CELLS`) at the **top-left currently-visible data cell** (first visible
  view row × first visible column of the current column window) **and stops there — it does NOT step on that
  first press.** The cursor lands at the seed cell; the *next* arrow press is the first one that moves it.
  (Cross-frontend behavior confirmed by the author 2026-07-21; macOS adopts the same. The frozen
  `tests/test_a11y.c` and AC G-A1 are authoritative and already encode no-step.)
- **Plain arrows move the cursor** (this is the approved delta from macOS, where arrows are a no-op with
  nothing selected and pure-scroll never existed): Up/Down step one row; Left/Right step one column; the
  selection **collapses** to the new 1×1 cell (anchor follows active).
- **Shift+arrows extend**: the anchor (`_a_`) stays fixed; only the active corner (`_b_`) steps; the rect
  grows/shrinks. `SEL_CELLS` mode.
- **Page Up/Down** move the cursor by one page (`page_size / row_h` rows), collapsing (or extending with
  Shift). **Home/End** move the cursor to the first/last row of the current view (file-top / file-bottom
  semantics preserved), cursor following; Shift extends to that end.
- **Left/Right past the visible column window** scroll `hadj` so the cursor column is revealed — this is the
  first horizontal keyboard scroll in the app and satisfies the "horizontal scroll = in scope" given.
- **Auto-scroll (minimal).** After any cursor move, the viewport scrolls the **minimum** needed to bring the
  active cell fully into view (vertical via `vadj`, horizontal via `hadj`); if the cell is already visible,
  the viewport does not move. Row-by-row scrolling still emerges naturally (cursor at the bottom edge drags
  the view down one row). On a network doc, a target beyond the fetched frontier lands via the existing
  `net_drive_begin` drive; the cursor is clamped to the current row-count value until the fetch advances.
- **Clamping.** The cursor never leaves the current view extent (`0 … rowcount-1` × `0 … n_cols-1`).

### FR2 — Keyboard copy, select-all, and Escape-clear (grid-focused)

- **`Ctrl+C`** copies the current selection through the **existing** `do_copy` path. A bare cursor is a 1×1
  `SEL_CELLS` selection, so it copies exactly that one cell via the **existing single-cell raw special case**
  (not the whole row). No change to the copy engine.
- **`Ctrl+A`** selects the full current view extent — all columns × all rows of the **current row-count
  value the model already displays** (the filtered count while filtered) — as a single `SEL_CELLS` rect,
  O(1) in state. The subsequent `Ctrl+C` reuses the existing **streaming copy + frontier-resume** machinery
  (identical to a whole-column copy today). This wires FR10 of the parent ARCH, previously unimplemented.
- **`Esc` on the grid** keeps its current precedence and gains one **lowest-priority** fallback: (1) dismiss
  an open find/jump/dialect popover / clear an active search (unchanged); else (2) cancel an in-flight copy
  (unchanged); else (3) **clear the selection/cursor** (`SEL_NONE`). This last step is the GNOME-typical
  behavior; macOS does not do it (approved delta).
- **No focus hijack.** `Ctrl+C` / `Ctrl+A` must NOT steal from a focused text entry (find / jump / Where
  value). They stay **grid-focus-scoped** (a `GtkShortcutController` with local/managed scope on the grid, or
  actions gated on grid focus) so a focused `GtkText` keeps its own `Ctrl+C` / `Ctrl+A`. This preserves
  today's deliberate placement of `Ctrl+C` on the grid controller.

### FR3 — Grid as a labeled region + live announcements

- **Role + name + description.** `app->area` is given an accessible role appropriate for a labeled region
  (see Decision 3), a fixed accessible **name = "Data grid"** (format-neutral), and a **dynamic accessible
  description** rebuilt whenever the relevant state changes:
  `"<document name>, N columns, ~M rows, showing rows X to Y[, filtered]"` (M is `~`-prefixed while the
  row count is an estimate; X–Y are the gutter row numbers of the first/last visible data rows; "filtered"
  appended while a filter is active; "0 rows" / "empty" for an empty doc). The description updates the
  accessible property but is **not announced** (no spam).
- **Decorative inner drawing areas** (the jump glyph inside `jump_button`, the header "H" glyph inside
  `header_toggle`) are marked **presentational** (accessible role NONE) so the interactive parent button is
  the single named stop, not an extra empty element.
- **Live announcements** via `gtk_accessible_announce` on the grid (available since GTK 4.14 — below our 4.16
  floor, so no version cost). The **approved verbosity set**:

  | Event | Announced text | Priority |
  |---|---|---|
  | Cursor move (arrow/page/home/end) | `"Row R, <ColumnName>: <value>"`, clipped to ~80 chars (ellipsis) | LOW |
  | Extend / select-all | `"N rows × M columns selected"` (rect dimensions) | MEDIUM |
  | Filter apply / clear | the existing header-subtitle text (`update_title_subtitle`) | MEDIUM |
  | Find-navigation landing | `"Match n of m, row R"` (same n/m the find status shows) | MEDIUM |
  | Copy completion | the existing copy-complete toast text | MEDIUM |

  `R` and `<ColumnName>` match what the grid already draws (gutter row number — the source row under a
  filter; header label if `has_header`, else the generic column name). `<value>` is the **displayed
  (formatted)** cell text. **NOT announced:** plain scrolling, live match-count ticks during a scan, and
  row-count-estimate growth.

### FR4 — Accessible names on every bare control

Each currently-bare interactive control gets an accessible name (via `gtk_accessible_update_property
… PROPERTY_LABEL`) defaulting to **its existing tooltip text**:

| Control | Accessible name |
|---|---|
| Open file | "Open File" |
| Open URL | "Open URL" |
| Find | "Find" |
| Previous match | "Previous match" |
| Next match | "Next match" |
| Search entry | "Find text" |
| Jump to row (button) | "Jump to row" |
| Header "H" toggle | "First row is a header" |
| Field separator dropdown | "Field separator" |
| Quote character dropdown | "Quote character" |
| (×) clear filter | "Clear filter" |
| Settings gear | "Main menu" |

The custom header title box needs no extra role/label — its children are already an accessible name label, a
subtitle label, and the named (×) button. Standard Adwaita chrome remains accessible for free.

### FR5 — `GAction` promotion + a real, correct shortcuts surface

- **Promote app-level bindings to `GAction`s** with `gtk_application_set_accels_for_action`, so every
  accelerator is real and centrally defined: Open (`Ctrl+O`), Open URL (`Ctrl+Shift+O`), Find (`Ctrl+F`),
  Jump (`Ctrl+G` **and** `Ctrl+L`), Preferences (`Ctrl+comma` — **now actually bound**, fixing the stub's
  unbound entry), and the shortcuts action (`Ctrl+?` **and** `Ctrl+F1`). The existing `on_window_key`
  handlers for these are replaced by the actions. Grid-contextual commands (Copy, Select-All, cursor moves,
  digit-jump) stay on the grid controller / a grid-scoped shortcut controller per FR2 (they must not fire
  when a text entry is focused).
- **A single accelerator table is the source of truth** for both the accel registration and the shortcuts
  surface — no hand-typed list. The surface is generated from / references that table so the displayed
  accelerator always equals the one that actually fires (honoring the single-source-of-truth rule).
- **The shortcuts surface** is the native help-overlay (Decision 1), listing the **complete, correct** set
  grouped sensibly (e.g. General: Open / Open URL / Preferences / Shortcuts; Find: Find / Next / Prev / Esc;
  Navigation: arrows / Page / Home / End / digit-to-jump / horizontal; Selection: Shift+arrows / Select-All /
  Copy). It replaces the wrong stub entirely.

---

## Non-functional constraints

- **Zero cold-start / scroll regression.** Cursor state is O(1); the description/announcement builders run
  only on discrete state changes (never per frame, never per scanned byte). Auto-scroll reuses the existing
  `vadj`/`hadj` + `grid_materialize` path — no new full-file work; O(viewport) preserved. The parent ARCH's
  cold-start (< 500 ms), viewport-only, and two-lane threading guarantees are untouched.
- **Theming, no hardcoded colors** (parent G7). The active-cell focus outline resolves from the **theme
  accent** (the same `AdwStyleManager` accent resolution the find highlights already use) — no literal color
  constant; follows light/dark + live accent changes.
- **No new runtime dependency** beyond the GNOME stack already in `meson.build` — with the Decision 1
  version-floor bump (GTK 4.16 → 4.20, libadwaita 1.6 → 1.8) applied by the planner. No contract/API impact.
- **Announcement politeness.** Cursor moves are LOW priority (queued, non-interrupting); discrete
  confirmations are MEDIUM. Frequent/among-noise events (scroll, scan ticks, estimate growth) are silent.

---

## Component decomposition & data flow

All changes are in `apps/gtk/src/`. Existing parts touched:

- **`src/main.c` — `on_key_pressed` (grid):** re-specified per FR1/FR2 — arrows/Page/Home/End now drive the
  cursor + auto-scroll instead of scrolling the adjustment directly; adds `Ctrl+A` and the `Esc`-clear
  fallback; `Ctrl+C` and digit-jump behavior preserved.
- **`src/main.c` — selection state (`sel_*`) + `do_copy` + `grid_draw`:** the keyboard cursor reuses the
  existing `sel_a_*/sel_b_*/sel_mode`; `grid_draw` adds the accent outline on the active (`_b_`) cell atop
  the existing marquee; `do_copy` is unchanged (bare cursor → existing single-cell raw path).
- **`src/main.c` — grid construction (`app->area`):** created with the accessible **role** as a construct
  property (roles are immutable post-construction) + name "Data grid"; description updated from
  `grid_materialize` / filter / open paths; the decorative inner glyph drawing areas set to role NONE.
- **`src/main.c` — the announcement call sites:** cursor-move (in the new cursor handler), extend/select-all,
  filter apply/clear (`update_title_subtitle` / the filter toggle), find-landing (the find-nav fold), copy
  completion (the copy-complete toast site) each call `gtk_accessible_announce` with a string from a pure
  builder.
- **`src/main.c` — `action_shortcuts` + `build_primary_menu` + app startup:** replace the stub dialog with
  the native shortcuts surface (Decision 1); add the `GAction`s + `gtk_application_set_accels_for_action`;
  add accessible names (FR4).

**New (recommended) pure module — Decision 2:** a display-free `src/lsg_a11y.*` (or folded into an existing
`lsg_*`) holding the **pure, unit-testable** logic so the gate can verify behavior without a display:

- the **cursor/selection reducer** — `(current corners, visible-window descriptor, key command) → (new
  corners, mode, reveal-target hint)` covering seed-at-top-left, move, shift-extend, page, home/end,
  horizontal, select-all extent, and clamping;
- the **string builders** — cursor-move announcement (with the ~80-char clip + ellipsis), extend/select-all
  announcement, find-landing announcement, and the grid **description** builder;
- the **accelerator table** — the single `(command, action-name, accel[])` source consumed by both the accel
  registration and the shortcuts surface.

This mirrors the parent ARCH's layered "pure logic is headlessly testable; only rendering/AT needs a
display" discipline and the macOS `Contracts/Selection.swift` + `SelectCopyLogic` split. Auto-scroll geometry
can reuse `lsg_grid_geometry`. The exact module boundary is the planner's call; the **requirement** is that
the cursor algebra + string/description builders + accel table are pure and gate-tested.

**Data flow:** key event → grid controller → pure cursor reducer → update `sel_*` + compute reveal target →
set `vadj`/`hadj` (minimal reveal) → `grid_materialize` + `queue_draw` → `grid_draw` paints marquee + accent
outline → the site calls `gtk_accessible_announce(area, builder(...), priority)`. AT-SPI reads role/name/
description directly off the widget (in-process; no bus needed to query them).

---

## External interfaces

- **Consumes (unchanged):** the frozen `ls_*` ABI and the existing `lsg_*` frontend modules — no additions.
- **GTK/GLib accessibility surface (new usage):** `gtk_accessible_update_property` (LABEL / DESCRIPTION),
  the `accessible-role` construct property, `gtk_accessible_announce` (+ `GtkAccessibleAnnouncementPriority`),
  `gtk_accessible_get_accessible_role` (for the gate's in-process assertions), `GtkShortcutController` /
  `GAction` / `gtk_application_set_accels_for_action`.
- **The shortcuts surface widget:** `AdwShortcutsDialog` (Decision 1, chosen) — the `app.shortcuts` action
  auto-created by `AdwApplication` when a `shortcuts-dialog.ui` resource is present in the resource base
  path; `AdwShortcutsItem` items carry `title` / `accelerator` / `action-name`.

---

## Technology decisions

### Decision 1 (CHOSEN — the author, 2026-07-21) — the shortcuts-surface widget = `AdwShortcutsDialog`

The parent scope named "a real `GtkShortcutsWindow`." Research (2026-07-21) shows that widget is **deprecated
since GTK 4.18 — the exact version the old gate container shipped — and removed in GTK 5.** Under the gate's
`werror=true` with no version-macro pin (`meson.build` defaults `GDK_VERSION_MIN_REQUIRED` to the installed
GTK), adding it as-is **fails the gate** on a deprecation warning. The native modern replacement,
**`AdwShortcutsDialog`** (libadwaita 1.8 / GNOME 49; structure Dialog → Section → Item; `AdwShortcutsItem`
carrying `title` / `accelerator` / `action-name`; auto-loaded by `AdwApplication` from a `shortcuts-dialog.ui`
resource via an `app.shortcuts` action), was above the prior floor (libadwaita 1.6, parent Decision 7) and
container (fedora:42 = libadwaita 1.7).

**Chosen: `AdwShortcutsDialog`** — the current, non-deprecated, native idiom, honoring "prefer native and
latest" and avoiding a widget already removed in GTK 5. `AdwShortcutsItem`'s `action-name` gives
single-source accel display; `AdwApplication` auto-wires the `app.shortcuts` action (the help action moves
from `win.show-help-overlay` to `app.shortcuts`; `Ctrl+?` / `Ctrl+F1` are set on it explicitly). **Consequent
amendments (the author-approved 2026-07-21, recorded in the parent ARCH):** the libadwaita floor rises
**1.6 → 1.8** and, since libadwaita 1.8 is paired to its GNOME-49-cycle GTK, the GTK floor rises **4.16 →
4.20**; the gate container rises **fedora:42 → fedora:43** (ships GTK 4.20 / libadwaita 1.8.1). **Accepted
trade-off:** minimum distro support narrows by ~1 year (drops GNOME 47/48, e.g. Debian trixie / older Ubuntu
LTS). *The planner applies the concrete `meson.build` floors (`gtk4 >= 4.20`, `libadwaita-1 >= 1.8`) and the
`fedora:43` container tag during the freeze — see "Target values for the planner" below.*

*Alternative considered and rejected (kept for the record):* **`GtkShortcutsWindow` + version-macro pin**
(`GDK_VERSION_MIN_REQUIRED / MAX_ALLOWED = GDK_VERSION_4_16` + the libadwaita equivalents), which would let
the deprecated widget compile at the 4.16 surface under `-Werror` with **no floor/container change**. Rejected
because it builds on a widget removed in GTK 5 (future migration debt) and reads against "prefer native and
latest"; the ~1-year reach cost of Option A was accepted instead.

**Target values for the planner (apply during the freeze; do not derive elsewhere):**
- `apps/gtk/meson.build`: `gtk4 >= 4.20`, `libadwaita-1 >= 1.8` (confirm the exact minimums libadwaita 1.8
  pulls against fedora:43's pkg-config in-container; do not go below these).
- `apps/gtk/.ci/Dockerfile`: base image `fedora:43` (GTK 4.20 / libadwaita 1.8.1 / GNOME 49), explicit tag +
  a fresh pinned digest observed at authoring time (mirroring the current file's pinning convention).

### Decision 2 — pure logic extracted to a display-free module (gate-testable)

The cursor/selection reducer, the announcement/description string builders, and the accelerator table are
**pure C** in an `lsg_*` module (new `lsg_a11y.*` or folded into an existing one — planner's call), so the
gate verifies the behavior headlessly (mirrors the parent's layered discipline; matches macOS's
`Contracts/Selection.swift` split). Only the actual key-event routing, Cairo outline paint, and
`gtk_accessible_announce`/AT wiring remain display/AT-dependent (human pass). *Feature-local.*

### Decision 3 — grid accessible role = labeled region

`app->area` gets a role appropriate for a **labeled region** (e.g. `GTK_ACCESSIBLE_ROLE_GROUP`, or a more
specific landmark/region role if the implementer verifies it exists and reads better in Orca at the 4.16
floor) + accessible name + dynamic description + `gtk_accessible_announce` live announcements. **NOT** the
per-cell `GRID`/`ROW`/`GRID_CELL`/`COLUMN_HEADER` tree (the deliberately-deferred deepening). The exact role
enum is verified in-container by the implementer; the architecture requirement is "named region + dynamic
description + polite live announcements," not a specific enum. *Feature-local (per the author's given #1).*

### Decision 4 — announcements via `gtk_accessible_announce`

Chosen over a manually-managed ARIA-style live-region property because it is the GTK-native, direct
"post this message now at this priority" API and needs no live-region container plumbing. Available since GTK
4.14 (below our floor). *Feature-local.*

Per Decision 1 (Option A), the parent `ARCH-gtk-frontend.md` Decision 7 (floor) and its gate-container
decision are amended to GTK 4.20 / libadwaita 1.8 / fedora:43 (see that doc's amendment notes dated
2026-07-21). `PROJECT.md` is unaffected — it records neither the libadwaita floor nor the container image as
a project-wide stable decision (its Linux entries remain open/toolkit-level), so no second file changes.

---

## Acceptance criteria

Split per the parent ARCH convention. **GATE** criteria are deterministic and run headlessly in the Linux
container (pure `g_test` + the existing headless GTK smoke — accessible role/name/description are queryable
**in-process**, no AT-SPI bus/Orca needed). **HUMAN GUI PASS** criteria are validated by the author on a real
GNOME desktop via `run_gtk_on`, with Orca, because live AT-SPI announcement delivery and interactive
keyboard/focus behavior are inherently GUI-interactive (no synthetic input events in-gate; no
screen-reader automation).

### GATE — deterministic, headless (Linux container)

- **G-A1 — Cursor/selection reducer (pure `g_test`).** For a scripted set of (starting corners, visible-
  window descriptor, key command) inputs, the reducer returns the exact expected corners/mode/reveal-hint:
  seed-at-top-left on first arrow from `SEL_NONE`; plain arrow collapses + steps; Shift+arrow keeps anchor +
  steps active; Page steps by page rows; Home/End go to view first/last row; Left/Right step columns;
  select-all yields `(0,0)…(rowcount-1, n_cols-1)`; every result is clamped to the extent (no out-of-range
  corner); on an empty (0-row) view all commands are no-ops.
- **G-A2 — Announcement string builders (pure `g_test`).** Cursor-move → `"Row R, Name: value"` with values
  over ~80 chars clipped + ellipsis; extend/select-all → `"N rows × M columns selected"` with correct rect
  dimensions; find-landing → `"Match n of m, row R"`. Byte-exact expected strings across representative
  fixtures (header/no-header, filtered/identity, wide value, multibyte value).
- **G-A3 — Grid description builder (pure `g_test`).** `"<doc>, N columns, ~M rows, showing rows X to Y[,
  filtered]"` for identity / filtered / estimate (`~`) / empty ("0 rows") states — byte-exact.
- **G-A4 — Accelerator table is single-source (pure `g_test` + structural).** One table drives both accel
  registration and the shortcuts surface; a test asserts the set is complete (every FR5 command present with
  its accel — including `Ctrl+A`, Copy, Find Next/Prev, `Ctrl+L`, `Ctrl+?`/`Ctrl+F1`) and that the surface
  is generated from / references that table (no separate hand-typed literal list remains). The old wrong
  entries (unbound `Ctrl+,` as displayed-but-dead; missing items) are gone.
- **G-A5 — Accessible role/name/description present (headless smoke, in-process query).** Extending the
  existing headless smoke: after opening the small CSV, `app->area` reports a **non-default accessible role**
  and a **non-empty accessible name** ("Data grid") and a **non-empty description**; the decorative inner
  glyph areas report role NONE; **every** control listed in FR4 reports a non-empty accessible name (a
  structural sweep). No screen reader involved — these are in-process widget properties.
- **G-A6 — Focus-outline theming discipline (structural + snapshot, extends G7).** The active-cell outline
  paint path contains **no literal color constant** and resolves from the theme accent; a headless
  light/dark (or accent-swap) snapshot shows the outline color track the accent. No cold-start/scroll
  regression measured by the existing probe (cursor state O(1); builders run only on discrete changes).
- **G-A7 — No focus hijack (structural).** Copy / Select-All are grid-focus-scoped (grid `GtkShortcutController`
  local/managed scope, or focus-gated actions) — asserted structurally that they are not registered as
  unconditional global app accels that would fire while a `GtkText` is focused.

### HUMAN GUI PASS — the author, on a real GNOME desktop (Orca + `run_gtk_on`; recorded, not gate-blocking)

- **H-A1 — Keyboard-only cell selection + copy.** Tab focus to the grid; the first arrow press seeds the
  cursor at the top-left visible cell WITHOUT stepping, and subsequent presses move it, with the accent
  outline visible; the viewport auto-scrolls minimally to keep the cursor visible; Shift+arrows
  extend; Left/Right scroll horizontally; Page/Home/End behave per FR1; `Ctrl+A` selects all; `Ctrl+C` copies
  (a bare cursor copies exactly one cell); `Esc` clears the selection as the last fallback — **all with no
  mouse**. Typing in the find/jump/Where field, `Ctrl+C`/`Ctrl+A` still act on the field, not the grid.
- **H-A2 — Screen-reader announcements (Orca).** The grid announces its name + description on focus; cursor
  moves, extend/select-all, filter apply/clear, find landings, and copy completion are announced per the FR3
  verbosity table; plain scrolling, scan ticks, and estimate growth are **not** announced; cursor-move
  announcements do not interrupt (LOW priority).
- **H-A3 — Native shortcuts surface.** `Ctrl+?` / `Ctrl+F1` and the menu item open the native surface
  (per Decision 1); it lists the **complete, correct** accelerators matching what actually fires — no wrong
  `Ctrl+,`; includes Find Next/Prev, Esc, arrows/Page/Home/End, digit-to-jump, `Ctrl+L`, `Ctrl+A`, Copy.
- **H-A4 — Controls named + focus visuals under Orca.** Tabbing the header bar, every button/dropdown/entry
  announces its FR4 name; the accent focus ring follows the live GNOME accent color; nothing announces an
  empty/decorative inner glyph.
- **H-A5 — No regression.** Existing find / jump / filter / copy / dialect / settings / scroll behavior and
  the cold-start feel are unchanged; the accent outline reads correctly in light and dark.

---

## Open Questions

None. The five interview questions are answered (all architect recommendations accepted, 2026-07-21) and the
one technology fork (Decision 1) is resolved to Option A — `AdwShortcutsDialog` — with its two consequential
parent-ARCH amendments recorded. Signed off by the author 2026-07-21; ready to freeze.
