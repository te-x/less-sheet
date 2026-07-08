# REVIEW-7 — native-grid (frontend lane, apps/macos)

VERDICT: **PASS** — every ARCH-native-grid acceptance criterion is met and independently
re-measured in RELEASE on the 2.6 GB / 100M-row fixture. One non-blocking hygiene item
([impl] F1: the new file is untracked — `git add` it before commit). No `[contract]` findings.

Reviewed at contract 9f2b496. Diff (working tree vs HEAD): only
`Sources/LessSheetApp/{AppUI.swift (+5), FrameDump.swift (+78), GridView.swift (-238)}`
plus new `Sources/LessSheetApp/NativeGrid.swift`. Frozen surfaces (`api/`, `Sources/Contracts`,
`Tests/`, `Package.swift`) are 0-diff. (`.aidev/models.conf` + `.claude/agents/*.md` are
out-of-band harness model-routing edits, not part of this slice, not frozen paths.)

---

## 1. Probe-instrument integrity (the planner's named escape) — PASS

The frozen tests assert on `stderr` emitted by implementer-owned probe code, so a green stall
test is only meaningful if the instrument still honestly measures a main-thread gap. Result:

- **The instruments were not touched.** `git diff HEAD` for `FindControls.swift` (LANDING_STALL
  + FindProbe heartbeats), `JumpProbe.swift` (JUMP heartbeat + ScrollProbe/LOG_LAYOUT emitter),
  and `ViewerModel.swift` (landing/paging/highlight state) is **0 lines** — byte-identical to the
  find-seek commit (c5f2083) that produced the RED 1255 ms baseline. The engine swap rewires the
  *consumer* of the model (scrollTo → landOn + clip scroll in the new `NativeGridController`),
  not the measurement.
- **The 16 ms landing heartbeat is honest.** `LandingStallProbe.startHeartbeat` is a real
  `Task { @MainActor in while !cancelled { await Task.sleep(16ms); gap = now - lastTick } }`
  using monotonic `DispatchTime.uptimeNanoseconds`. `maxGapMs` = max inter-tick gap over an
  isolated ~1.0 s window opened (`maxGapMs=0; lastTick=now`) immediately BEFORE each landing is
  triggered and reported at the next step; `worstGapMs` = max across all 5. Checked against every
  named softening: measurement is ON the main actor (a blocked main thread cannot schedule the
  sleep continuation → the gap surfaces); the landing window is not filtered (the full post-landing
  second is measured, and a late stall would surface in the next window and in `worst`); tick
  interval is 16 ms as documented; the only sleeps are the heartbeat tick and the inter-landing
  spacing (which do not reset the accumulator mid-window). Exactness is proven by a separate,
  un-fakeable path (the probes log the real model-landed row).
- **JumpProbe** uses the identical honest pattern at its documented 250 ms scan cadence.

Conclusion: the green is genuine, not a weakened yardstick.

## 2. Independent RELEASE measurements — PASS (see ## Measurements for full numbers)

- big2g (100M rows), `LESSSHEET_LANDING_STALL`, 3 runs: worst main-thread gap per run
  **25 / 18 / 26 ms** — every landing < 100 ms (baseline was ~1.3 s). Matches the implementer's
  18-30 ms claim.
- 3M marked fixture (release), where finds RESOLVE on real markers: real far FIND landings
  (incl. highlight re-render) at **31/47/46 ms**, jumps 17-23 ms — worst 47 ms, all < 100 ms.
- Gate stall test (`landingsStallTheMainThreadLessThan100ms`) run by me: PASS.

Honest caveat, reconciled: on the *unmarked* 100M fixture the find-steps do not resolve a match
inside the 1 s step window (the content scan is legitimately long and stays OFF the main thread —
`state=scanning total=0`), so on big2g steps 2/4/5 measure main-thread responsiveness during a
background scan (≤ 25 ms), while the two JUMPs are real far landings via estimate-seek. The
far-FIND-landing-with-highlight case is proven at 46-47 ms on the marked 3M fixture in release and
by the gate. Same `landOn` code path for jump/find/wrap, so distance is O(viewport) either way.

## 3. Visual equivalence via live cacheDisplay (light + dark) — PASS

Inspected PNGs (`/tmp/lswin/png/`): `big2g_grid_light`, `big2g_grid_dark`, `big2g_jump50m_live`
(widened 8-digit gutter), `big2g_eof_live` (EOF overscroll), `hl.live` (highlights on find.csv).

- Spreadsheet fill to BOTH edges with empty filler columns + hairlines; data→filler seam is one
  continuous full-width bottom hairline. Uniform hairlines, tabular numerals, semibold header.
- Faded, right-aligned 1-based gutter; widens correctly for large row numbers (verified at row
  50,000,000); it is a fixed strip with no horizontal content offset (pinned vs h-scroll — code).
- Sticky header id/ref/tag; LOG_LAYOUT confirms it at y[32,54] (below).
- **Dark mode (never verified before this slice): PASS** — adapted semantic colors, dark band
  stand-in, LEGIBLE light header text, dimmed gutter, visible hairlines.
- Highlights: STRONG fill + accent border on the current match; SUBTLE fill on all other matching
  cells; header and filler rows never highlighted; non-matches never highlighted; smart-case
  correct (6/6 needle matches). 
- **No hardcoded colors**: `NativeGrid.swift` uses only semantic NSColors
  (`textBackgroundColor/gridColor/controlAccentColor/labelColor/secondaryLabelColor/
  windowBackgroundColor`) + `NSGlassEffectView`. Grep for white/black/`Color(.sRGB`/literal RGB =
  none. The `.usingColorSpace(.sRGB)` calls are appearance-correct resolutions of *semantic* colors
  for the bitmap capture context (a thoughtful fix for dynamic-catalog resolution in dark capture).

## 4. Exactness & layout probes — PASS

- `LESSSHEET_JUMP` big2g: 1-based 10000000 → 0-based 9999999 EXACT; 999999999999 → REJECTED,
  viewport restored (firstRow 9999996), never clamped, exact_total=100000000; follow-up 50000000
  → 49999999 EXACT. Scan heartbeat gaps 301-312 ms (< 500 ms bound).
- `LESSSHEET_FIND_STEP_SEQ` 3M: landings 200000/1400000/2000000/2800000 exact, in order, final
  count 4. (NB: these are the native-grid fixture's markers; the 300000/900000/1500000/2100000 in
  the brief are the older find-seek fixture, not this slice.)
- `LESSSHEET_LOG_LAYOUT` big2g: band y[0,54], header y[32,54], row1 y[54,76], scrollview minY 0.0.
- Estimate-refinement viewport stability: code-verified — `apply()` refines the scrollbar via
  `reloadData()` (not `noteNumberOfRowsChanged`) and restores the clip origin
  (`scroll(to: origin)`); rows are absolute at `row*rowHeight`, so the visible row is preserved.
  (Gate-scale/headless observation of a mid-refinement window is not deterministic — noted by the
  planner; the mechanism is the sanctioned one.)

## 5. Non-regression — PASS

- 46/46 tests pass (42 pre-existing viewer-ui/find-seek UNMODIFIED — `Tests/` 0-diff — + 4 new
  native-grid probes). Root gate PASS (api/ integrity + backend + frontend chained).
- No frozen path touched. Overlay/pills/Settings/popups + delegate-owned window untouched
  (`OverlayView/SettingsWindow/GuessPills/main/LaunchTiming` all 0-diff); grid still sits under the
  overlay in the same `documentContent` ZStack; AppUI change is 5 lines (dump-scene routing only).
- **AppKit huge-content-size warning is GONE** — grepped every big2g/capture stderr log; absent.

## 6. Cold start & RSS (release) — PASS

- Cold start big2g: 185 / 214 / 221 / 231 / 236 ms across runs — all < 500 ms.
- Steady-state phys_footprint after the jump/find/scan workout (dump hook OFF): **34.1 MB**
  (peak 34.2 MB) via both `vmmap --summary` and `footprint` — well under 120 MB. (`ps` RSS shows
  ~820 MB = resident mmap'd file pages; phys_footprint is the ARCH-specified metric and excludes
  them.)

## 7. No selection / no column drag-resize — PASS (code-level)

`selectionHighlightStyle=.none`, `allowsColumnResizing=false`, `allowsColumnReordering=false`,
`allowsColumnSelection=false`, `column.resizingMask=[]`, `shouldSelectRow→false`,
`selectionShouldChange→false`, `SheetRowView.drawSelection` no-op, `isEmphasized` pinned false.
(Synthetic-click confirmation needs GUI events — human-eyes / not headless-probeable.)

---

## Findings (all NON-BLOCKING)

1. **[impl] `NativeGrid.swift` is untracked** (`git status: ?? NativeGrid.swift`). The working
   tree builds green and the gate passes, but a commit of only tracked changes would omit the
   replacement grid and not build from a clean checkout. Action: `git add` it before the commit.
   (This is the real kernel of Claude's sole finding below; Claude's "does not build" is an artifact
   of `review.sh` feeding `git diff`, which excludes untracked files — the file exists and compiles.)
2. **[impl] nit** `LESSSHEET_DUMP_FIRSTROW` is not honored by the live cacheDisplay path
   (`FrameDump.captureLiveGrid` never calls `dumpMaterialize`), so the live-grid initial dump always
   renders row 1. Verification-tooling only: the widened gutter / large-number rendering IS correct
   and was verified via a jump-arrival live capture (row 50,000,000). Fix optional.

Note (not a finding): the glass band in cacheDisplay PNGs is a semantic material STAND-IN, not the
live frost (inherent to `cacheDisplay`/`ImageRenderer`; `NSGlassEffectView` renders blank
off-screen). This is ARCH-acknowledged — the frost is a live/on-screen check. The band is drawn
EXPLICITLY (not emergent titlebar/scroll-edge compositing), honoring the memory-logged lesson.

## Human-eyes-only (not attempted; no TCC-triggering commands)

- Live Liquid-Glass frost under the band + Reduce Transparency degrading to an opaque legible band.
- Wheel/trackpad 60 Hz scroll feel (measured main-thread gaps during the workout stayed ≤ 26 ms on
  big2g with scan windows at one ~16 ms tick — consistent with no > 17 ms serving hitch — but
  tactile 60 Hz needs live input).
- VoiceOver / accessibility of the AppKit grid.
- Runtime click/drag confirmation of no-selection / no-resize (code-verified above).

## Cross-model (Claude claude-opus-5) read

Claude raised exactly one item — the untracked-file build concern (folded into F1). Its context was
the tracked `git diff` only (untracked `NativeGrid.swift` excluded by `review.sh`), so it could not
review the substance of the new grid; its "clean checkout does not build" is a context artifact, the
staging point is valid. Independent review above covers the substance.

---

## Measurements

Build: `swift build -c release` (backend rebuilt + stale-link products purged first). Machine:
darwin arm64, macOS 26. Fixture: `/tmp/lsprobe/big2g.csv` = 2.6 GB, 100,000,000 data rows
(`id,ref,tag` → `<i>,r<i>,tag<i mod 1000>`). Marked fixture: the gate's generated 3M-row
`lesssheet-native-grid-fixture-v1.csv` (ZQZmark at 0-based 200000/1400000/2000000/2800000).
Single-machine numbers = order-of-magnitude evidence; all are far from the boundary.

### Landing stall — big2g, RELEASE (LESSSHEET_LANDING_STALL=80000001,25000001, seed query "0000000")
| run | s1 jump | s2 find | s3 jump | s4 find | s5 find | worst | verdict |
|-----|---------|---------|---------|---------|---------|-------|---------|
|  1  |  25     |  18     |  23     |  17     |  17     |  25   | all OK (<100) |
|  2  |  17     |  17     |  18     |  17     |  17     |  18   | all OK |
|  3  |  26     |  17     |  24     |  17     |  25     |  26   | all OK |
(ms, max main-thread gap per landing. Jumps = real far landings via estimate-seek; finds on this
UNMARKED file measure main-thread responsiveness during an ongoing background scan — total=0.)

### Landing stall — 3M MARKED fixture, RELEASE (LESSSHEET_LANDING_STALL=800001,400001; finds resolve)
| run | s1 jump | s2 find | s3 jump | s4 find | s5 find | worst |
|-----|---------|---------|---------|---------|---------|-------|
|  1  |  18     |  17     |  17     |  31     |  47     |  47   |
|  2  |  17     |  23     |  23     |  17     |  46     |  46   |
(ms. s4/s5 are REAL far FIND landings incl. subtle/strong highlight re-render. All < 100 ms.)
Overall worst main-thread gap observed anywhere: **47 ms** vs the 100 ms bound (baseline ~1.3 s).

### Gate stall test (reviewer-run): landingsStallTheMainThreadLessThan100ms → PASS (7.2 s).

### Jump exactness — big2g, RELEASE (LESSSHEET_JUMP=10000000,999999999999,50000000)
- seq0: landed_row_0based=9999999 gutter_1based=10000000  (EXACT)
- seq1: rejected scanned=true viewport_restored_to_firstRow=9999996 exact_total=100000000 exact=true
        (never landed, never clamped)
- seq2: landed_row_0based=49999999 gutter_1based=50000000  (EXACT)
- jump scan heartbeat max_gap 301-312 ms (< 500 ms bound).

### Find-step exactness — 3M marked, RELEASE (LESSSHEET_FIND=ZQZmark LESSSHEET_FIND_STEP_SEQ=1)
- landing n=1 row 200000 / n=2 1400000 / n=3 2000000 / n=4 2800000 (in order); count_final total=4.

### Layout at rest — big2g, RELEASE (LESSSHEET_LOG_LAYOUT=1)
- band     minY=0.0  maxY=54.0
- header   minY=32.0 maxY=54.0
- row1     minY=54.0 maxY=76.0
- scrollview minY=0.0

### Cold start (lesssheet.first_rows_visible_ms), big2g, RELEASE: 185 / 214 / 221 / 231 / 236 ms (< 500).

### Steady-state memory after workout (dump hook OFF), big2g, RELEASE
- phys_footprint = 34.1 MB (peak 34.2 MB) — `vmmap --summary` and `footprint -p` agree. (< 120 MB)
- (ps RSS ≈ 820 MB = resident mmap'd file pages; not the phys_footprint metric.)

### AppKit huge-content-size warning: ABSENT in every big2g/capture stderr log (regression gone).

### Gates
- `apps/macos/.aidev/gate.sh apps/macos` → GATE: PASS, 46/46 tests.
- `.aidev/gate.sh` (root: api/ integrity + backend + frontend chained) → GATE: PASS.

### Captured PNGs inspected (light+dark), /tmp/lswin/png/
big2g_grid_light, big2g_grid_dark, big2g_jump50m_live (widened gutter), big2g_eof_live
(EOF overscroll w/ filler below last row), hl.live (subtle/strong highlights on find.csv).
