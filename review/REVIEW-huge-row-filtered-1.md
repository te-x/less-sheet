# REVIEW — huge-row-filtered (finding-1, round 1)

Reviewer: independent; loyalty to the frozen contract (`api/lesssheet.h`) + `ARCH-huge-row-filtered.md`
acceptance, verified by measurement. Adversarial. Did not edit code.

> Orchestrator note: this file is the reviewer subagent's verdict verbatim. Per the build-cell rule I
> re-ran `bash .aidev/gate.sh` from the orchestrator context myself (never take the cell's word) — see
> the `aidev: build huge-row-filtered` commit for that independent confirmation.

## Overall verdict: PASS

All 6 ARCH acceptance criteria are genuinely met. The two correctness cruxes (#1 full-cell matching, #2
the second `nthMatchInBlock` caller) hold under adversarial attack, and criterion 1 (O(budget), not
O(giant bytes)) is verified BY MEASUREMENT with a large fixture — not just the ~1.1 MiB frozen fixtures.
Findings are NON-BLOCKING (test-coverage strengthening + a pre-existing, out-of-scope responsiveness
residual for a follow-up).

## Gate results (verbatim)
- `bash backend/.aidev/gate.sh backend`:
```
GATE: conformance -> [ "$(zig version)" = "0.16.0" ] || { echo "zig 0.16.0 required, found $(zig version)"; false; } && zig build
GATE: behavior -> zig build test
GATE: PASS
```
`zig build test --summary all` → `Build Summary: 3/3 steps succeeded; 116/116 tests passed` (incl. frozen
`hrf1`/`hrf2`/`hrf3` and identity `hr3`/`hr4`/`hr5`/`hr6`). `zig version` = `0.16.0`.
- `bash apps/macos/.aidev/gate.sh apps/macos` → `Test run with 67 tests in 1 suite passed` … `GATE: PASS`.
- `bash .aidev/gate.sh` → `GATE: PASS` (api/ integrity + both components chained).
- Frozen-path check (`git diff --name-only 42f04c3 -- api backend/contracts backend/tests apps/macos/Sources/Contracts apps/macos/Tests apps/macos/Package.swift`) → **empty**. Only `backend/src/{base,filter,nav,root,window}.zig` changed.

## Crux #1 — full-cell matching (hrf2): PASS
The match for a giant row is decided **exactly once, full-cell**, in `filter.filterScanChunk`
(`lexInto(… null, content.len …)` then `matcher.matchRecord`, filter.zig:129-137) and recorded via
`stageOversizedMatch` (gated on source extent > cap). Both foreground consumers —
`window.windowSetFiltered` (window.zig:187) and `nav.nthMatchInBlock` (nav.zig:219) — consult ONLY
`filter_oversized_matches` for a capped row; **no path re-decides on the prefix or re-lexes to the tail.**

Adversarial cases I ran (self-built ReleaseFast lib + a C-ABI driver, both giant sizes):
- **Giant row matching only in its TAIL** (col0 = huge `X` filler, col1 = `needle` past the 1 MiB cap):
  served at its filtered index, `ls_row_oversized`=true, col0 truncated to 4096, **col1 = "" (tail never
  re-scanned)** — the row is present exactly as the background full-cell scan decided.
- **Giant row NOT matching** (col1 = `plain`), crossed between two matches: **correctly EXCLUDED** from
  the filtered view and skipped without re-scan. (This exercises the `capped && !matched` branch that the
  frozen `hrf*` tests never hit — all three have the giant row matching.)

## Crux #2 — `nthMatchInBlock`'s second caller: PASS (broke nothing)
`nthMatchInBlock` consults `filter_oversized_matches` **unconditionally on any capped row, without
checking `ctx`** — so safety rests entirely on it only ever receiving the active filter's predicate. I
proved that by exhaustive call-graph, not by taking the implementer's word:
- `nthMatchInBlock` has **exactly one** caller: `nthMatchLocation` (nav.zig:252).
- `nthMatchLocation` has **exactly three** callers: `window.windowSetFiltered` (window.zig:165),
  `search.resolveNavLockedFiltered` (search.zig:291 and :307). **All three pass `filter.filterCtx(doc)` +
  `filter_block_counts`** — the pure FILTER predicate over the filter's own counted region. `filterCtx`
  (filter.zig:23) returns the filter predicate alone, never a composed find+filter ctx.
- In `resolveNavLockedFiltered`, the find composition is done **separately** by
  `findForwardMatch`/`findBackwardMatch` over `doc.block_counts` with `pctx` (search.zig:293/318) — those
  route through `relexBlock`, **not** `nthMatchInBlock`, and never touch `filter_oversized_matches`. So the
  filtered anchor→row LOCATE (filter-only) and the find scan (combined) are cleanly separated; the record
  is consulted only under the filter predicate at both sites. The subtle "find-nav reads the filter's
  oversized record" bug does not exist.

## Crux #3 — unconditional drain vs advancing-gated checkpoints: PASS
The asymmetry is correct. `oversized_checkpoints` is **shared** across scanners (index `scanChunk`,
`headScan`, search scan, filter scan all advance the one frontier and can re-walk each other's ground), so
its drain must be `advancing`-gated. `filter_oversized_matches` is **filter-exclusive**:
`drainOversizedMatches` is called only from `commitFilter`, and the filter scan runs off its **own private
cursor** (`filter_offset`/`filter_rows`), advanced only in `commitFilter` and reset only by `setFilter`.
Interleaving I traced:
- **No duplicates / no reorder:** all three drivers call `filterScanChunk(doc, doc.filter_offset,
  doc.filter_rows)` (index.zig:112/147, filter.zig:393); `commitFilter` advances the cursor forward to
  `res.end_row` (filter.zig:181). Within one generation the cursor is strictly monotonic and contiguous →
  a chunk can never re-stage an already-recorded row. Cross-chunk staging is therefore strictly
  row-ascending → the `oversizedMatch` binary search is valid. The only "re-scan" is across a `setFilter`
  generation, which clears the list first.
- **Reset per generation:** `setFilter` clears `filter_oversized_matches` and resets
  `filter_offset`/`filter_rows`/`filter_block_counts` and bumps `filter_gen` (filter.zig:345,366-371). A
  gen-mismatched chunk skips `commitFilter` entirely (no drain, cursor not advanced; index.zig:115/150),
  and the next `filterScanChunk` clears the lock-free stage first (filter.zig:120) → no stale leak.
- **Complete + consistent:** every oversized row crossed is staged in both the lex-success and lex-error
  paths (filter.zig:132,137) and drained in the same locked `commitFilter` that advances `filter_rows`
  past it. Window/nav reads hold the same mutex, so they see cursor-advance and record-drain atomically —
  every row `< filter_rows` (the loop/`hi_bound` bound) has a record, and its `matched` bit comes from the
  same full-cell decision that `filter_block_counts` counted, keeping the in-block walk's `seen` in
  lockstep with the block counter.

## Criterion 1 (responsiveness) — verified BY MEASUREMENT
The frozen `hrf*` fixtures are ~1.1 MiB, so they cannot distinguish a bounded skip from re-lexing the
giant row. Criterion 1 hinges on the post-oversized checkpoint landing at row+1 so the skip loop's
`recordBounds` never walks the giant row. I measured a C-ABI driver (ReleaseFast) that crosses **two**
giant rows (one non-match, one tail-match) in one filtered `ls_window_set`, at growing giant-row sizes:

| giant-row size | background filter-scan (off-lane) | `ls_window_set` (UI lane) |
|---|---|---|
| 2 MiB    | 38.5 ms   | 11.4–14.6 ms |
| 128 MiB  | 1817 ms   | 12.2 ms |
| 256 MiB  | 3540 ms   | 11.6 ms |

The synchronous window materialize is **flat (~12 ms) across a 128× span** while the background scan scales
with file size — conclusively O(budget), not O(giant bytes), well under the 100 ms UI budget. (The ~12 ms
is the bounded budget: the ≤1 MiB in-cap re-lex of the served oversized row's display prefix + first-window
allocation.) Correctness held identically at all sizes: filtered 0→src 0 (whole), filtered 1→src 2 (giant
tail-match, oversized, col1=""), filtered 2→src 3 (whole); giant non-match src 1 excluded. Run under AUTO
index mode, so the index and filter scans both advance the shared frontier — additionally stressing the
`oversized_checkpoints` sharing / finding-2 guard.

## Item 4 — memory, leaks, identity path, findings 2+3, nav residual
- **Memory O(oversized rows):** `filter_oversized_stage`/`filter_oversized_matches` grow only per row
  whose extent > cap (`stageOversizedMatch` size test). Never O(rows)/O(matches). Both deinit'd in
  `freeDoc` (base.zig:323-324); 116/116 pass under `std.testing.allocator` → leak-free.
- **Identity huge-row path unchanged:** `hr3`/`hr4`/`hr5`/`hr6` green. The
  `bestCheckpoint`/`checkpointAtOrBefore`/`findCheckpoint` move from window.zig to nav.zig is verbatim
  (logic-preserving); `windowSet` now calls `nav.bestCheckpoint` at the same two sites.
- **Finding 2 applied correctly:** `drainOversized` now appends a staged checkpoint only if `.row`
  strictly exceeds the last entry's — keeps `oversized_checkpoints` strictly ascending by construction,
  drops only redundant re-walked rows (a forward scan's new oversized row always has a greater row), robust
  to a hypothetical second mid-block overlap. **Finding 3:** the O(oversized rows) doc comment is updated.
- **Nav residual genuinely out of scope:** `relexBlock` (nav.zig:61) and `countInBlockUpTo` (nav.zig:117)
  still lex `cap=null, content.len` — unchanged by this diff. `hrf3` proves find-within-filter /
  jump-under-filter / count / mapping stay CORRECT across a giant row (not responsiveness). See finding 2.

## Findings (all NON-BLOCKING)
1. **`[impl]` — frozen `hrf*` tests never exercise a giant NON-matching row crossed in a filtered window**
   (the `capped && !matched` branch in `windowSetFiltered` window.zig:184-207 and `nthMatchInBlock`
   nav.zig:215-230). All three `hrf` fixtures have the giant row matching. I verified this path correct by
   measurement (giant non-match excluded, skipped O(budget)), so this is a test-strengthening note for the
   planner (frozen, planner-owned), not a code gap.
2. **`[impl]` — nav residual: find-within-filter / `positionOf` still re-lex a giant row full-cell**
   (`relexBlock`/`countInBlockUpTo`, `cap=null`), reachable on the foreground `ls_search_nav` lane
   (search.zig:450). Pre-existing, unchanged, outside this ARCH's `windowSetFiltered` scope; `hrf3` guards
   correctness. Recommend a follow-up slice to bound these the same way (checkpoint-skip + a combined-match
   record), OR a contract note qualifying nav-under-filter responsiveness for giant rows. Solvable in code
   within the contract → `[impl]`.
3. **`[impl]` — minor: `windowSetFiltered` double-lexes a served oversized row** (bounded test lex then
   bounded serve lex, ~2× the 1 MiB cap of foreground work). Bounded and correct; the pre-existing
   test-then-serve shape. Optional micro-optimization (reuse the test lex when serving). Negligible.

No `[contract]` findings: no public-surface drift (`api/` untouched, per ARCH's default), and every issue
is solvable in code within the frozen contract.
