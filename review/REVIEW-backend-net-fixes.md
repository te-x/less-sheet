# REVIEW — backend network-path fixes (hang, slow open, jump-progress)

**Verdict: PASS (1 round, no findings).** Bound to tree-hash `908a46a8…`, trusted gate 256/256 +
both `-*-linux-musl` cross-compiles + generator 142/142. The CORE half of the network-loading cluster
the author found on the 32 MB stats.govt.nz URL — **fixes both macOS and GTK** (shared core). Frozen RED
tests `net_bug_open_head_roundtrips` (#5) + `net_bug_jump_progress_evolves` (#6) at freeze `a242d52`.

## Fixes (`src/net_source.zig`, `src/index.zig`)
- **#5 — slow open (~5-7 s → ~1-2 s).** The RANDOM-fill fetch assembled the 4 MiB head as ~16 separate
  256 KB ranged GETs. New `ensureChunkRangeLocked` coalesces each contiguous run of missing chunks into
  ONE ranged `fetchInto`; `fetch_count` counts round-trips (not chunks); present chunks break a run
  (LRU-touched, not re-fetched). Open = magic GET + coalesced head GET = **2** ⇒ `netFetchCount ≤ 2`.
  (Real-transport-only follow-up, deferred/human-verified: retain the probe's already-fetched 4 MiB body
  — the fake has no probe GET so it's out of gate scope.)
- **#6 — jump-scan progress stuck ~0.12.** `updateJump` used a target-ROW ratio (÷ the unreachable target
  row). Replaced with a **byte-frontier fraction**: project the target's byte offset from the observed
  scan rate, cap at `data_span`, `progress = covered/target_span`, clamped [0,1] through the existing
  monotone guard; DONE untouched (1.0); unknown-length falls back to the row ratio. Beyond-EOF → climbs to
  ~1.0 at EOF; in-range → tracks to the target. Local-jump invariants (L884/1583/2731/2826) preserved.
- **#1 — hang (NOT gate-testable — real HTTP is fake-seam-only).** The RANDOM `ensureSlice` held the
  HttpRange mutex ACROSS the ~1 s ranged GET → every main-thread present-byte read blocked → the scroll
  freeze. `ensureChunkRangeLocked` now RELEASES the mutex across `fetchInto`, guarded by a `fetching`
  boolean (mutated only under the mutex). **Reviewer-verified concurrency** (race/deadlock/half-write-free
  by construction — see the verdict); the actual latency/hang behavior is the author's real-host pass.

## Reviewer verification (PASS)
#1: run-form + `fetching=true` atomic under the mutex (no double-fetch / no overlapping runs); `present[k]`
set only after `fetchInto` returns AND the mutex is re-acquired, held through the `defer unlock` (no
half-written read); runs disjoint from present bytes, `present` never cleared post-open; single mutex, no
nesting, `fetching` cleared unconditionally incl. the failure `return` (no deadlock/livelock/stuck waiter);
shutdown checked each loop iteration + a real yielding `sysio.sleepMs` wait; single-path-per-doc + per-doc
transport ⇒ one GET at a time (safe for the shared HTTP client). #5: round-trip counting + no gaps + no
re-fetch. #6: cap/clamp/monotone/1.0-at-DONE/no-div-by-zero/no-u128-overflow/row-fallback all verified.

## Non-blocking notes (recorded, do NOT gate)
1. A hung **in-flight** GET is broken only by transport cancellation/timeout, not the `shutdown` flag (A
   doesn't re-check mid-GET) — strictly better than the old mutex-held behavior; a real-host GET timeout is
   the proper fix (folds into network-robustness hardening, see [[security-threat-model]]).
2. `ensureChunkLocked` (gzip path) is outside the `fetching` guard → single-path-per-doc is load-bearing
   for transport serialization (holds today; a future both-paths-per-doc would need the guard extended).
3. A failed GET returns a zero-holed `spool` slice — pre-existing behavior, not a regression.

## Gate / discipline
256/256 + both cross-compiles + generator. Scope `src/net_source.zig` + `src/index.zig`; no
`tests/`/`api/`/`contracts/`/`build.zig` drift. Real-host latency/hang = the author's desktop pass.
