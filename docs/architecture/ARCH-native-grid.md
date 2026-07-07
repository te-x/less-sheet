# ARCH — native-grid

Replace the SwiftUI `ScrollView`/`LazyVStack` grid with an `NSTableView`-backed grid (native
row recycling) so that **any landing — find or jump, any distance — stalls the main thread
< 100 ms**. A frontend rendering slice: no core/ABI changes, no frozen-Kit-protocol changes
expected; every existing user-visible behavior of the grid is preserved and re-proven by the
existing probe suite. Decisions made with the author on 2026-07-07.

## Problem & scope

Evidence (committed probes, `c5f2083`): SwiftUI's scroll machinery blocks the main thread
75–1200 ms when moving the viewport across a ~33 M-point content space; a synthetic-metric
attempt reduced offsets 500× and still stalled. `NSTableView` recycles row views and its
`scrollRowToVisible` is O(viewport) by construction — the standard macOS mechanism for
million-row tables (and the native-components-first preference applies).

**In scope**: the grid rendering engine and its integration seams (landing path, paging,
layout probes, dump capture). **Explicit non-goals**: row selection (stays a pure viewer —
decided), column drag-resize (column-ergonomics slice — decided), any change to core, ABI,
Kit protocols, frozen tests, find/jump semantics, overlay controls, popups, Settings window,
launch behavior, or the marker.

## Inputs / Outputs

Unchanged from today, by definition: the grid renders the materialized row window served by
`DocumentModel` (viewport + buffer paging with hysteresis), and emits scroll-position changes
that drive paging and the estimate-then-refine scrollbar. All user-visible behavior is the
CURRENT behavior — this doc pins equivalence, and the deltas below.

**The one behavioral delta (the point of the slice)**
- Landing on any row (jump landing, find landing, wrap landing): main-thread gap < 100 ms,
  measured by the existing `LESSSHEET_LANDING_STALL` probe (16 ms heartbeat, per-landing
  isolated max gap), for targets at any distance, in release, on the 2.6 GB fixture.

**Bonus delta (verification win)**
- The live grid becomes self-capturable: `NSView.cacheDisplay` renders the REAL grid (not a
  parallel mirror) to the dump PNG without TCC — `LESSSHEET_DUMP_FRAME` gains a live-grid
  mode. The SwiftUI `DumpGrid` mirror remains for overlay/popup scenes that ImageRenderer
  handles; new grid-content verification prefers the live capture. This closes the
  "dumps can't see the live path" class of escape for grid content.

## Functional requirements (equivalence pins + mechanism latitude)

1. **Visual equivalence** to the current grid, verified by frame comparison on the standard
   fixtures: spreadsheet-style fill to BOTH window edges (empty filler cells with identical
   hairlines, incl. the data→filler seam), glass header band (one continuous band, window top
   → header bottom, content frosting under it), faded 1-based row-number gutter, uniform
   hairlines, semantic colors (dark mode automatic), tabular numerals, same row height and
   type treatment, header semibold, EOF overscroll (last row lands above the floating
   controls). Mechanism latitude: native `NSTableHeaderView` with custom cells vs. retained
   SwiftUI overlay band; filler as synthetic recycled rows/columns; the AppKit glass
   equivalent (`NSGlassEffectView` on macOS 26) vs. layered SwiftUI — implementer's choice,
   pinned by the rendered result, with one constraint: NEVER rely on emergent titlebar/
   scroll-edge compositing (the memory-logged lesson) — the band is drawn explicitly.
2. **Gutter pinning**: row numbers stay fixed against horizontal scroll, scroll vertically
   with rows, width fits the largest visible number, never mistakable for data. (Frozen-
   first-column mechanism — synced twin table, overlay, or floating column — implementer's
   choice.)
3. **Sticky header**: pinned vertically, scrolls horizontally with its columns, exactly as
   today.
4. **Hidden-column reflow**: hiding/showing columns via Settings reflows immediately
   (native `NSTableColumn` hiding is the obvious mechanism); last-visible rule unchanged
   (enforced in the frozen view-model, untouched).
5. **Scrolling**: wheel/trackpad feel native; estimate-then-refine scrollbar (row count =
   the estimate, refining to exact — `noteNumberOfRowsChanged`/`reloadData` on refinement
   must not visibly jump the viewport row); sequential scroll never blocks (paging stays
   off the scroll path, hysteresis preserved); keyboard scrolling (arrows/page/home/end)
   may work natively — free win, no requirement either way, but Home/End must not
   reintroduce a stall (End = same path as jump-to-end).
6. **Landings**: viewport lands exactly on the target row (find/jump/wrap), current-match
   highlight correct; < 100 ms main-thread gap per landing (THE requirement).
7. **Highlights**: subtle on all matching visible cells, strong on current match, header/
   filler never highlighted — same semantics, same colors, re-rendered on match-state
   change without full reloads.
8. **No selection**: rows are not selectable/clickable; no selection highlight exists.
9. **Composition seam**: the grid ships as an `NSViewRepresentable` (or equivalent) INSIDE
   the existing SwiftUI shell — overlay controls, popups, error/empty states, Settings, and
   the delegate-owned-window architecture are untouched. The `LESSSHEET_LOG_LAYOUT` probe is
   reimplemented over AppKit frames (band/header/row1/scrollview, same log format).
10. **All existing env probes keep working** with identical log formats (`LESSSHEET_JUMP`,
    `LESSSHEET_FIND`, `LESSSHEET_FIND_STEP_SEQ`, `LESSSHEET_FIND_WRAP`,
    `LESSSHEET_LANDING_STALL`, `LESSSHEET_LOG_OFFSET`→equivalent, `LESSSHEET_HIDE_COLS`,
    `LESSSHEET_FORCE_*`, `LESSSHEET_DUMP_SCENE`) — they are the acceptance instrument.

## Non-functional constraints
- Cold start < 500 ms unchanged (expected to improve; measure).
- Steady-state RSS < 120 MB on multi-GB files after the scroll/jump/find workout (dump hook
  off; phys_footprint methodology).
- 60 Hz scrolling within the indexed region (reviewer-measured; no main-thread hitch
  > 17 ms attributable to row serving/recycling).
- O(viewport) discipline: row views recycled; no structure grows with file size beyond the
  existing model state; the AppKit huge-content-height constraint warning should disappear
  (note its absence).
- Zig core untouched; bundle stays single-digit MB; macOS 26; Reduce Transparency degrades
  the glass band to an opaque material with legible header text (as today).

## Component decomposition & data flow
- **apps/macos LessSheetApp only**: `GridView.swift` replaced by the NSTableView-backed
  implementation (new files as needed, e.g. `NativeGrid.swift` with the representable,
  data-source/delegate, row/cell view classes, gutter mechanism); `ViewerModel` keeps its
  paging/window/highlight state (the table's data source reads the SAME model — landing =
  `landOn` + `scrollRowToVisible` instead of `scrollTo(y:)`); `FrameDump` gains the live
  cacheDisplay capture; probes rewired at the same log formats. Overlay/pills/Settings/
  AppUI structure otherwise untouched.
- **Frozen surfaces untouched**: api/, backend/, Sources/Contracts/, Tests/, Package.swift.
  The frozen Swift tests must pass UNMODIFIED — they pin the view-models and bridge, which
  this slice does not change. (If any frozen test turns out to pin ScrollView-specific
  mechanics, that is a planner conversation before any workaround — expected: none do.)

## External interfaces
None new. No dependencies added (AppKit is already linked via SwiftUI).

## Acceptance criteria (each testable)
1. `LESSSHEET_LANDING_STALL` on big2g.csv (release): 5 consecutive far landings alternating
   find/jump — max main-thread gap **< 100 ms per landing**, landings exact. The same run on
   HEAD's grid shows the current 500 ms-class stalls (comparative baseline recorded once).
2. `LESSSHEET_JUMP` sequence proofs unchanged: 10 M exact landing; reject
   999999999999 → restore; follow-up jump lands; heartbeat gaps < 500 ms during scans.
3. `LESSSHEET_FIND` + `FIND_STEP_SEQ` + `FIND_WRAP` proofs unchanged: landings
   300000/900000/1500000/2100000 exact; searching holds position; wrap notice ~1 s.
4. `LESSSHEET_LOG_LAYOUT` (AppKit frames): band y[0,54], header y[32,54], row1 y[54,76]
   at rest; row1 fully visible; no overlap — same numbers as today.
5. Live-grid captures (cacheDisplay) on tiny + big fixtures match the pinned look:
   spreadsheet fill to both edges, seam line continuous, gutter faded + right-aligned,
   highlights subtle/strong, EOF overscroll with last row above the controls, dark-mode
   variant sane (capture once with NSAppearance forced dark).
6. Hidden-column reflow + dialect re-open + header toggle behave as today (dump/probe
   verified); estimate refinement does not visibly jump the viewport (probe: log first
   visible row across a refinement step — unchanged).
7. swift test: all frozen tests pass UNMODIFIED (25 viewer-ui + 17 find-seek).
8. Reviewer-measured (release): cold start (report; < 500 ms), RSS < 120 MB after workout,
   60 Hz scroll / no >17 ms hitches, the AppKit content-size warning gone.
9. No selection affordance exists (click a row: nothing); column widths not draggable.

## Open Questions
None. (Cell-rendering technique — NSTextField-based cell views vs. custom draw(_:) — plus
gutter and header mechanisms are implementer latitude, pinned by the rendered results and
the perf criteria above.)
