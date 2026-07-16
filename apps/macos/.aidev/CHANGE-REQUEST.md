# Contract Change Request — thin-frontend-shared-core Phase 2 / remove the frozen refs that keep `TSVCopyBuilder` alive

Signed:  [x] implementer   [ ] reviewer
(both required; the reviewer's signature also certifies the numbers below were independently re-checked)

## Grounds (tick at least one)
- [x] A. Infeasible within the current contract
- [x] B. Substantial, quantified improvement

## Context
Phase 2 AC5 says: "`TSVCopyBuilder`, the `CopyBuilder` protocol, and its fixture are gone; the
per-cell `ls_cell_copy` selection-copy loop is replaced by the streaming call; the pasteboard
write + notice/cancel lifecycle are unchanged." Round 1 (this build) has already:
- made the CORE frame the TSV: `ls_copy_open` / `ls_copy_next` / `ls_copy_close`
  (`backend/src/root.zig`), a pull-model row-major sweep that reuses `window.cellCopy`'s O(1)
  forward COPY CURSOR (no per-cell re-location) and frames TAB/LF + spreadsheet quoting +
  single-cell-raw + lossless cells + the `LS_COPY_MAX_CELLS` cap — with `cp1`–`cp7` + `cp_perf` +
  `cp_abi` GREEN (142/142 backend tests);
- bridged it: `CoreDocumentSession.openCopy(_:)` opens the job and vends `CoreCopyStream`
  (`ls_copy_next`/`ls_copy_close`, guarded by the same `copyBufferLock`/`isClosed` UAF discipline
  as `copyCell`), with the golden `StreamingCopyBridgeTests` GREEN; and
- re-pointed the frontend: `ViewerModel.copySelection` now drives the streaming `openCopy` job
  (`ViewerModel.streamCopy`) — append each chunk, handle `.stalled` via `startJump`, byte budget,
  cancel-by-stop+close — and the `copyBuilder = TSVCopyBuilder()` property + the per-cell
  `CopyCellFetch`/`build(...)` drive are GONE. No product code path drives `TSVCopyBuilder` anymore.

So `TSVCopyBuilder` (its TSV framing/quoting) and the `CopyBuilding` protocol are now DEAD in the
product — kept alive ONLY by FROZEN references the implementer may not edit. Deleting `TSVCopyBuilder`
(AC5) is the one remaining Phase-2 step and it needs FROZEN-path edits first → this request.

## If A — infeasibility
AC5 cannot be completed under the current frozen contract: removing `struct TSVCopyBuilder` requires
removing references in FROZEN paths (`Sources/Contracts`, `Tests/`), which the PreToolUse guard +
the frozen-conformance gate block for the implementer.

- Attempts (≥2), each with the specific reason it failed under the current signature:
  1. Delete `struct TSVCopyBuilder` (+ its `build`/`buildSingleCell`/`quoted`/`needsQuoting`) from
     `Sources/LessSheetKit/SelectCopyLogic.swift` (an IMPLEMENTATION path). → `swift build`/`swift test`
     fail to compile: `Tests/LessSheetKitTests/SelectCopyTests.swift:78`
     (`let _: any CopyBuilding = TSVCopyBuilder()`), every `TSVCopyBuilder().build(...)` call site in
     `SelectCopyTests.swift` (the copy-builder behavior tests, ~lines 197–349), and
     `Tests/LessSheetKitTests/StreamCopyWallClockTests.swift:95`
     (`await Task.detached { TSVCopyBuilder().build(rect, budget:, fetch:) }.value`) all still
     reference the removed type. Editing any of them to unblock is a FROZEN-path write → blocked by
     the guard/gate. (The `CopyBuilding` protocol in `Sources/Contracts/CopyBuilder.swift:179` also
     then has no conformer, but the compile break is the tests.)
  2. Shrink `TSVCopyBuilder` to a stub instead of deleting it. → still infeasible: the frozen
     `SelectCopyTests` copy suite drives `TSVCopyBuilder().build(...)` and asserts the EXACT TSV
     framing (single-cell raw, TAB/LF, Excel/Numbers quoting with doubled interior quotes, byte
     budget, cell-count cap, frontier stop, lossy flag), so the full framing must stay as long as
     those tests stand — the duplicate cannot be reduced, let alone removed.
- Failing gate / compiler / type-checker output (representative): `error: cannot find 'TSVCopyBuilder'
  in scope` at `SelectCopyTests.swift:78` / `:197` / …; `error: cannot find type 'CopyBuilding' in
  scope` at `SelectCopyTests.swift:78`; and the guard-contracts PreToolUse hook / `gate.sh`
  frozen-diff check refusing any edit to `Sources/Contracts/CopyBuilder.swift`,
  `Tests/LessSheetKitTests/SelectCopyTests.swift`, or `.../StreamCopyWallClockTests.swift`.

## If B — improvement
- Dimension: code-size/complexity (dedup — the feature's whole point) + performance.
- Baseline (current contract): `TSVCopyBuilder` in `SelectCopyLogic.swift` (`build` +
  `buildSingleCell` + `quoted` + `needsQuoting`, ~90 LOC of TSV framing/quoting logic) + the
  `CopyBuilding` protocol + its exercising tests. The per-cell drive it powered
  (`ViewerModel` → `CopyCellFetch` → `ls_cell_copy`) re-located each row from the nearest index
  checkpoint on EVERY cell: a 100k-row × 3-column copy was measured at ~80 s off-main. Every future
  frontend would re-port the fiddly quoting.
- Proposed: delete `TSVCopyBuilder`; the copy streams core-framed TSV via `openCopy` → `ls_copy_*`.
  The one framing now lives once, in the core.
- Magnitude: −~90 LOC of frontend TSV framing + one `Contracts` protocol + the copy-builder test
  suite; removes the last cross-frontend copy duplicate this slice exists to remove; and the ~80 s
  stall drops to an O(rows) cursor sweep.
- Evidence (how measured): the core path is proven equivalent from BOTH sides WITHOUT referencing
  `TSVCopyBuilder`:
  * backend `cp1`–`cp6` (`backend/tests/all_tests.zig`, GREEN) pin the framing against the core
    directly — plain/empty/single-cell-raw/column-sub-window (`cp1`), spreadsheet quoting incl.
    doubled interior quotes + single-cell-raw-bypasses-quoting (`cp2`), lossless past the 4 KiB
    display cap + tiny-buffer chunk concatenation (`cp3`), monotone `rows_done` to `rect.row_count`
    (`cp4`), STALLED-then-jump-resume byte-identity (`cp5`), and the `LS_COPY_MAX_CELLS`
    `budget_capped` cut (`cp6`);
  * backend `cp_perf` (GREEN) pins the sweep at O(rows) advance count (`>= n-1`, `<= 4n+64`),
    interval-invariant — the ~80 s → O(rows) fix;
  * the macOS golden `StreamingCopyBridgeTests` (GREEN) assert the concatenated `openCopy` chunks
    equal literals CAPTURED FROM the current `TSVCopyBuilder` framing over `find.csv` / `copyquote.csv`
    (full rect, single-cell raw, leading-empty-field, column sub-window, quoting, tiny 8-byte chunks).
  The grid consumes the core path (`ViewerModel.copySelection → streamCopy → openCopy`); the
  `copyBuilder` property + per-cell `build`/`fetch` drive are gone. So `TSVCopyBuilder`/`CopyBuilding`
  are dead but for the frozen refs.
- Reviewer's independent check: <reviewer re-runs `bash .aidev/gate.sh` and confirms `cp1`–`cp7` +
  `cp_perf` + `cp_abi` + `StreamingCopyBridgeTests` GREEN, and that no product code references
  `TSVCopyBuilder`/`CopyBuilding`>

## Minimal change (as a diff) — the FROZEN removals the planner executes
1. `Sources/Contracts/CopyBuilder.swift` — remove the `CopyBuilding` protocol + its doc comment (the
   `public protocol CopyBuilding: Sendable { func build(...) -> CopyReport }` block at line 179).
   **RETAIN every sibling type in this file — they are still used (see Cost/blast radius):**
   `CopyCellStatus`, `CopiedCell` (+ `.empty`), `CopyBudget` (+ `.standard`), `CopyOutcome`,
   `CopyReport`. The `CopyCellFetch` typealias is referenced ONLY by `CopyBuilding.build` +
   the `TSVCopyBuilder` tests being removed in (2)/(3); it becomes dead with them, so it MAY be
   dropped too — planner's call (the conservative default is to keep it; nothing else references it).
2. `Tests/LessSheetKitTests/SelectCopyTests.swift` — remove (a) the conformance pin on line 78
   (`let _: any CopyBuilding = TSVCopyBuilder()`) and (b) the copy-builder behavior tests — every
   `TSVCopyBuilder().build(...)` call site (~lines 197–349: the single-cell/TSV-structure/quoting/
   byte-budget/cell-cap/frontier/lossy tests). Their byte-identical framing is re-pinned by the GREEN
   `cp1`–`cp6` + `StreamingCopyBridgeTests` (neither names `TSVCopyBuilder`). **KEEP** the `Selecting`
   (`SelectionModel`) and `ColumnSizing` (`ColumnSizer`) tests + their conformance pins on lines 76–77
   in this same file — those two impls are UNTOUCHED by this phase.
3. `Tests/LessSheetKitTests/StreamCopyWallClockTests.swift` — remove (or re-pin) the whole test: it
   drives `TSVCopyBuilder().build(...)` end-to-end (its `fetch` calls the real `copyCell`/`ls_cell_copy`)
   and asserts the copy finishes under a 5 s ceiling. That intent is now covered by backend `cp_perf`
   (O(rows) advance count, interval-invariant). If the planner wants to keep a FRONTEND wall-clock
   probe, re-pin it against the streaming `openCopy` path (drive `session.openCopy(rect)` → `next`
   instead of `TSVCopyBuilder().build`) rather than the deleted builder — adjudicator's call.

## Cost / blast radius
- After the planner lands (1)–(3), Round 2 (implementer, IMPLEMENTATION path) deletes
  `struct TSVCopyBuilder` (+ `build`/`buildSingleCell`/`quoted`/`needsQuoting`) from
  `Sources/LessSheetKit/SelectCopyLogic.swift`, completing AC5. (Between the planner's frozen change
  and that Round-2 deletion the tree does not compile — `TSVCopyBuilder: CopyBuilding` then names a
  removed protocol — the same expected two-key transient Phase 1 had with `CellMatcher`/`CellMatching`;
  the gate is required GREEN only at the end of Round 2.)
- **RETAIN** (still referenced by live product code / other frozen tests — do NOT drop):
  * `CopiedCell` + `CopyCellStatus` — the return of `DocumentSession.copyCell` (a frozen protocol
    REQUIREMENT), its `CoreDocumentSession` impl over `ls_cell_copy`, and `CellCopyBridgeTests`.
    `copyCell` / `ls_cell_copy` is NOT being removed — the lossless single-cell read stays (the
    streaming copy is built ON its cursor machinery).
  * `CopyBudget` (+ `.standard`) — `ViewerModel` reads `CopyBudget.standard.maxTotalBytes` (the ~64 MiB
    byte budget `streamCopy` enforces); also used by `CellCopyBridgeTests`.
  * `CopyReport` + `CopyOutcome` — PRODUCED by `ViewerModel.streamCopy` and consumed by
    `completeCopy` / `noticeText` (the pasteboard write + honest notice, unchanged).
  * `SelectionRect` (`Sources/Contracts/Selection.swift`) — ubiquitous (selection algebra, `openCopy`
    input, the grid); untouched.
- One deliberate, contract-specified BEHAVIOR delta to note (NOT a byte-identity regression on any
  fixture): the streaming copy reads each cell losslessly to the core's oversized-row SOURCE cap
  (`LS_WINDOW_ROW_SCAN_MAX_BYTES`, exactly as `ls_cell_copy`), whereas the old builder capped each
  cell's OUTPUT at `CopyBudget.perCellMaxBytes` (~1 MiB) and set `lossyCells`. So `streamCopy` reports
  `lossyCells: false` (there is no per-cell display-cap truncation on this path) and a pathological
  >~1 MiB-output cell is copied MORE completely, not less. No copy fixture has such a cell, so every
  pinned byte-identity holds; the header (`ls_copy_next` "read LOSSLESSLY … WITHOUT the display cap")
  specifies exactly this.
- Changes EXTERNAL I/O?   [x] no    [ ] yes → this goes to the ARCHITECT, not the planner.
