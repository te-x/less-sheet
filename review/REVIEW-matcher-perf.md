# Task #6 — the scan matcher: 1.9× search, 4.0× matcher, almost none of it from SIMD

**Status: reviewer-PASS at `3946713` (round 2).** Branch `master`.
Perf-only cell: no new contract surface, no new frozen test. Baseline `7dc5c21`.

| | |
|---|---|
| Footprint | `backend/src/{matcher,base,search,filter,open,root,window}.zig`, `tools/fuzz/{matcher_diff.zig,build.zig,README.md}` |
| Byte-identical | `api/lesssheet.h`, `backend/contracts/`, `backend/tests/`, `backend/src/{csv_reader,lexer}.zig` |
| Gate at close | ROOT PASS — EXIT=0, 4× `GATE: PASS`, 297 tests, run by the orchestrator on the delivered tree |
| Suite count | **297 on master too** — no test was added, removed, relocated or weakened |

## The result, and where it actually came from

Independently re-measured (not the implementer's numbers), 8 interleaved outer reps × 2 inner,
ReleaseSafe, 210 MB fixture, ms:

| op/spec | base | final | ratio |
|---|---|---|---|
| search/nomatch | 563.5 | 294.2 | **0.52×** |
| search/early | 431.6 | 299.6 | 0.69× |
| search/floor | 442.6 | 204.7 | **0.46×** |
| index_scan (control) | 364.6 | 371.0 | 1.018× |

`filter` tracks `search` within 1%. On a 67 MB single cell: text search 125 → 9.2 ms, ordering
predicate 143 → **2.5 ms**.

**The headline is a deletion, not a vectorisation.** `search/floor` is an ordering predicate aimed at
a TEXT column — the numeric FSM reaches `.invalid` on byte one, so the row's verdict is settled
immediately. Master then fed it every remaining byte of the file: **~238 ms of a 443 ms scan was work
whose result was already known.** Step 1 reclaimed essentially all of it. The same defect on a 67 MB
cell cost 143 ms.

Matcher share, using the unchanged structural floor (`csv_reader.zig`/`lexer.zig` byte-identical, so
one floor applies to both builds): `563.5 − 204.7 = ~359 ms` → `294.2 − 204.7 = ~89 ms` = **4.0×**.
Robust to its premise — if the floor differs by the ±2% the control shows, the ratio stays in
[3.96, 4.05].

## The three steps

1. **Early verdict exit in `StreamCell.feed` — all three arms.** The brief scoped this to TEXT; the
   implementer widened it to EQ/NE and the ordering FSM on the theorem that `matches()` can no longer
   change, and was right. Verified by grep, not by reading the claim: **nothing outside `matcher.zig`
   reads `.len`, `.equal`, `.text_k` or any `num_*` field** — the only external touches are
   `StreamCell.init(...).matches()` and `@sizeOf`. `text_found` is only ever assigned `true`; `equal`
   only ever `false`, and `matches()` reaches `len` only through a short-circuiting
   `self.equal and …`; `.invalid` has no outbound transition.
2. **One `matcher.Query`** owning owned bytes, the pre-folded query, the KMP table over the *folded*
   query, the parsed `Decimal` and the anchor constants, with `init`/`clone`/`deinit`; `MatchCtx`
   carries `q: *const Query`. Retired two `buildFailure` call sites and two `Decimal` re-parses in the
   worker snapshots, made `buildFailure` private, collapsed 8 Document fields to 4.
3. **Vectorized two-byte anchor prefilter** for TEXT, live only while the KMP cursor is 0. Two bytes
   rather than one so a common first byte cannot degenerate into a block scan per byte.

Step 2 alone regressed long-cell rare-anchor text ~8% while improving short cells 20–30%; step 3
subsumes it. **If step 3 is ever reverted, step 2 needs re-examining for that shape.**

## What review changed

**F1 — a false performance claim, caught before it entered the record.** The report said "the
matcher-free scan floor improved 356→196 ms". It cannot have: nothing structural changed. The claim
conflated three quantities — a subtraction (`566 − 210`), a direct measurement, and `ls_index_poll`,
which measures the **indexing sweep** (checkpoints + column stats), not `matchMmapUtf8`. Settled by
measuring the floor directly (~205 ms) against the index sweep (~371 ms) rather than by argument.
This is the same class as the retracted 28% `copy_rows` anomaly — *a subtraction is not a
measurement, and two numbers from different code paths are not a before/after.*

**F2 — `Query.clone` inferred its kind from a derived artifact** (`failure.len > 0`). Latent, not
live, but the same class as the hazard the implementer had caught in self-review, and the earlier fix
had removed the caller's ability to get it wrong while leaving the inference. Now `Query` stores
`is_text` and `build` derives both from the same parameter in the same function body, so they cannot
disagree by construction. Exactly three construction paths (`init`, `clone`, default `.{}`); no
struct literal anywhere else.

**F3 — dissolved by running it rather than arguing.** The reviewer suspected the oracle didn't pin
the two conditions the optimization rests on and specified two mutations. Both were **already
caught**: `if (k == 0)` → `if (true)` (skip while a partial match is in flight) and
`.anchor1_upper` losing its fold twin. The oracle was stronger than the review credited. Both are now
in a documented five-mutation table, re-run against this tree.

**A near-miss worth recording.** Step 2 replaced `clearRetainingCapacity` + `appendSlice` (in place,
usually no free) with `clone` + `deinit` (**always** frees). Had any cross-thread refresh existed,
that would have converted a benign torn read into a use-after-free. It doesn't — all twelve refresh
sites are the worker thread itself under the lock, the degraded synchronous paths where the caller is
blocked, or the test-only parked step — but the safety is contingent on that, not structural.

## Residual

- **The +1.8% index-scan regression, MECHANISM UNVERIFIED.** Real and reproducible in min and median
  (+1.8% orchestrator run, +2.1–2.3% implementer's), on a path whose code did not change. One
  hypothesis **disproven**: not per-chunk `clone`+`deinit` churn, since `refreshWorkerCtx` is gated on
  `doc.search_gen != doc.w_gen` (`index.zig:194`) and runs once per request. Document field
  layout/cache is **plausible but not established** — and the spread between the two measurements is
  itself about the size of the effect, so it should not be quoted to two significant figures. Not
  chased: ~7 ms on a non-interactive 371 ms sweep against a 1.9× win. **This must not compress into
  "field layout caused it".**
- **`gz_match_resident_bytes` dropped, and the gate could not see it.** `MatchCtx` 136 → 40 bytes,
  `StreamCell` 224 → 128, so the AC13 contract-surfaced residency reads 448 → 256 (search, 2×) and
  224 → 128 (filter). Direction is down and the frozen assertion is an upper *bound*, which is exactly
  why a green gate stayed silent about a contract-surfaced number moving.
- **`cellMatches` and `StreamCell` deliberately NOT unified** — their ordering arms are genuinely
  different algorithms (exact-decimal parse-and-compare vs incremental FSM). The oracle pins their
  agreement instead.
- **Oracle coverage caveat**: the sweep's largest cell is 1031 bytes, so the 67 MB single-cell shape
  that earned the headline 13.5× is represented at ~1/65,000 of its size. The biggest win sits on the
  least-covered shape.

## Filed forward to the structural-scan cell (task #9)

- **Two `findAny` sites, not one.** `csv_reader.zig:446` and `lexer.zig:192` run the identical
  `std.mem.findAny(u8, …, &.{ sep, '\r', '\n' })`. In Zig 0.16 that resolves to `findAnyPos`
  (`mem.zig:1347`), a plain nested scalar loop — three compares plus a bounds check per byte — while
  `findScalarPos` 80 lines above it *is* vectorized. One shared helper, not a point patch.
- **Do NOT inherit "205 ms of `findAny`".** The ~205 ms floor is the match-scan path floor and
  contains more than the delimiter scan: `matcher.StreamCell.init` runs unconditionally at
  `csv_reader.zig:417/418` *before* the `pfeed` check, so the floor includes ~3 × 3.4M ≈ **10M
  StreamCell constructions**. `findAny` owns **≤ 205 ms** and the split must be profiled.
- **A free win in the same loop, reviewer-verified as behavior-preserving**: the row loop keeps
  feeding the primary `StreamCell` for columns *after* a TEXT match, and `matchRecord` discards those
  verdicts. Since `primary_col` is only ever assigned under `if (primary_col == null …)`, `pfeed` at
  `csv_reader.zig:419` can become `wantsCell(primary, col) and primary_col == null`. Needs a fixture
  that matches in the FIRST column of a wide row — the matcher cell's fixtures all matched in the
  last, which is why it could not measure it.

## Process notes

- **A green gate cannot see an upper-bound assertion going slack.** The AC13 residency number moved
  by a factor of ~1.75 and every leg stayed green, correctly.
- **The reviewer corrected two of the orchestrator's own premises.** The suite count was not 288→297
  (master is also 297 — the 288 was a stale baseline from an earlier log), and the "+5% regression on
  early-matching cells" was step-2-vs-step-3 between two unshipped candidates: against master that
  shape is **31% faster**. Both would have entered the record as real defects.
- **Two mutations beat an argument.** F3 was a plausible hypothesis about a blind spot; running the
  two probes took minutes and resolved it in the opposite direction to the suspicion.
