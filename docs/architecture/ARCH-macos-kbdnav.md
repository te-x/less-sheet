# ARCH — macos-kbdnav (keyboard cell-navigation parity with the signed GTK a11y slice)

Status: **DRAFT — interactive interview complete.** Four macOS-specific questions answered by the author
2026-07-22 (Q1 seed-no-step, Q2 accent outline on every active corner, Q3 skip-hidden-columns, Q4 Cmd+arrow
synonyms — all recorded below). The interaction model is INHERITED from the signed `ARCH-gtk-a11y.md` (the
cross-frontend template) and is NOT re-litigated here. Awaiting explicit sign-off to freeze.

The macOS parallel to the keyboard-navigation half of `ARCH-gtk-a11y.md` (that slice's FR1/FR2). **Scope =
keyboard navigation ONLY.** VoiceOver / `NSAccessibility` exposure is explicitly DEFERRED by the author and is a
non-goal of this slice — no screen-reader work, no live announcements, no accessible-role/description surface
(the GTK a11y items FR3/FR4/FR5 have no macOS counterpart here).

**Read first:** `docs/architecture/PROJECT.md`, `CLAUDE.md` (workspace guide + the cold-start budget),
`ARCH-select-copy.md` (the signed selection/copy parent this extends), and — as the authoritative interaction
template — `ARCH-gtk-a11y.md` FR1/FR2. Grounding survey (2026-07-22) of the macOS frontend:
`apps/macos/Sources/Contracts/Selection.swift` (the frozen `Selecting` geometry), `Sources/LessSheetKit/
SelectCopyLogic.swift` (`SelectionModel`), `Sources/LessSheetApp/ViewerModel+Selection.swift` (the model's
selection state), `NativeGridChrome.swift` + `NativeGrid+Selection.swift` (the `SheetTableView` key/mouse
routing), `NativeGridRowView.swift` (the marquee draw), `NativeGrid+Scroll.swift` (`landOn` / clip geometry),
and `ViewerModel+Copy.swift` (the streaming single-cell copy path).

---

## Problem & scope

macOS is BEHIND on keyboard navigation — the GTK a11y work surfaced this. Verified current macOS state:

- The one shared selection is `anchor` + `active` corner (`Contracts/Selection.swift`). Plain arrow collapses
  and steps the active corner; Shift+arrow keeps the anchor and steps the active corner (`SelectionModel`
  via `Selecting`, routed through `SheetTableView`'s `moveUp:`/`moveDown:`/`moveLeft:`/`moveRight:`(+`…AndModifySelection:`)
  overrides → `NativeGridController.moveSelection` → `DocumentModel.moveSelection`).
- **Arrows are a NO-OP with nothing selected** — `DocumentModel.moveSelection` guards `guard let current =
  selection else { return }` (`ViewerModel+Selection.swift:53`). So a keyboard-only user cannot create a
  *targeted* selection without a first mouse click (Cmd+A→Cmd+C works with no mouse today, but selecting a
  specific cell/range does not).
- **No auto-scroll on keyboard move** — the controller only repaints the visible rows; a cursor stepped off
  the visible region leaves the viewport where it was.
- **PageUp/Down/Home/End are not handled by the grid** — they fall through to `NSTableView`'s default
  scroll-only behavior (the cursor does not follow).
- **No horizontal keyboard behavior tuned for hidden columns** — `Selecting.move`/`extend` step in *absolute*
  column space with an extent clamp, so a Left/Right step can land the active corner on a *hidden* column
  (an invisible cursor); mouse paths cannot produce this, but a keyboard-first flow amplifies it.
- Cmd+A (capped select-all, `selectAll:`) and Cmd+C (streaming copy; a 1×1 rect already rides the core's
  single-cell raw special case) are implemented and correct. Esc (`handleEscape`) dismisses popups / clears
  an active search, else cancels an in-flight copy — it NEVER clears the selection.
- The data table is already made first responder at open with no preceding click
  (`NativeGrid+Build.swift:159–168`), and `NSTableView` draws no focus ring in this pure-viewer subclass, so
  seeding a cursor at open has no first-responder or focus-ring conflict.

**In scope (the settled givens inherited from `ARCH-gtk-a11y.md`, plus what falls out of them):**

1. **Arrows always move a cell cursor.** The first navigation key with nothing selected **seeds** the cursor
   at the **top-left visible cell** with **NO step on that first press** (Q1); subsequent presses move it. The
   viewport **auto-scrolls the minimum** needed to keep the active cell visible.
2. **A full navigation key set** over the one shared selection: Up/Down (±1 row), Left/Right (±1 **visible**
   column, Q3), PageUp/PageDown (±one page of rows), Home/End (file top/bottom, cursor following), and the
   macOS-native **Cmd+arrow synonyms** (Q4): Cmd+Up/Down = file top/bottom, Cmd+Left/Right = first/last
   visible column. Shift added to any of these **extends** (anchor fixed).
3. **Cmd+A** capped select-all — already exists; kept unchanged.
4. **Cmd+C** on a bare 1×1 cursor copies exactly that one cell (the existing single-cell raw path); with
   seeding in place, **keyboard-only copy now works end to end**.
5. **Esc** clears the selection/cursor as the **lowest-priority** fallback (after dismissing popups / an active
   search, after cancelling an in-flight copy).
6. **Accent active-cell focus outline** (Q2): the active corner of **every** selection (keyboard- or
   mouse-created) renders an outline resolved from the system accent color, in addition to the existing
   muted-gray selection marquee; reads correctly in light + dark.

**Non-goals (explicit):**

- **NOT VoiceOver / `NSAccessibility`.** No accessible role/name/description, no live announcements, no
  screen-reader work of any kind (the author-deferred). This is the macOS-specific narrowing versus the GTK slice.
- **NOT touching the frozen C ABI or any SHA-pinned Swift contract.** `api/lesssheet.h` and
  `apps/macos/Sources/Contracts/ColumnPanel.swift` (the two files pinned by `AmendmentContractGuardTests`
  AC23) are unchanged; no `ls_*` core change; no amendment to the frozen `Selecting` protocol.
- **NOT a new selection MODEL.** The one shared `anchor`+`active` selection and the frozen `Selecting`
  geometry are reused as-is; this slice adds a keyboard *command → target-cell* layer over them, never a
  parallel cursor state.
- **NOT re-litigating** the settled GTK-template interaction (seed-no-step, shift-extend, skip-hidden,
  Esc-clear-last) or any parent `ARCH-select-copy` decision (marquee language, streaming copy, O(1) selection).
- **NOT new visual design** beyond the accent outline required for keyboard use.

---

## Inputs / Outputs

**Inputs (new/changed):** keyboard events while the data table (`SheetTableView`) is first responder —

| Physical key(s) | Logical command | Extending variant |
|---|---|---|
| ↑ / ↓ | step active corner ∓1 **row** | Shift+↑ / Shift+↓ |
| ← / → | step active corner ∓1 **visible column** | Shift+← / Shift+→ |
| Page Up / Page Down | step active corner ∓ one page of rows | Shift+Page Up / Down |
| Home / End · **Cmd+↑ / Cmd+↓** | active corner to **file top / bottom** row (column kept) | + Shift |
| **Cmd+← / Cmd+→** | active corner to **first / last visible column** (row kept) | + Shift |
| Cmd+A | capped select-all (unchanged) | — |
| Cmd+C | copy the current selection (unchanged engine) | — |
| Esc | dismiss popup / cancel copy / **clear selection** (new last step) | — |

With **nothing selected**, ANY navigation command above **seeds** a 1×1 selection at the top-left visible cell
and applies **no** step (Q1). Extending variants with nothing selected likewise seed the 1×1 (there is no
anchor to extend from yet) — the same fallback the mouse `extendSelection` already uses.

**Outputs (new/changed):**

- **Selection state** (`DocumentModel.selection`, index space): the new `anchor`/`active` corners after the
  command; O(1) to hold regardless of rect size (frozen `Selection` semantics).
- **Viewport:** a minimal clip scroll (vertical via the existing clip-origin math, horizontal via the clip x)
  so the active cell is fully visible; unchanged when the cell is already visible.
- **On-screen:** a 2 pt `controlAccentColor` outline, inset ~1 pt, on the active-corner cell, drawn atop the
  existing 2 pt muted-gray marquee (distinct by geometry from the rounded, inset accent find-highlight chips).
- **Pasteboard:** unchanged — a 1×1 cursor copies exactly one cell's raw value via the existing path.

**Error / edge cases:** empty extent (0 rows or 0 visible columns) → every command is a no-op (nil selection),
matching the frozen `Selecting` producing-ops. A step past an edge stays on the edge (clamped). A shift-extend
whose rect spans hidden columns includes them in the rect and copy exactly as a mouse drag does today (copy is
visibility-blind — unchanged). Network doc mid-fetch: cursor moves within materialized rows; a target beyond
the fetched frontier is clamped to the current row-count value the model displays (no new network behavior;
the copy path's existing frontier-resume is untouched).

---

## Functional requirements

### FR1 — Keyboard cell cursor + navigation (grid first responder)

The cursor is the **active corner** of the ONE shared selection already in `DocumentModel`
(`selection.active`); keyboard and mouse share this single state (no parallel cursor). Every navigation
command resolves to a **target cell**, then produces the new selection by the frozen geometry: plain =
collapse to the target (`Selecting.select`), extending = keep anchor, move active to the target
(`Selecting.extend(_:to:in:)`). The target computation is where the new behavior lives:

- **Seed (no step).** With `selection == nil`, the first navigation command seeds a 1×1 selection at
  `(topVisibleRow, firstVisibleColumn)` — the top-left cell currently on screen — and applies no step (Q1).
- **Row step (↑/↓).** target row = active row ∓ 1, clamped to `0…lastRow`; column kept.
- **Column step (←/→) — visible columns only (Q3).** target column = the visible column adjacent to the
  active column in the ordered **visible-columns** list (clamped at the ends); a hidden column is never a
  cursor stop. Row kept.
- **Page (Page Up/Down).** target row = active row ∓ `pageRows` (one page of data rows), clamped; column kept.
- **Document ends (Home/End, Cmd+↑/↓).** target row = `0` (top) / `lastRow` (bottom); column kept.
- **Line ends (Cmd+←/→).** target column = first / last **visible** column; row kept.
- **Shift** on any of the above keeps the anchor and moves only the active corner (the rect grows/shrinks; it
  may span hidden columns — included in the rect, per Q3).
- **Clamping.** No result leaves `0…lastRow` × the set of valid visible columns.

### FR2 — Minimal-reveal auto-scroll

After any cursor move, the viewport scrolls the **minimum** needed to bring the active cell fully into view;
if it is already fully visible on both axes, the viewport does not move. Vertical uses the same absolute
row-space clip math `landOn` already uses (`row × rowHeight − contentInsetTop`, clamped to the content/viewport
extent); horizontal adjusts the clip x so the active column's `[leftX, leftX+width)` fits inside
`[originX, originX+viewportWidth)`, clamped to `[0, maxX]`. Row-by-row scrolling emerges naturally (a cursor
at the bottom/top visible edge drags the view one row). This reuses the existing clip-scroll path — no new
full-file work, O(viewport).

### FR3 — Keyboard copy, select-all, Escape-clear (grid first responder)

- **Cmd+C** copies the current selection through the **existing** streaming-copy path unchanged. A bare cursor
  is a 1×1 `SelectionRect` (`isSingleCell == true`), so it copies exactly that one cell via the existing
  single-cell raw special case — not the whole row. No copy-engine change.
- **Cmd+A** selects the capped extent (unchanged — already implemented via `selectAll:`).
- **Esc** precedence gains one **lowest-priority** step. In order: (1) dismiss an open find/jump/dialect popup
  or clear an active search (unchanged); else (2) cancel an in-flight copy (unchanged); else (3) **clear the
  selection/cursor** (new). This precedence is a pure decision (see Decision 2 / AC-G7), wired by
  `handleEscape`.
- **No focus hijack (inherited, no new work).** These actions are declared on `SheetTableView` and fire only
  while the table is first responder; when a find/jump/Where text field has focus, IT is first responder and
  the framework routes Cmd+C / Cmd+A / arrows to the field. macOS gets focus-scoping for free from the
  responder chain — this is verified as a human-GUI-pass item, not re-implemented.

### FR4 — Accent active-cell focus outline

The active-corner cell (`selection.active`) of **every** selection — keyboard- or mouse-created,
single-cell or multi-cell (Q2) — renders a 2 pt outline resolved from `NSColor.controlAccentColor`, inset
~1 pt, drawn atop the existing 2 pt muted-gray marquee. On a bare 1×1 cursor the outline simply coincides with
the marquee cell. Distinct by geometry from the rounded, inset accent find-highlight chips (a full-cell square
outline vs. an inset rounded chip), so "active cursor", "selected range", and "search match" stay
distinguishable. No hardcoded color — the outline follows light/dark and live accent changes (the same accent
resolution the find highlights already use).

---

## Non-functional constraints

- **Zero cold-start / scroll regression.** The reducer and reveal-target math are O(1) / O(visible columns),
  run only on a discrete key press — never per frame, never per scanned byte, never O(file). Auto-scroll
  reuses the existing clip-scroll path (no `reloadData`, no relayout). The PROJECT cold-start (< 500 ms) and
  O(viewport)-open guarantees are untouched (this is all post-open input handling).
- **Single source of truth for knobs.** Each tunable is ONE named constant / resolver read by every consumer:
  `pageRows` (derived once from the live viewport height and `rowHeight`), `rowHeight` / `contentInsetTop`
  (existing `GridMetrics` / `NativeGrid`), the outline metrics (2 pt width, ~1 pt inset), and the accent color
  (`controlAccentColor`). Changing a knob is one line in one place.
- **Theming, no hardcoded colors.** The outline resolves from the system accent; correct in light + dark and
  under a live accent change.
- **No new runtime dependency.** Pure Swift + AppKit already in the target; no package/manifest change.
- **No frozen-surface change.** No `api/` edit; no amendment to the frozen `Selecting` protocol or any
  SHA-pinned Swift contract (see AC-G7).

---

## Component decomposition & data flow

All changes are in the macOS frontend implementation targets (`Sources/LessSheetKit`, `Sources/LessSheetApp`)
plus **one new pure-logic contract** the planner freezes (see Decision 1). Existing parts touched:

- **New pure reducer (Decision 1)** — a display-free keyboard-navigation reducer: `(current Selection?, a
  navigation context, a key command) → new Selection?`, where the navigation context carries the `GridExtent`,
  the ordered **visible-columns** list, the `pageRows`, the `topVisibleRow`, and the `firstVisibleColumn`. It
  handles seed-no-step, visible-column stepping, page / document / line targets, and clamping, and it produces
  its result by delegating the final geometry to the **frozen `Selecting`** (`select` / `extend(_:to:in:)`) —
  no duplicated clamping, no new selection algebra (Decision 2). Lives as a new protocol in
  `Sources/Contracts` (planner-frozen) + an implementation in `Sources/LessSheetKit`, pinned by a frozen
  conformance test, exactly like `Selecting`/`SelectionModel`.
- **New pure reveal-target math (Decision 1)** — `(active cell + a viewport-geometry descriptor) → minimal new
  clip origin | no-move`. Pure arithmetic mirroring `landOn`'s clamp; gate-testable byte-exact. May be a
  sibling type or folded into the reducer's output — the planner's call; the requirement is that it is pure
  and gate-tested.
- **New pure Escape-precedence resolver (Decision 2)** — `(popupOpen/searchActive, copyInFlight, hasSelection)
  → one action` in the FR3 priority order; `handleEscape` calls it (no branch logic duplicated in the
  controller).
- **`DocumentModel` (`ViewerModel+Selection.swift`)** — `moveSelection` (and new page/document/line/seed
  entry points) route through the new reducer instead of calling `Selecting` directly; the app assembles the
  navigation context from state it already computes (`currentTopDataRow`-equivalent top row, `windowColumns()`
  / `visibleColumns`, viewport `pageRows`), then hands the reducer's reveal target to the grid.
- **`SheetTableView` (`NativeGridChrome.swift`)** — adds the `NSStandardKeyBindingResponding` overrides for
  the new keys (page / document-begin-end / line-begin-end and their `…AndModifySelection:` variants),
  alongside today's arrow overrides, all via `interpretKeyEvents` (Decision 4). `handleEscape`
  (`NativeGrid+Selection.swift`) gains the clear-selection fallback via the pure resolver.
- **`NativeGridController` (`NativeGrid+Selection.swift`)** — after a keyboard move, applies the reducer's
  reveal target to the clip (the existing `landOn`-style scroll) and calls `refreshSelectionDisplay`.
- **`DocumentModel.windowSelectionMarks` + `SelectionMark` (`ViewerModel+Selection.swift` / `GridView.swift`)
  + `SheetRowView` (`NativeGridRowView.swift`)** — `SelectionMark` (implementation layer, not frozen) grows an
  `isActive` bit set for the `selection.active` cell; `SheetRowView.drawColumn` draws the accent outline on
  that cell atop the marquee.

**Data flow:** key event → `SheetTableView` `interpretKeyEvents` → the mapped `move…`/`page…`/`scrollTo…` /
`moveTo…` override → `NativeGridController` → `DocumentModel` assembles the navigation context → **pure reducer**
→ new `selection` (via frozen `Selecting`) + **reveal target** → controller applies the minimal clip scroll +
`refreshSelectionDisplay` → `SheetRowView.draw` paints the marquee + the accent outline on the active cell.
Cmd+C is unchanged (`copySelection` → the existing streaming path; a 1×1 rect → single-cell raw).

---

## External interfaces

- **Consumes (unchanged):** the frozen `Selecting` geometry (`Sources/Contracts/Selection.swift`), the
  existing streaming copy (`DocumentSession.openCopy` → `next`/`close`), and the existing clip-scroll /
  landing mechanics. No `ls_*` core call is added or changed.
- **AppKit (existing usage, extended):** `NSResponder.interpretKeyEvents` + additional
  `NSStandardKeyBindingResponding` action overrides on `SheetTableView`; `NSColor.controlAccentColor`;
  `NSClipView.scroll(to:)` / `reflectScrolledClipView` (already used by `landOn`).
- **New (planner-frozen) Swift contract:** the keyboard-navigation reducer protocol + its supporting value
  types (command enum, navigation context, reveal target), in a NEW `Sources/Contracts` file — pinned by a
  frozen conformance test. This is additive; it edits neither AC23-pinned file.

---

## Technology decisions

All decisions here are **feature-local** to the macOS frontend. The existing PROJECT stack settles the rest;
**`PROJECT.md` is unaffected** (it records no keyboard-navigation or macOS-selection decision as a project-wide
stable choice).

### Decision 1 — Pure, gate-testable logic (reducer + reveal math) in a new frozen Swift contract

The keyboard-navigation reducer and the minimal-reveal auto-scroll math are **pure** (no AppKit, no pixels):
a new protocol in `Sources/Contracts` (planner-frozen) with its implementation in `Sources/LessSheetKit`,
pinned by a frozen conformance test — exactly the layering the frozen `Selecting`/`SelectionModel` and the
`ColumnLayouting`/`ColumnLayout` split already use, and the direct analog of `ARCH-gtk-a11y.md` Decision 2's
`lsg_*` pure module. Only the key-event routing, the clip scroll, and the outline paint stay
display-dependent (human pass). *Rationale:* the gate then verifies seed-no-step, visible-column stepping,
page/document/line targets, clamping, and the auto-scroll target arithmetic **headlessly via XCTest**, with no
running app — the bulk of the correctness risk in this slice. *Alternative rejected:* keeping the logic inside
the `NativeGridController` / `SheetTableView` (AppKit-bound) — it would push all geometry verification into the
non-deterministic human GUI pass, against the project's established layered discipline.

### Decision 2 — Compose the frozen `Selecting`; do not extend or duplicate it

The reducer computes a **target cell** for each command and produces the new selection by calling the existing
frozen `Selecting.select` (collapse) / `extend(_:to:in:)` (shift-extend). It does NOT amend the frozen
protocol and does NOT re-implement clamping or the anchor/active algebra. *Rationale:* single source of
selection geometry (the memory rule), no frozen-contract change, and the visible-column / page / document /
line behaviors are expressible purely as *which target cell* to feed the existing geometry. The
Escape-precedence resolver is likewise a small pure decision, wired (not duplicated) by `handleEscape`.
*Alternative rejected:* growing `Selecting` with visibility-aware / page / document variants — a frozen-surface
change (two-key CHANGE-REQUEST) for behavior that composes cleanly over the existing three methods.

### Decision 3 — Accent outline from `NSColor.controlAccentColor` (no hardcoded color)

The active-cell outline resolves from the system accent — the same accent the find highlights already use
(`NativeGridRowView.swift` resolves `NSColor.controlAccentColor` today) — so it tracks light/dark and live
accent changes with no literal color constant. 2 pt stroke, ~1 pt inset, drawn atop the muted-gray marquee.
*Rationale:* PROJECT/parent theming discipline (no hardcoded colors) and geometric distinctness from the
rounded find-highlight chips. *Alternative rejected:* a bespoke focus color — fails the no-hardcoded-color bar
and would need its own light/dark tuning.

### Decision 4 — Physical-key → command routing via `interpretKeyEvents` + standard actions

Key routing extends today's mechanism: `SheetTableView` overrides the relevant `NSStandardKeyBindingResponding`
actions (arrows already; adding page / document-begin-end / line-begin-end and their `…AndModifySelection:`
variants), with `interpretKeyEvents` doing the key→action translation — no hand-rolled keyCode switch, and
focus-scoping inherited from the responder chain. *Implementer docs-first note:* the exact selector each
physical key/Cmd-combo maps to (e.g. Home/End and Cmd+↑/↓ vs. `scrollTo…`/`moveTo…Beginning/EndOfDocument:`,
Cmd+←/→ vs. `moveTo…EndOfLine:`) must be verified against the installed AppKit key-binding behavior (a small
probe), not assumed — the same "verify the API, don't trust memory" discipline the workspace applies to Zig.
The pure reducer is deterministic and gate-tested regardless of which selector fires, so this verification is a
routing detail, not a correctness risk for the geometry. *Alternative rejected:* a custom `keyDown` keyCode
parser — loses free focus-scoping and the framework's modifier handling.

---

## Acceptance criteria

**GATE** criteria are deterministic macOS **XCTest** over the pure logic (the reducer, the reveal-target math,
the Escape-precedence resolver, and the single-cell copy rect) — no running app, no synthetic key events.
**HUMAN GUI PASS** criteria are validated by the author on macOS (accent outline in light/dark, the keyboard-only
copy feel, focus-scope, no cold-start/scroll regression) because live key routing, focus, and rendered
appearance are inherently GUI-interactive (and this slice must not trigger TCC/screenshot prompts — visual
checks are handed to the author).

### GATE — deterministic, headless (macOS XCTest)

- **G1 — Seed (no step).** From a `nil` selection, EVERY navigation command (↑ ↓ ← →, Page Up/Down, Home/End,
  Cmd+↑/↓, Cmd+←/→, and each Shift variant) returns a 1×1 selection at `(topVisibleRow, firstVisibleColumn)`
  from the context, with **no step applied** (`anchor == active ==` the seed cell). Byte-exact corners across
  fixtures (varying top row, first visible column, and a scrolled column window).
- **G2 — Directional move / extend over VISIBLE columns.** With a seeded selection: plain ↑/↓ steps ∓1 row and
  collapses; plain ←/→ steps to the **adjacent visible column** (skipping hidden columns) and collapses;
  Shift variants keep the anchor and step only the active corner. Fixtures include (a) a visibility set with
  interior AND edge hidden columns — assert ←/→ skip them and clamp at the first/last visible column; (b) a
  Shift+→ whose resulting rect SPANS hidden columns — assert the rect's `left…right` INCLUDES the hidden
  columns (visibility-blind, per Q3). Byte-exact.
- **G3 — Page / document / line commands.** Page Up/Down step ∓`pageRows` (clamped); Home/End and Cmd+↑/↓ →
  row `0` / `lastRow` (active column kept); Cmd+←/→ → first / last visible column (active row kept); the Shift
  variant of each keeps the anchor and moves only the active corner. Byte-exact corners across fixtures
  (small page vs. page larger than the remaining rows; active column both visible-interior and at an edge).
- **G4 — Clamping + empty extent.** No result leaves `0…lastRow` × the valid visible-column set (a step past
  an edge stays on the edge). On an empty extent (0 rows OR 0 visible columns) every command is a no-op
  (`nil`), matching the frozen `Selecting` producing-ops.
- **G5 — Minimal-reveal auto-scroll target math (pure).** Given an active cell + a viewport-geometry descriptor
  (`rowHeight`, `contentInsetTop`, `originY`, `viewportHeight`, `maxY`; the active column's `leftX`, `width`,
  `originX`, `viewportWidth`, `maxX`), the function returns: **no change** when the cell is already fully
  visible on both axes; the exact `landOn`-style clamped origin when the cell is above / below / left / right
  of the visible region; each axis independent; the result clamped to `[min, max]` per axis. Byte-exact across
  representative cases (already-visible; just past top; just past bottom; off-left; off-right; a corner
  requiring BOTH axes).
- **G6 — Single-cell keyboard copy rect unchanged.** A bare 1×1 seeded/collapsed selection yields a
  `SelectionRect` with `isSingleCell == true`; the existing copy path takes the single-cell raw special case
  and copies exactly that one cell's raw value (asserted through the existing SelectCopy / stream-copy tests
  with a 1×1 rect). No copy-engine change and no whole-row copy for a bare cursor.
- **G7 — Escape-precedence resolver (pure truth table).** The resolver maps
  `(popupOpen/searchActive, copyInFlight, hasSelection)` to exactly one action in priority order —
  dismiss-popups > cancel-copy > clear-selection > nothing — for the full truth table (enum-exact); a
  structural check confirms `handleEscape` dispatches on the resolver rather than duplicating the branch
  logic.
- **G8 — Frozen-surface integrity.** The new reducer + reveal-math + resolver are pinned by frozen conformance
  test(s) (`let _: any <NavProtocol> = <Impl>()`), and the existing `Selecting`/`SelectionModel` conformance
  is unchanged. The `AmendmentContractGuardTests` **AC23 SHA-256 baselines are UNCHANGED** for both pinned
  files — `api/lesssheet.h` (`df0436b6…`) and `apps/macos/Sources/Contracts/ColumnPanel.swift` (`d4ed5d70…`):
  this slice edits neither (all new contract lives in a NEW `Sources/Contracts` file). The whole gate stays
  green: `swift build -Xswiftc -warnings-as-errors`, `swiftlint --strict`, `swift test`.

### HUMAN GUI PASS — the author, on macOS (recorded; not gate-blocking)

- **H1 — Keyboard-only selection + copy, end to end.** With nothing selected, the first arrow seeds the cursor
  at the top-left visible cell (accent outline visible) with no jump; subsequent arrows move it and the
  viewport auto-scrolls the minimum to keep it visible; Shift+arrows extend; ←/→ move over visible columns
  (scrolling horizontally as needed); Page Up/Down, Home/End, and Cmd+arrows behave per FR1; Cmd+C on the bare
  cursor copies exactly that one cell (paste into Numbers/TextEdit to confirm the single value); Cmd+A then
  Cmd+C copies the extent — **all with no mouse**.
- **H2 — Accent outline in light + dark.** The active cell shows the 2 pt system-accent outline over the
  muted-gray marquee; it reads correctly in light and dark and follows a live system accent-color change; on a
  multi-cell (mouse or Shift) selection the outline marks the active corner; it stays visually distinct from
  the rounded find-highlight chips and from a plain selected cell.
- **H3 — Esc precedence + focus scope.** Esc dismisses an open find/jump/dialect popup (or clears an active
  search) first; with none open it cancels an in-flight copy; with neither it clears the selection/cursor.
  While typing in the find/jump/Where field, Cmd+C / Cmd+A / arrows act on the FIELD, not the grid (no
  hijack).
- **H4 — No regression / native feel.** Existing mouse selection, drag, gutter/header select, column
  resize/auto-fit, find/jump/filter/copy/settings, and vertical+horizontal scrolling are unchanged; the
  keyboard auto-scroll feels native (no overshoot or jitter; row-by-row emerges at the edges); cold-start feel
  is unchanged.

---

## Open Questions

None. The four macOS-specific questions are answered (the author, 2026-07-22): Q1 seed-only/no-step; Q2 accent
outline on every selection's active corner (2 pt `controlAccentColor`, ~1 pt inset, over the muted-gray
marquee); Q3 keyboard cursor steps over visible columns only, shift-extends still span hidden columns; Q4 adopt
the Cmd+arrow synonyms over the same reducer. Awaiting explicit sign-off to freeze.
