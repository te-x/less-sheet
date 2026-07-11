# ARCH — stream-copy (O(rows) rectangular copy + never-look-frozen progress)

**Feature:** two coupled responsiveness wins for the dogfood milestone.
1. Make a big rectangular copy **O(rows)** instead of **O(cells × checkpoint-interval)** — a pure backend
   change *behind the existing `ls_cell_copy` ABI* (no `api/` change, byte-for-byte the same clipboard
   output). Built on the Reader interface (`af83db9`): a forward `(row, Pos)` **copy cursor** the core
   reuses across consecutive `ls_cell_copy` calls, so a row-major sweep advances O(1) per step instead of
   re-locating every cell from a sparse checkpoint.
2. **Never look blocked:** any operation that runs longer than ~500 ms shows a **subtle progress
   indicator** (so the user knows we're working, not frozen). Delivered as ONE reusable frontend
   affordance, wired to COPY here (the operation that can still be long even after win #1), and consumed
   by the other existing long operations (index / jump-scan / filter-scan) where that is just wiring.

**Read first:** `docs/architecture/PROJECT.md` (esp. the < 500 ms cold-start / O(viewport) budget);
the copy path today — `backend/src/window.zig` (`cellCopy` / `cellCopyFiltered` / `decodeCellAt`),
`backend/src/reader.zig` (the `boundsAfter` / `cell` ops + opaque `Pos`), `backend/src/nav.zig`
(`bestCheckpoint`, `nthMatchLocation`), `api/lesssheet.h` (`ls_cell_copy` / `ls_copy_result`, the
FULL-CELL READ + THREADING sections); the frontend — `apps/macos/Sources/Contracts/CopyBuilder.swift`
(`TSVCopyBuilder`, frozen), `SelectCopyLogic.swift`, `CoreDocumentSession.copyCell`, and the existing
progress surfaces (`ViewerModel` jump/filter progress, the filter-scan banner %).

## Problem
**Copy cost.** `window.cellCopy(row, col, …)` locates the row **from scratch every call**: it takes
`d.lock()`, reads `nav.bestCheckpoint(row)`, then runs a `boundsAfter` skip loop from that checkpoint up
to `row` (`window.zig:355`). Checkpoints are sparse (~one per ~2048 rows), so each cell costs up to ~2048
`boundsAfter` steps. A rectangular copy reads cells **row-major**, so within one row `W` columns re-locate
the *same* row `W` times, and each next row re-skips from the nearest checkpoint again. Net ≈ **O(cells ×
checkpoint-interval)** ≈ 2000 cells/s → a 100k-row selection ≈ 140 s (today off-main-thread + cancellable
as a stopgap). The filtered path (`cellCopyFiltered` → `nav.nthMatchLocation`) is worse: O(checkpoints +
in-block re-lex) **per cell**. The redundancy is pure: a row-major sweep only moves **forward**, and a
Reader `Pos` is **stable** once scanned (the frontier is append-only) — so one forward cursor collapses
"locate row R+1" to a single `boundsAfter` and "another column of row R" to zero locates.

**Responsiveness.** Even at O(rows), a truly large copy (millions of rows, or the ~64 MiB budget) can
exceed ~500 ms; today it shows only a text "Copying…" notice, no progress. More broadly, the app must
never present a frozen/blank UI for a slow operation — it should always show at least a subtle sign of
work in progress.

## Scope
- **In:**
  - An internal, forward, view-scoped **copy cursor** in the core that accelerates *consecutive,
    monotonically-non-decreasing* `ls_cell_copy` calls — exactly the pattern `TSVCopyBuilder` produces —
    for BOTH the identity view (`cellCopy`) and the active-filter view (`cellCopyFiltered`). Byte-for-byte
    identical results, status codes, bounds/caps/flags.
  - A **reusable "subtle progress after ~500 ms" affordance** (frontend), wired to COPY (determinate —
    fraction of the selection swept — with the existing cancel), and **consumed by the existing long ops
    (background index, jump-scan, filter-scan)** where that is only wiring to their existing progress
    signals. An **audit note** records every long operation's status.
- **Non-goals:**
  - **No `api/` change.** `ls_cell_copy`'s signature, `ls_copy_result` values, every frozen symbol
    untouched. No new backend/copy ABI (the "new cursor ABI" and "core-serializes-range" options were
    rejected). No new *progress* ABI — the affordance consumes signals that already exist (copy's own
    row-major position; the index/jump/filter polls).
  - **No copy-contract change.** `TSVCopyBuilder` / `CopyBudget` / `copyCell` and their frozen tests are
    unchanged: the ~64 MiB byte budget, 10M-cell safety, row-major order, TSV/Excel quoting,
    single-cell-raw, frontier-stop, and lossy flag all stay in Swift. The frontend change is **additive**
    (a progress affordance + wiring), not a rework.
  - Not a general window/index/nav optimization — only the copy path. `windowSet` is out of scope.
  - Does not change WHAT is copyable (frontier-`PENDING`, `NO_CELL`, oversized-row bounding, bounded
    record-1, ragged padding, display-cap-vs-full-cell all behave as today).
  - Operations whose 500 ms-progress needs MORE than wiring (e.g. a backend that reports no progress yet)
    are **enumerated as fast-follows**, not built/gated here.
  - **Progress accuracy is a non-goal.** The indicator only conveys "working through a lot of data" — that
    the delay is data volume, not a stuck UI/backend — NOT a precise percentage. A coarse or indeterminate
    indicator is acceptable; do not invest effort in an accurate fraction.

## Inputs / Outputs
- **Copy interface unchanged:** `ls_cell_copy(doc, row, col, buf, buf_len, out_len, out_truncated) →
  ls_copy_result`. Inputs, outputs, and the three result codes keep their exact current meaning.
- **Output invariant (the crux):** for any document, view (identity/filtered), and `(row, col)`, the
  triple `(result, out_len, out_truncated[, buf bytes])` returned via the cursor path is **identical** to
  the current locate-from-scratch value. The cursor changes only *how fast* a row is located.
- **Access pattern optimized:** calls whose `row` is equal to, or forward of, the cursor's last row in
  the same view. Non-monotonic (backwards / far-jump / different view) is still correct — it re-anchors
  (Functional req. 4).
- **Progress output:** a UI-only indicator (no clipboard/data effect) that signals "working through a lot
  of data." Coarse or indeterminate is fine — accuracy is a non-goal. Purely additive.

## Functional requirements
1. **Forward cursor, identity view.** The core keeps a view-scoped copy cursor `{ row, pos }`. On a
   locatable `cellCopy(row, col)`, if the cursor is valid and `cursor.row ≤ row`, advance from
   `cursor.pos` by `boundsAfter` exactly `row − cursor.row` times (0 for another column of the same row),
   decode column `col`, update the cursor. Result identical to today.
2. **Forward cursor, filtered view.** `cellCopyFiltered(row, col)` uses a filtered cursor
   `{ filtered_row, pos, match-walk state }` that resumes the per-block-count / `nthMatchLocation` walk
   forward from the last filtered row instead of re-walking from the start, decodes column `col`, updates
   the cursor. Result identical to today.
3. **Cold / re-anchor.** When the cursor is absent, invalid, `row < cursor.row`, or the forward gap is
   implausibly large vs a checkpoint seek, fall back to today's locate-from-scratch and then set the
   cursor. Guarantee: **never slower than today** for any access pattern.
4. **Invalidation.** The cursor is tagged with the view identity (identity vs filtered) and filter
   generation; dropped/ignored on filter set/clear or re-open. Positions themselves never need
   invalidation (stable once scanned).
5. **Special cases preserved exactly.** Bounded record-1 row 0 still served from `data_start` bypassing
   the cursor; frontier-`PENDING` / exact-past-`NO_CELL` still decided before any cursor use; oversized-row
   bounding and the "never cross an oversized row's bytes" guarantee unchanged.
6. **Copy progress.** If a copy is still running after a ~500 ms threshold, a **subtle** progress
   indicator appears (within ~500 ms of start), carrying the existing cancel (Task/Esc/Cancel), and
   disappears on completion or cancel. Its only job is to say "working through a lot of data, not stuck" —
   coarse or indeterminate is fine; the copy driver need not compute a precise fraction (accuracy is a
   non-goal). A copy that finishes under the threshold shows nothing (no flicker). Threshold + show/hide
   logic is pure and hermetically testable (no real wall-clock in the logic itself).
7. **Reusable affordance + audit.** The 500 ms indicator is one reusable component (subtle, non-blocking,
   negligible overhead, respects Reduce Motion). The existing long operations (background index,
   jump-scan, filter-scan) surface a consistent subtle progress when they exceed ~500 ms — newly wired to
   the affordance, or confirmed already-compliant via their existing progress surface. An audit note lists
   each long operation with its status (already-compliant / wired-here / fast-follow).

## Non-functional constraints
- **Performance (the point):** a full row-major sweep of an `N`-row × `W`-col selection performs **O(N)**
  source row-advances (≈ `N` forward `boundsAfter` + at most one anchor per genuine re-anchor),
  **independent of the checkpoint interval** — not `O(N × interval)`. Decoding stays O(cells read).
  Filtered sweep: **O(matches)** advances. Cursor state is O(1) memory.
- **No regression:** cold-open, window, landing, memory (O(head)/O(checkpoints)) untouched; this path
  never scans, never advances the frontier, no identity-path alloc (filtered path keeps its single shared
  `nav_scratch`).
- **Thread-safety:** `ls_cell_copy` stays safe off the main thread and concurrently with other accessors.
  The cursor is `Document` state mutated only under `d.lock()`; concurrent callers serialize (benign — one
  copy sweep is the real workload). Still never touches/evicts the window (cc4 no-borrow holds), never
  advances the frontier.
- **Responsiveness:** any operation exceeding ~500 ms shows the subtle indicator within ~500 ms of start;
  it never blocks input and adds negligible overhead; the copy indicator is cancellable and conveys
  "a lot of data" (coarse/indeterminate is fine — accuracy is not a goal). Sub-500 ms operations stay
  chrome-free.

## Component decomposition & data flow
- **Backend (changed):** `window.zig` — `cellCopy`/`cellCopyFiltered` gain the cursor fast-path + re-anchor
  fallback (`decodeCellAt` unchanged). `base.zig` — `Document` gains the cursor field(s) + reset on
  open/filter-change. `nav.zig` — possibly a small resume-from entry for the filtered match walk. Reader /
  source / csv_reader / `root.zig` ABI / `api/` / `build.zig`: unchanged.
- **Frontend (changed, additive):** a reusable subtle-progress-after-500 ms component; `SelectCopyLogic` /
  the copy driver signal "still working" (a coarse position is enough — no precise fraction) and drive the
  threshold; `ViewerModel` / `NativeGrid` present
  it and wire index/jump/filter onto it (consuming existing progress). The end-to-end copy **wall-clock
  probe** lives in the macOS test suite (it links the real core, so it stays red until the backend cursor
  lands — expected in a backend∥frontend cell, not chased).
- **Data flow (copy):** `TSVCopyBuilder.build` → row-major `fetch(row,col)` → `copyCell` → `ls_cell_copy`
  → `window.cellCopy` (**now cursor-accelerated**) → `Reader.cell`; the driver emits progress alongside,
  the affordance shows it past 500 ms.

## External interfaces
None new. The cursor consumes existing internal Reader/nav ops; the progress affordance consumes existing
progress signals (copy sweep position; index/jump/filter polls). The C ABI stays byte-compatible.

## Acceptance criteria (testable)
1. **Byte-identical output (identity).** Across the CSV corpus and a spread of rects — single cell, within
   one window, spanning ≥2 checkpoints, an oversized row, bounded record-1 row 0, ragged/short rows,
   first/last row, `col` past the row's fields — a row-major cursor sweep returns, per cell, the SAME
   `(ls_copy_result, out_len, out_truncated, buf bytes)` as a reference locate-from-scratch (cursor
   disabled). No divergence.
2. **Byte-identical output (filtered).** Same equivalence for `cellCopyFiltered` under active text/where
   filters (incl. zero-match and all-match) vs today's per-cell `nthMatchLocation` path.
3. **O(rows) locate cost (identity), interval-invariant.** With an instrumented count of source
   row-advances (the `copyAdvances` seam), a row-major copy of an `N`×`W` selection performs a LINEAR
   count (`≈ N-1`, ceiling `≤ N+64`) with **no interval term** — proving it is NOT `O(N × interval)` —
   contrasted against the cursor-OFF baseline (`≥ 100·N`). Proven by this absolute linear bound vs the
   interval-costly baseline, NOT a runtime interval knob (a per-doc interval divisor would regress the
   shared index/search/filter hot loops — outside this feature's blast radius). Extra columns within a row
   add **zero** advances.
4. **O(matches) locate cost (filtered), interval-invariant.** The analogous `copyAdvances` count for a
   filtered sweep is linear in filtered rows read (no interval term), vs the interval-costly cursor-OFF
   baseline.
5. **Never-slower.** Non-monotonic/backwards/cross-view access re-anchors correctly; its instrumented
   count matches the from-scratch baseline and never exceeds it.
6. **No behavior/ABI/perf regression elsewhere.** All existing frozen backend + macOS + root tests stay
   green byte-for-byte (incl. cc1–cc5, the cc4 no-borrow/thread test, window/landing/cold-open probes). No
   `api/`, contract, or frozen-test edit. Gates green (backend + macOS + root).
7. **Copy wall-clock ceiling (GATING) + ship.** End-to-end through the real `TSVCopyBuilder` +
   `copyCell` + `ls_cell_copy` in the macOS suite, a **100k-row × ~10-col** full-selection copy completes
   **under 5 s** on the dev box (deliberately generous vs the expected sub-second-to-low-seconds — ~28×
   headroom over the ~140 s today — so machine load can't false-fail; the planner may tighten). This gates
   alongside AC3's interval-invariant count. On green, the assembled `.app` is reassembled so select-copy
   finally **SHIPS**.
8. **Copy progress ≥ 500 ms.** A copy running past ~500 ms shows a subtle progress indicator appearing
   within ~500 ms, with cancel, gone on completion/cancel; a sub-threshold copy shows nothing. The
   indicator conveys ongoing work on a large dataset — coarse/indeterminate is acceptable; **accuracy is
   explicitly NOT gated**. The threshold + show/hide logic is unit-tested hermetically (injected
   clock/progress — no real wall-clock in the logic test).
9. **Reusable affordance + audited coverage.** The indicator is one reusable, Reduce-Motion-respecting
   component with a unit-tested 500 ms threshold. Copy uses it (AC8). An audit note enumerates every
   long-running operation (index, jump-scan, filter-scan, open) with its status — already-compliant,
   wired-here, or listed fast-follow — and jump + filter are confirmed to surface progress within ~500 ms.
   No covered operation over ~500 ms presents a frozen/blank UI.

## Isolation note (for the parallel fan-out)
Backend edits are confined to `window.zig` + `base.zig` (+ maybe a small `nav.zig` helper); frontend edits
are macOS-only (progress affordance + wiring). Both are **disjoint from the sibling csv.gz feature**
(backend-only: `source.zig` + `root.zig`'s open path). So stream-copy and csv.gz remain aidev §5 **parallel
build cells on one tree** — no git worktrees/merge. *Within* stream-copy, the backend cursor cell and the
frontend progress cell are the usual backend∥frontend split (the macOS wall-clock probe links the real
core → red until the cursor lands; listed, not chased). If the build surfaces an unforeseen shared write
to `root.zig`/`base.zig` between the two features, fall back to worktree isolation.

## Open Questions
None.
