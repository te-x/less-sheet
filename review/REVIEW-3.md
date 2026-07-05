# REVIEW-3 — walking-skeleton (round 3)

Scope: delegate-owned-window architecture (WindowGroup dropped; windowless `Settings` scene for
menus; AppDelegate creates exactly one NSHostingView window) + spreadsheet grid fill with a
single-Canvas body grid (`GridLines`). Changes confined to
`apps/macos/Sources/LessSheetApp/AppUI.swift` (verified via git status; `main.swift` unchanged
since round 1; frozen paths untouched). Reviewer re-ran the root gate: **GATE: PASS**.

All behavior checks headless and TCC-free (markers via `--stderr`, visuals via
`LESSSHEET_DUMP_FRAME`, window presence via CGWindowList enumeration — no capture/scripting APIs).

## Launch determinism — the round-2 fragility is fixed (measured, 3 runs per mode, release)
| Mode | Markers per launch | Window count | first_rows_visible_ms |
|---|---|---|---|
| Direct exec (tiny.csv) | 1 / 1 / 1 | 1 / 1 / 1 | 171, … |
| `open -n -a … --args` (tiny.csv) | 1 / 1 / 1 | 1 / 1 / 1 | 160 / 167 / 146 |
| Doc-launch `open -a` (1 GB fixture) | 1 / 1 / 1 | 1 / 1 / 1 | 235 / 268 / 272 (median 268 < 500) |

- Dump inspected (tiny.csv): data anchored top-left, filler columns/rows to the window edges,
  and the data→filler seam hairline present and continuous across ALL columns — the reported
  missing-seam bug is fixed. Missing path: in-window error panel dump correct, NO marker.
  Empty file: stderr completely silent. Replace-document in a running instance: single window
  reused, exactly one additional marker (2 markers for 2 opens) — contract semantics hold.
- No stray window at launch in any mode (always exactly one on-screen window).

## Findings

1. **[impl] BLOCKING — criterion 18 memory budget exceeded: ~122–156 MB vs < 100 MB.**
   Measured on the 1 GB fixture doc-launch (release, marker fired, steady state):
   ps RSS **154–156 MB**, `footprint` phys_footprint **122 MB** (peak 122). Round 2 measured
   ~96 MB ps-RSS with the same method — this is a ~60 MB regression introduced by the new grid,
   not noise, and it fails the budget on either metric. Attribution: tiny.csv run is 39 MB
   phys_footprint / ~97 MB ps-RSS → the ~83 MB delta is per-document rendering. Two compounding
   causes in `SpreadsheetGrid`:
   (a) `bodyBlock` wraps ALL body rows in one eager `VStack` placed as the Section content of
   the `LazyVStack` — a single child defeats laziness, so all 200 rows × columnCount cells
   materialize (round 2's ForEach rows were direct, lazy children);
   (b) `GridLines` is a single `Canvas` spanning the entire body block (≈ 900 pt × 5600 pt for
   200 × 28 pt rows), whose rasterized backing store at 2× scale is ≈ 1800 × 11200 × 4 B ≈ 80 MB.
   Fix within the contract (view code is implementer-owned): keep rows as direct lazy children
   and draw grid lines per-row (or per visible chunk / bounded overlay) instead of one
   full-height Canvas; re-verify with `footprint`/ps on the 1 GB fixture. Note cold start also
   crept up (median 177 → 208 → 268 ms across rounds); still passing, likely same cause.

2. **[impl] minor — empty Settings window reachable.** The windowless `Settings { EmptyView() }`
   scene necessarily adds "Settings…" (Cmd-,) to the app menu; invoking it opens an empty
   preferences window. Not reachable at launch (window count verified = 1), but it is a stray
   user-reachable window. Cosmetic for this slice; fix or accept explicitly (human-eyes to
   confirm appearance — menus cannot be driven headlessly without TCC).

3. **[impl] cosmetic — duplicate "View" menu** (coordinator-observed; cannot enumerate menus
   headlessly). `CommandMenu("View")` adds a second View menu next to SwiftUI's built-in one.
   Non-blocking; merging via a `CommandGroup` placed in the system View menu is the usual fix.

4. **[impl] cosmetic — window frame autosave never restores position.** `showMainWindow()` calls
   `center()` after `setFrameAutosaveName("LessSheetMain")`, re-centering on every launch and
   discarding any restored origin. Harmless this slice.

5. **Observation — header/body grid-line geometry.** Header cells draw their vertical hairline
   inside the trailing edge (`[cellWidth-1, cellWidth]`) while the body Canvas strokes centered
   on `x = c·cellWidth` (`±0.5 pt`) — a half-point offset at the pinned-header junction, and the
   Canvas's outermost right/bottom strokes are half-clipped at the exact frame edge. Not visible
   in the 2× dump; on-screen check is human-eyes. Cosmetic.

6. **Observation — lifecycle code is sound.** `isReleasedWhenClosed = false` with a strong
   `mainWindow` reference avoids the classic programmatic-NSWindow over-release;
   `applicationShouldTerminateAfterLastWindowClosed = true` gives close-to-quit (single-window
   viewer semantics — with the Settings window open, termination waits for both; acceptable);
   `applicationShouldHandleReopen` re-shows the window idempotently. Close-button behavior
   itself is human-eyes (cannot performClose headlessly without scripting APIs).

7. **Observation — dark mode (code-level PASS).** Grid and header use semantic
   `NSColor.gridColor` / `.windowBackgroundColor`, which adapt to appearance automatically;
   actual dark rendering is human-eyes.

## Contract conformance re-check
- Root gate run by reviewer: PASS (backend zig tests + 11 frozen Swift tests binding the real
  linked core). `Package.swift`, `Sources/Contracts`, `Tests`, `api/`, `backend/contracts|tests`
  untouched. Marker semantics verified per contract: exactly one per open reaching the table,
  measured from process start, silent on error and empty. Bundle 360 KB (single-digit MB).

## Human-eyes-only items (not attempted, per TCC constraint)
- Menu bar contents/function: File › Open… panel, the checkable View › First Row Is Header
  toggle, the duplicate View menu, the Settings… item behavior (finding 2).
- Live scroll behavior: sticky header pinning and header/body line alignment while scrolled
  (finding 5), scrollbar behavior with filler cells.
- Close-button → quit behavior (finding 6) and Dock-click reopen.
- Dark-mode rendering (finding 7).

## Verdict
**FAIL** — finding 1 (measured memory-budget violation, `[impl]`) blocks; findings 2–5 are
minor/cosmetic and can ride along in the same fix round. Launch determinism, criterion 19, the
seam fix, marker semantics, and contract conformance are all verified good.
