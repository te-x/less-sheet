# REVIEW — gz-filter-stream (fixes csv-gz defect #14)

**Final verdict: PASS.** Backend-only. `api/lesssheet.h` byte-identical. Bound tree `97e2710d…`; freeze
`dae0fc5` (original regression) + this build. Root gate PASS.

## Defect
Filtering (or searching) a `.csv.gz` effectively hung — surfaced during the window-budget NFR harness (~5 of
16 rows in ~226 s). Root cause (planner-verified): a gzip FILTER/SEARCH background scan trailing the index
frontier reused the shared `forward` inflater lane, but once the forward session's `logical` raced ahead
(peek-ahead + 256 KiB over-production) `byteAtLane` could not serve a byte behind it → the scan **livelocked**
on 0-byte `produce()` calls (never terminated, count frozen wrong). Inflated bytes plateaued at ~1× logical,
so a byte-bound alone couldn't catch it; the deterministic tell is inflate **operations** growing unbounded.

## Fix (implementer ⇄ reviewer, 3 rounds)
- **R1** — preserve peek-ahead across lane-buffer boundaries; trailing scans select an independent replay
  lane; retain one cursor across a scan block. Regression ops 14,000→186 on the single-block case. Review →
  `[impl]`: the lease only spanned ONE 2048-row block, so interleaved behind-frontier window/copy re-inflated
  ~32 MiB per block.
- **R2** — **whole-job replay retention**: `Document` owns the active gzip scan cursor keyed by
  filter/search generation (`base.zig`), released only on scan-slot ownership change / EOF / cancel /
  shutdown / teardown (`index.zig`); filter/search reuse it across all blocks. Reserved lane stays busy for
  the job; a second behind-frontier consumer waits for the free replay lane (no 4th session, resident ceiling
  intact). Review → `[impl]`: a data race — the worker read `doc.filter_gen`/`search_gen` unlocked when
  acquiring the lease.
- **R3** — thread the mutex-captured generation into the scan chunks (`index.zig:177`); lease
  acquire/key/release use the immutable generation; release only the matching owner/generation. Reviewer PASS.

## Regression lock (planner, strengthened per reviewer)
`gzfs_filter` / `gzfs_search` (48 rows, single block — original) plus `gzfs_filter_multiblock` /
`gzfs_search_multiblock` (150,000 × 512 B rows ≈ 73.2 MiB, 74 blocks crossing the 32 & 64 MiB checkpoints;
AUTO + scanToEnd so the scan trails the frontier; driven one 2048-row block at a time with a behind-frontier
replay-lane read between EVERY block). Asserts `bytes ≤ 2×logical` AND `ops ≤ 4×(logical/256 KiB)`, exact
totals (150,000), and termination. Deterministic via Zig-only comptime-pinned seams
(`gzInflatedBytes`/`gzInflateOps`/`gzInflateWorkReset`, `gzScanParkWorker`/`gzScanStep`/`gzTouchReplayLane`;
`api/` untouched; production seed default-off → byte-identical prod).

**Independent proof (planner-measured, gate-locked — not implementer self-report):** committed fix =
72,605,704 bytes / 282 ops; per-block-lease regression = 1,186,185,648 bytes (~16×) / 4,637 ops (trips the
byte bound); original livelock → ops→∞. New tests RED on the regression, GREEN on the fix. Reviewer accepted
this as adequate independent evidence; no separate release rerun required.

Result: `zig build` green; `zig build test` 167/167; root gate PASS.
