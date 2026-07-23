# REVIEW — gz Source tail-materialization fix (local EOF dead zone + network stale-buffer)

**Verdict: PASS (2 rounds).** Backend bug-fix cell (implementer + reviewer, both opus, run-id `gz_tail_eof`)
on branch `feat/kbdnav-a11y`. Fix commit `26abe2e` (`src/source.zig` only); RED freeze `907bbe7`; net-path
regression freeze `bc64d31`. Orchestrator `gate --require-frozen --relay gz_tail_eof` = **PASS** (integrity
OK / conformance OK / behavior GREEN 265/265, both linux-musl cross-compiles, `zig fmt`, flat-RSS bench;
`verify-relay` PASS on all 4 ledgered turns). Reported by the author on `eagleData_berlinTile.csv.gz` (334 MB,
37,317,552 rows, single-member gz).

## The bug + fix
- **Round 1 (the reported bug):** on a large streaming `.csv.gz` the final `chunk_bytes` (256 KiB) of
  inflated output never materialized — `cursorAt` routed behind-frontier tail reads onto forward lane 0
  (which can't serve past clean EOF) via a stale `forward_resume` hint, so `produce` returned 0 → the last
  ~5,162 rows rendered EMPTY while the count (streaming index reaching true EOF) was correct and the plain
  `.csv` was fine. **Fix:** `cursorAt` picks lane 0 only when the forward session can serve the position
  (`internal >= forward_logical`, or the resident op buffer covers `internal`); else route to a replay
  session. Removed the dead `forward_resume` field + its `Cursor.deinit` store.
- **Round 2 (reviewer finding, confirmed reachable by probe, then fixed):** the widened `fwd_buffered`
  fast path could **skip bytes in the NETWORK budget-stop path** — a budget-stalled forward lane leaves a
  stale op buffer, and a later `fwd_buffered` read crossing `op_end` returned the byte at the budget stop
  `B`, not `op_end`. Empirically confirmed (pre-fix probe: `'7'` where the oracle has `'8'`). **Fix:**
  `byteAtLane` forward-lane guards — return null (reroute to replay) when the forward session over-produced
  past `internal`, and drop the clobbered op buffer (`op_len=0`) on a failed `discardTo`.

## Diagnosis facts (orchestrator, before dispatch)
Single-member gzip (not multi-member), 37,317,552 rows / 1.909 GB decompressed (~51.2 B/row), all lines
non-blank. The empty tail is a **constant ~256 KiB (= `chunk_bytes`) dead zone** regardless of file size —
HEAD-gated (rows inside the 4 MiB open head are fine) and checkpoint-independent (reproduces below + above
the 32 MiB gz checkpoint) → an end-of-stream Source defect, not data/member/frontend/count.

## Reviewer-confirmed
Lane selection correct per position class; generality (routes on `forward_logical`/op-buffer coverage, not
content/size); concurrency safe (`op_start[0]/op_len[0]` mutated only by a lane-0 op under `lane_busy[0]`,
read under the lock only while `!lane_busy[0]` — no TOCTOU); round-2 guards close the hazard at the root
(the inconsistent state can no longer form; guard (a) is a fail-safe; reroute reliable, no null-loop);
local path unchanged; `forward_resume` genuinely dead; O(viewport) + constant memory preserved.

## Frozen regression tests (both RED-verified, now GREEN)
- `gz_tail_eof` (×2, `907bbe7`): ~9 MiB / 500k distinct rows past the 4 MiB head (below the 32 MiB
  checkpoint) + a ~40 MiB high-expansion fixture crossing a durable 32 MiB checkpoint (replay path) +
  `ls_cell_copy`; tail window must be byte-equal to the plain oracle.
- `gz_net_tail` (`bc64d31`): network `.csv.gz` over the fake transport, compressed high-water pinned behind
  true end at a gzip member boundary via the AC13 `withhold` gate, a forward-lane seek clobbering the
  resident chunk + budget-stall, then a differential-vs-plain tail read over the frontier band.

## NEW FINDING (out of scope for this fix — tracked separately)
The planner found (twice) that driving the forward inflater into an **arbitrary mid-DEFLATE-symbol
compressed truncation crashes `std.compress.flate`** — an integer overflow in `peekBitsEnding`
(`left.len * 8 - d.consumed_bits`) that aborts BEFORE `produce`'s error `catch` can set `.budget`. It
worked around this in the test by pinning the withhold at a **gzip member boundary** (`nextMember` sets
`.budget` cleanly, no split symbol). The normal worker jump parks gracefully rather than driving into a
truncation, so this **may be latent-only** — but given the network design streams partial compressed
fetches AND we ship **ReleaseFast (safety checks OFF → an integer overflow is UB, not a clean panic)**, it
warrants an implementer/architect look at reachability. See task #40; relates to [[security-threat-model]]
(fuzz the parser).

## Process note
The net-path regression freeze first ran ~4h (thrashing on deterministic mid-symbol stalls + large
fixtures + iterated RED-verification); stopped, re-dispatched with a tighter brief (reuse the proven probe,
minimal fixture, one RED check) → converged in ~2.4 min (+8 s test runtime). See
[[aidev-role-cost-and-kill-hygiene]].
