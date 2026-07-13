# REVIEW — cc-macos defect fix (column-config AC21 live-pass findings)

**Final verdict: PASS** (reviewer PASS + `gate.sh --require-frozen apps/macos` PASS, 132 tests / 13 suites).
macOS-only; `api/lesssheet.h` and Swift Contracts byte-identical. Bound tree `037b3d4f…`; committed `b7f8e80`
(fix + frozen regression assertions). Two human gates remain (below).

## Findings (reported by the human during the column-config AC21 live-pass)
1. Jump-to-row did not move the viewport.
2. Find located matches but did not scroll to the occurrence.
3. Dragging a rectangle selection blanked visible cells into the loading glyph.
4. Clicking an already-selected cell/row/column did not deselect (no toggle).

## Fix (implementer ⇄ reviewer, 1 round + planner contract amendment)
- **1 & 2** — model landing requests could be coalesced before AppKit attachment or reset during an open
  refresh. `ViewerModel` now directly schedules the native landing; `NativeGrid` preserves pending landings
  through reload/window attachment; find reuses the same landing path.
- **3** — rectangle selection reconfigured every row, letting loaded cells fall back to loading placeholders.
  Selection refresh now updates only the overlay marks, leaving cell content/pending state untouched.
- **4** — input handling always replaced the selection. Click is now distinguished from drag; a second
  mouse-up on the same target deselects; entire-row and entire-column toggles added.
- Reviewer: **no `[impl]` finding** (fixes correct). One `[contract]` finding — the frozen tests didn't
  assert the new physical signals. Planner (Mode B) amended `NativeGridTests.swift`: jump & find landings must
  show `target_visible=true` (real scrolled `NSClipView`, not just resolved model row), and a new
  `selectionSecondClickDeselectsCellRowAndColumn` asserts `deselected=true` for cell/row/column. No existing
  assertion weakened.

## Round 2 — scroll-during-search (found in the human re-test)
After confirming round-1 (jump/find/select), the human found that an active Find popup **disabled free
scrolling** (only match-stepping worked until Find was dismissed). Root cause: `anyPopupOpen` installed a
full-window transparent SwiftUI scrim that consumed scroll-wheel events. Fix: an AppKit click-away scrim
(`OverlayView`) that dismisses on click but forwards wheel events unchanged to the grid's `NSScrollView`
(`NativeGrid.forwardScrollWheel`); search stays active. Reviewer: no `[impl]`; one `[contract]` → planner froze
`scrollWheelMovesViewportWhileFindPopupActive` (`LESSSHEET_FIND_SCROLL_ACTIVE=1`: probe_ready/moved/
search_active/popup_active all true). Committed `a4e57d1`; `--require-frozen` gate PASS (133 tests); reviewer
**PASS**. Human-confirmed live ("perfect now"). Rectangle-select `content_preserved` (round-1 human-gated item)
also **confirmed** by the human ("selecting rectangle is perfect now").

## Human gates outstanding
- **Rectangle-select `content_preserved`** cannot be asserted headlessly: `SelectCopyProbe` emits
  `selection_repaint content_preserved=…` only when a materialized non-pending row view exists; off-screen
  headless runs log `skip=no_loaded_row`. Routed to a human visual pass (drag a rectangle over loaded rows;
  confirm text never turns into loading placeholders). Documented follow-up: an implementer probe change
  (force `apply()` + page-wait or a real scroll before the repaint check) would make it gate-observable.
- **Column-panel interactive-latency (AC21) trace** — still an outstanding human NFR gate from the
  column-config feature itself (panel open/search/scroll/redraw ≤100 ms, <500 ms).

Result: `swift build` green; `swift test` 132/132; `gate.sh --require-frozen apps/macos` PASS.
