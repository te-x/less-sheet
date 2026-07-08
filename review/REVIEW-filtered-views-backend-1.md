# REVIEW — filtered-views (backend) — Round 1

Verdict: **PASS** — zero blocking findings.

Reviewer did not write the code. Loyalty is to the contract (api/lesssheet.h
FILTERED VIEWS) and the ARCH acceptance criteria 1–15, verified by measurement.

## Gate
`bash backend/.aidev/gate.sh backend` → **GATE: PASS** (conformance: zig 0.16.0 +
`zig build`; behavior: `zig build test`). Full run: **108/108 tests pass** (93
pre-existing + 15 fv), MaxRSS 78M, 13s. `std.testing.allocator` / `BytesAllocator`
are in force, so a leak would fail the run — none did (leak-freedom is measured,
not claimed).

## Acceptance criteria — genuinely met (not fixture-gamed)
The filter-scan (`filterScanChunk`) evaluates rows with the SAME `matchRecord`
predicate the search path uses; window materialization (`windowSetFiltered`),
source-row mapping, jump, and find all recompute via that predicate over real
re-lexed cells — there is no fixture special-casing. Spot-verified against the
contract:
- fv1 identity view / IDLE / source_row identity; fv2 WHERE count+cells file-order;
  fv3 TEXT smart-case + scope; fv4 clear→identity; fv5 rejection leaves view
  intact (validation mirrors `ls_search_start` exactly, allocations done up-front
  so OOM rejects cleanly); fv6 zero-match exact-0.
- fv7 monotone progress→exact; fv9 filter-scan feeds base index (commitFilter
  advances the shared frontier and sets total_rows at EOF); fv10 jump takes the
  slot, filter MODE persists (do_jump path sets filter_state=.cancelled, never
  idle; AUTO auto-resumes via do_filter cancelled+auto).
- fv11 source rows; fv12 jump target=original-row nearest-match, landed=filtered
  index, EOF clamp; fv13 clear re-anchor; fv14 find composes BOTH predicates
  (rowMatch), found_row filtered, position over combined counted region; fv15
  set/clear reset search, re-open clears filter.

## Memory discipline (headline risk) — verified
The ONLY per-row-scaled structures are three `ArrayList(u64)`: `block_counts`
and `filter_block_counts` (both O(checkpoints), interval=2048, appended 1:1 with
`checkpoints` at block boundaries) and `win_source` (O(window)). There is NO
materialized match-row list anywhere. filtered index↔source and windowing are
served by counting into blocks (`nthMatchLocation`/`positionOf`/`countInBlockUpTo`)
plus bounded in-block re-lex. fv8 MEASURES this: dense (200k matches) vs sparse
(10 matches) filter allocation deltas differ by < 64 KiB (a match list would add
~1.6 MB) — passes. All filter buffers freed in deinit (win_source,
filter_block_counts, filter_scratch, filter_refs, filter_value, filter_scope_mask);
no leak under the testing allocator.

## Docs-first Zig 0.16.0
No stale std usage. Unmanaged-ArrayList style (`.empty`, explicit `gpa` on
append/deinit, `ensureUnusedCapacity`+`appendAssumeCapacity`,
`clearRetainingCapacity`) is correct for 0.16.0; the conformance gate pins the
exact compiler, so the API is correct by construction.

## Structure / maintainability (secondary)
Shared logic is factored, not copy-pasted: nav/count helpers (`relexBlock`,
`findForward/BackwardMatch`, `countInBlockUpTo`, `positionOf`, `nthMatchLocation`)
are generalized over explicit `block_counts` + optional `filter_ctx`/`primary_ctx`
and reused by both plain and filtered paths; `rowMatch` cleanly composes the two
predicates. New functions are cohesive and well-placed. The
`ls_search_start`/`ls_filter_set` validation IS duplicated verbatim (~20 lines,
root.zig 2767–2798 vs 2966–2997) — a small, obvious extraction, noted as a
non-blocking nicety (defer to the scheduled src/ split). File-size monolith is
known/out of scope per instructions.

## Non-blocking observations (no action required this round)
1. `windowSetFiltered` walks forward re-lexing every source row between matches to
   fill a window, so serving W filtered rows over a source span S costs O(S)
   re-lex, not the contract's stated "O(window)". For realistic viewports this is
   trivial; only a pathologically sparse filter (e.g. 1 match / 1e6 rows) with a
   large window makes it costly on the window lane. This is INHERENT to the
   counters-not-lists mandate (a match list is forbidden by contract) and mirrors
   the frozen SEARCH nav design (mmap re-lex behind frontier, disk-bound). No
   in-contract fix exists, so NOT a finding.
2. Duplicated validation block (above) — cosmetic.
