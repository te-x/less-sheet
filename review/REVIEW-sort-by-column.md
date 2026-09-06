# REVIEW — sort-by-column

Feature: sort the document view by one column, ascending or descending, session-only, with a converging
sorted prefix served while the key pass runs (design: `docs/architecture/ARCH-sort-by-column.md`, base +
Amendment 1 "latency over throughput", both signed by the author on 2026-09-06). Contract frozen in
`798a893` and amended in `fb84d32`; harness fix `45e0289` (the write guard honors nested component
profiles) preceded the build. This record is written per converged cell; the frontend cells and the
planner's `tools/fuzz` entry are appended as they converge.

## Backend cell — `build-sort-by-column-backend` — **PASS (round 3)**

Roles: implementer + reviewer (native runner, the configured models), orchestrator as switchboard; every
handoff relayed by reference and journaled (`verify-relay`: PASS, 13 ledgered turns, byte-exact). The
trusted backend gate was run by the orchestrator on every round's tree: 330/330 natively and 330/330 in the
`fedora:43` container, three ReleaseSafe builds, `zig fmt` clean, zero warnings. Only `backend/src/**`
changed (11 files, +2970/−101); `api/`, contracts, tests, build files and the other components are
byte-identical to the freeze. Reviewed tree: workspace digest `9b88c202…`, backend `aabeda5f…`.

### Rounds
- **Round 1** — implementer delivered the feature (key encoding + exact comparator grounded in the
  column-inference grammar, chunk/run/merge engine, top-K prefix, on-disk permutation + inverse mapping,
  the single `tempdir.resolve()` now also used by the gzip spill and net spool) and found two perf defects
  itself (linear k-way merge → heap, 233 s → 88 s; offset-chasing chunk sort → fixed-width prefix keys,
  88 s → 64.5 s) plus a merge that held the document mutex for its whole 6 s. Reviewer: 7 `[impl]`
  findings — a use-after-free on the last-chunk OOM path (unreachable by the frozen injected-failure test
  because `allocOk` was consulted in the wrong place), find-under-sort implemented as a synchronous
  double re-lex under the mutex instead of FR7's sorted-position counters, BOOLEAN keys read the untrimmed
  cell, two accessors allocated under a sort, two knob literals bypassing the resolver, a net document
  with no worker could download the whole resource under the mutex, stale `ls_window_match_flags` after a
  prefix refinement. Both of the implementer's deliberate §8 deviations were ACCEPTED (a BUILDING pass
  outranks a jump in the worker; no PARKED report under LS_INDEX_AUTO on a local document) and left for the
  planner to reconcile in the header prose.
- **Round 2** — all seven fixed; find-under-sort reimplemented as FR7 (match-scan tallies per sorted block
  via the inverse mapping, navigation examines one block off-lock on the worker, cached per block).
  Reviewer: 2 small `[impl]` findings in the new tally staging (a dropped staged match silently shortened
  the counters; a shared bool read off-lock).
- **Round 3** — both closed (complete-or-nothing tally with a contiguity proof; the flag snapshotted under
  the mutex and passed as a parameter, which also caught a test seam an atomic would have missed).
  Implementer proved the fallback path by temporary injection against an oracle, then reverted it
  (verified byte-identical). Reviewer: PASS.

### Measurements (orchestrator-run, ReleaseSafe, native builds of the reviewed trees, idle machine; fixture
`c10-10GB.csv`, 135,178,871 rows, and its `.csv.gz`)
| criterion | bound | measured |
|---|---|---|
| AC-s10a key pass vs same-session full-file search scan | ≤ 3× | 61.8 s vs 30.0 s = 2.06× (decimal), 62.9 s = 2.09× (text); round 2: 2.01× |
| AC-s16(b) first sorted window after `ls_sort_set` | ≤ 100 ms | 6.4 ms (decimal), 7.3 ms (text), 21.8 ms (gzip) |
| AC-s9 scratch disk, text column | ≤ 48 B/row peak, ≤ 16 retained | 36.0 B/row peak (run 20 + perm 8 + inv 8), exactly 16.0 retained, 0 files after close |
| AC-s10b gzip sorted scroll (report only) | — | 1,753 ms cold / 1,749 ms warm per 50-row window |
| plain sorted scroll | — | 9–17 ms per 50-row window, 0 re-issues |
| AC-s5 find-under-sort navigation | responsive | call returns 0.0 ms; resolves 367 ms first hop, then 1.3 ms (round 1: 50.1 s blocking); answers byte-identical across both implementations |
| AC-s8 open + first window | unchanged | 58 ms before and after (implementer's interleaved runs) |
| boolean whitespace discriminator (M5) | `1 0` | `0 1` in round 1 → `1 0` in rounds 2–3 |
| hostile corpus × type override (M6) | no crash | 56 cases × ≤ 4 columns × 6 override kinds = 1050 combinations, 0 non-zero exits, all terminal ACTIVE |

### Durable notes
- **ARCH §4 build-time RSS is imprecise, not violated.** `ru_maxrss` over the control scan grows by
  0.73–1.26 GB and scales with rows, because the two temp mappings' file-backed, evictable pages count as
  resident; the core's anonymous residency stays inside 2× the chunk knob + O(K) and is row-independent
  (`srt_memory_bound`). The planner should add one clause excluding mapped temp storage from that sentence.
- **§8 slot prose to reconcile (planner):** a BUILDING pass outranks a jump in the worker; under
  LS_INDEX_AUTO on a local document a jump does not report PARKED (the pass never yields).
- **The gate's last step leaves an x86_64 ELF `liblesssheet.a` in `backend/zig-out`.** Rebuild natively before
  linking any probe or bench against it (the stale-archive hazard, again).
- **"A clean library build is not evidence of a clean gate":** a Zig-only test seam in `root.zig` compiles
  only under the test step; the implementer's round-3 edit broke it and only the full gate caught it.
- **For the frontend cells:** a wide, short document (2000 columns × 626 rows) converges over ~290 window
  re-issues per cold sorted window (571 ms cold, 19 ms warm) — a repaint-loop hazard the UI must absorb.
  Gzip sorted scrolling costs ~1.75 s per 50-row window (accepted ship-and-measure); the UI must show the
  loading state.
- **Pending (not against this cell):** the `tools/fuzz` sort entry (AC-s13's campaign half) is the
  planner's, per the author's decision; it must iterate type overrides per column or it only re-walks the
  text path.
