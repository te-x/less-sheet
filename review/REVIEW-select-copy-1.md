# REVIEW — select-copy (full build, round 1)

Reviewer: independent, adversarial, by measurement; loyal to the frozen contracts + ARCH-select-copy.
Did not edit code.

> Orchestrator note: verdict FAIL on one blocking `[impl]` correctness bug (finding 1). Round 2 fixes it
> + the cancel/frontier items; the copy-perf accessor is a tracked follow-up (task #12). I re-ran
> `bash .aidev/gate.sh` (PASS) — but the gate is NOT sufficient here: the blocking bug is App-target
> coordinate mapping the frozen tests can't reach.

## Gate + integrity
- `bash .aidev/gate.sh` → PASS. Backend `zig build` + `zig build test` green (zig 0.16.0); csvgen selftest
  142/142. macOS `swift build` + `swift test` → 93 tests / 6 suites passed (incl. select-copy pure +
  cell-copy-bridge + native-grid probes). Root chained PASS.
- Frozen-path diff empty (`api backend/contracts backend/tests apps/macos/Sources/Contracts apps/macos/Tests
  apps/macos/Package.swift`). Only impl files differ.

## Verified cruxes
- **Backend `decodeColumn`** provably mirrors the frozen `lexer` field state machine (quote open / doubled-
  quote collapse / closing quote / trailing junk / sep-CR-LF structural stop / `utf8TrimToBoundary`), with
  one correct improvement: `was_truncated = cap_truncated or (hit_limit and artificial)` distinguishes the
  1 MiB scan cap (truncation) from genuine EOF (not). cc1–cc5 + the ABI pin genuine. Oversized-row safe
  (bestCheckpoint lands past the post-oversized checkpoint; the skip loop only crosses ≤1 MiB rows).
- **Concurrency: no race.** `copyCell` holds `copyBufferLock` across the call and materializes the String
  under the lock; the identity path takes the doc mutex only for the checkpoint snapshot then decodes
  lock-free over immutable `content` (window-independent, never touches `win_*`).

## Findings
1. **`[impl]` BLOCKING — header whole-column select → wrong column when horizontally scrolled.**
   `GridHeaderView.mouseDown` (NativeGrid.swift:1362) computes `point` in the header's DESCROLLED space
   (header draws at `columnFirstX − contentOffsetX`; `resizeIndex`/`resetCursorRects` descroll correctly),
   but the non-resize branch passes `point.x` to `headerMouseDown` → `windowColumnIndex(atX:)` (:875), whose
   cursor starts at ABSOLUTE `columnFirstX` (= `model.columnWindow.firstX` ≈ `contentOffsetX`). Descrolled x
   vs absolute accumulator → once scrolled past ~one column, every header click resolves to the first
   window column; shift-click whole-column extend inherits it. Correct only at `contentOffsetX == 0`
   (narrow/viewport-fitting docs) — why casual testing misses it, and reachable on the headline 100k-col
   scrolled case. Gutter (:1448, re-bases via `table.convert` → absolute) + data-cell (`cellAt`, absolute)
   paths are correct; header is the lone outlier. Uncaught: SelectCopyTests pin only the pure model; App
   coordinate mapping isn't importable by tests. FIX (frontend, within contract): pass absolute x
   (`point.x + contentOffsetX`) to `headerMouseDown`, or accumulate descrolled like `resizeIndex`; add a
   probe that scrolls right, clicks a header, asserts the column.
2. **`[impl]`+`[contract]` follow-up — copy time is O(cells × checkpoint_interval); the ~64 MiB byte budget
   does NOT bound copy TIME for small cells.** Measured (C bench on the built lib, row-major, frontier
   advanced): 2000×3 → 2.40 s; 10000×3 → 13.16 s; **100000×3 → 140.7 s** (~2130 cells/s, ~constant vs file
   size → confirmed O(cells × ~2048-checkpoint skip)). A 64 MiB / 10M-cell budget-filling small-cell copy ≈
   **75–85 min**. Off-thread (UI verified responsive), bounded, correct, noticed — but **no cancel**
   (`copySelection` guards `copyInFlight`, never stores/cancels the `Task.detached`). Recommendation: SHIP +
   tracked follow-up (all 7 ACs technically met; ARCH anticipated ≤10M cells off-thread w/ a progress
   affordance). Fold in cheap mitigations now: (a) `[impl]` tighten the (non-frozen) `CopyBudget`
   maxCells/add maxRows so worst-case ≈ a few seconds, + make the copy cancellable; (b) `[contract]` the
   real fix (reviewer co-signs the 2nd key): a streaming/range copy accessor across the ABI —
   `ls_copy_open(doc,first_row,first_col,col_count)→cur` + `ls_copy_next(cur,buf,…,out_row_end)` reusing the
   row offset across cells + advancing row→row via `res.next` (O(1) amortized), OR a batch
   `ls_row_copy(doc,row,first_col,col_count,…)`. Not solvable within the stateless per-cell `ls_cell_copy`;
   routing copy through `ls_window_set` correctly rejected (would thrash the UI's live window).
3. **`[impl]` minor — `copySelection` doesn't pre-advance the frontier** before the detached build
   (CopyBuilder.swift:171-175 expects a jump-to-bottom first), so a selection whose bottom is past the
   frontier under-copies + reports `.stoppedAtFrontier` until AUTO catches up. Honest + self-healing; low
   priority — a jump-to-bottom before the build satisfies the intent.
4. **Low (non-blocking):** no cc/bridge test exercises a QUOTED cell through `ls_cell_copy` (verified by
   equivalence to the lexer; a CSV→copy→re-quote round-trip would harden it); `decodeColumn` duplicates the
   lexer state machine (justified by the zero-alloc ABI; add a cross-link comment); filtered copy holds the
   doc mutex for the whole per-cell call (more contention under a filtered copy; acceptable, mirrors
   `windowSetFiltered`).

## Verdict: FAIL (finding 1). Round 2: fix finding 1 (+ regression probe), finding 3, and finding-2 cancel
+ a stopgap cap; the streaming accessor is a follow-up CHANGE-REQUEST (task #12, 2nd key co-signed).
