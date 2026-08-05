# Task #13 — the gzip/network match scan, and the last cell of the perf arc

**Status: reviewer-PASS on the code, 2 record-accuracy findings, both closed. Committed `0571cd9`.**
Baseline `24d39a6`. 56 non-comment source lines.

| | |
|---|---|
| Footprint | `backend/src/{csv_reader,encoding,lexer,root,source}.zig` (`source.zig` documentation only), `tools/fuzz/{harness.zig,lexer_diff.zig,README.md}` |
| Byte-identical | `api/lesssheet.h`, `backend/contracts/`, `backend/tests/`, `apps/`, `.aidev/` |
| Gate at close | ROOT PASS — EXIT=0, 4× `GATE: PASS`, 297 tests, run by the orchestrator |

## Why this cell existed, and who chose it

The previous cell's vector scan was reachable only for `.mmap` — `csv_reader` dispatches
`.mmap => <content-based lexer.*>` versus `.gzip, .http_range => <cursor-based *Stream>`. The
**reviewer** identified this and overruled the orchestrator's priority: the orchestrator had
recommended the index sweep next because it was the biggest number, and the reviewer pointed out the
index sweep is a background path nobody waits on, whereas the gz match scan is a **foreground wait**.
That was correct, and it is the single best call in the arc.

## Profiling decided whether to build at all

Inflate measured **directly** with the same `std.compress.flate` the backend uses, not by
subtraction: **34.4 ms** on a pathologically compressible 123:1 fixture, **421 ms** on a realistic
6.8:1, **578 ms** at 4.2:1 — per 209 MB. On the realistic fixture `search/floor` decomposed as
inflate 421 ms (13%) + `matchCursor` ~2728 ms (87%), against 118 ms for the same document as plain
mmap.

**This also corrected the brief this cell was given.** The orchestrator had briefed a 3.2 s / 0.14 s
pair as the gap to close. The 0.14 s came from the 123:1 fixture, which inflates in 34 ms *because*
it is pathological. A realistic `.csv.gz` is **inflate-floored at ~420–580 ms** and can never match
uncompressed. Had inflate dominated, the correct outcome was to not build this at all.

## Measured, with the paths each number covers

Min of 8 interleaved outer reps, ReleaseSafe, base built in the same session, ms.

**Local `.csv.gz` 6.8:1, unquoted fields — the headline path:**

| | base | final | ratio |
|---|---|---|---|
| `search/floor` | 3149.8 | 799.7 | **0.254× (3.9×)** |
| `search/nomatch` | 3597.1 | 854.5 | **0.238× (4.2×)** |
| `index_scan` (control) | 855.4 | 854.7 | 0.999× |

**Local `.csv.gz`, wide 2000-col:** `search/first` 2678.9 → 1283.4 (0.479×), `search/last`
3266.9 → 1469.3 (0.450×), control 1.000×. Both rows improve — unlike the previous cell's early-out
which moved only `first`. That is the signature of a scan-wide win rather than a verdict-settling one.

**Local uncompressed mmap, same document — must be flat, and is:** `search/floor` 117.5 → 118.5
(1.009×), `nomatch` 200.6 → 201.5 (1.004×). Confirms containment to the cursor path.

**Network (`http_range`)**: code-reachable through the same `matchCursor`, deliberately **not
benchmarked** — no clean rig, and round-trip latency would measure the network rather than the change.
The gz numbers do not speak for it. The reviewer verified the property that actually matters there is
preserved: `spanHttp` bounds every span to the next chunk boundary (`source.zig:1299-1304`), so the
fast path cannot turn a match scan into a full download — **"no full download, ever" is intact.**

## THE TRADE — measured, not left uncosted

The fast path replaces only the **unquoted** field scan; the quoted arm still runs unit-at-a-time with
**one-byte feeds**, which is the worst of the costs (a one-byte feed sits below the matcher's vector
prefilter threshold and takes the scalar KMP step). The reviewer raised this as F1 because every
fixture in the measurement set was unquoted. The implementer then **built an all-quoted fixture**
(219 MB, every field quoted, embedded commas so the quoting is load-bearing) rather than record an
intention:

| all-quoted local `.csv.gz` | base | final | ratio |
|---|---|---|---|
| `search/nomatch` | 3417.9 | 3468.8 | **1.015×** |
| `search/floor` | 3047.1 | 3062.6 | 1.005× |
| `index_scan` (control) | 591.9 | 592.9 | 1.002× |

**A fully-quoted `.csv.gz` gains nothing and is ~1.5–1.8% slower.** Real, not noise: reproducible in
min *and* median across two runs, control flat in the same run, non-overlapping bands (base
3417.9/3422.1/3433.5 vs final 3468.8/3478.6/3490.9).

**Mechanism UNVERIFIED.** The obvious hypothesis — a per-field `encoding` branch — was tested by
hoisting it out of the loop and changed nothing (1.016× vs 1.015×). Hypothesis **disproven**, and the
hoist **reverted** rather than carried as a change implying a fix it did not deliver. Code layout from
the function body roughly doubling is plausible and explicitly **not established**.

So: quote-heavy gz pays ~1.8% so unquoted gz gains 3.9–4.2×. Heavily favourable, and still a
regression on a supported shape. Both facts are in the record and the headline numbers are labelled
unquoted-field numbers **in the code itself**.

## The finding that matters more than the speedup

**5 of 6 planted defects survived all 297 frozen tests.**

Three are provably benign, and the reviewer derived that set **independently** rather than accepting
the implementer's label — which is the right way to audit a self-dismissal. The fast path is
**structurally self-correcting**:

1. Deleting `if (rel != null) break;` — the top-of-loop `unitIsStructural` check re-detects the
   terminator next iteration.
2. Shortening `run` to anything in `[1, run]`, provided the same bytes are fed and advanced — every
   byte is still fed exactly once, just in smaller pieces, and `StreamCell.feed` is **split-invariant**
   (the property `matcher_diff.zig` exists to pin).
3. Deleting the top-of-loop structural check — `rel == 0` → `run == 0` → empty feed → `advance(0)` →
   break via `rel != null`.

Both dismissed mutations were traced to their class and named in the README, so "5 of 6 survived" is
auditable rather than a self-assessment. One nuance the implementer added: **class 3's benignity is
contingent** on the `span()`-empty fallback being unreachable — were it reachable, that path would
feed the separator byte itself. That links the benign set to the one uncovered branch.

The complementary set of *genuine* defects is exactly: feed fewer bytes than you advance, drop or
duplicate a span, over-advance past the terminator, fail to progress. **Those are precisely the four
the new lock catches** — lock coverage matching the reachable defect surface exactly.

**Why the genuine ones survived: the frozen suite cannot enter the multi-span branch.** That needs a
field >256 KiB (`chunk_bytes`, `source.zig:18`) sitting past the 4 MiB gzip head
(`open_head_max_bytes`, `contracts/api.zig:87`), because inside the head `span()` returns the whole
remainder. Proven by planting an infinite loop (`rel orelse 0`) and watching 297 tests pass.

Closed with a permanent **mmap-vs-gzip parity lock** in `tools/fuzz/harness.zig` over an over-span
cell, **4/4 sensitive** (one as a hang). It took two fixture iterations, and both lessons are worth
keeping: needles only at the cell's end let "feed just the final span" escape, and needles only
mid-cell let a short feed at the end escape. The reviewer verified the lock genuinely enters the
branch arithmetically — 5 MiB pre-fill puts the cell past the head, `span()` takes the lane arm
bounded by ~256 KiB, a ~1 MiB payload needs ≥4 spans, and the needles at ~300 K/~700 K/~1000 K fall in
different ones.

## Equivalence, argued rather than inherited

The previous cell got streaming safety for free: gzip never reached the vector scan, and mmap mappings
are stable. Neither holds here.

For UTF-8, `decodeUnit` short-circuits (`encoding.zig:174`) to `decodeUtf8PassthroughUnit` (`:247`) —
one raw byte in, the same byte out, never null, never validated — so the unit loop **already was** a
byte loop, with no malformed-input divergence.

Rather than prove `span()`'s demand semantics match `peek()`'s, the implementer made it safe by
construction: **`streamUnit` remains the sole authority** for both decisions that can end a field, with
`span()` only a bulk accelerator between them and a one-byte fallback if it under-delivers. Nothing
treats `span()`-empty as EOF. Progress is guaranteed because `bytes[0]` is the byte `streamUnit` just
proved non-structural, so `run >= 1`.

The reviewer noted the argument **understated** one dependency and then closed it: *within* a span,
`findStructural` — not `streamUnit` — decides where the field ends, so equivalence needs `span()` to
honour exactly the limits `peek()` honours. It verified all four arms, including that `cursorAt`
(`source.zig:1667`) never sets `physical_limit` for `.gzip`, so `span()`'s gzip arm omitting it is
**correct rather than a gap**.

## The encoding gate, and the reason nobody would rediscover

The GUARD test proves byte-wise scanning is wrong for every non-UTF-8 encoding the product supports
(the switch is exactly `{utf16le, utf16be, latin1, windows1252}`): U+2C00 is `00 2C`, a comma that is
not a separator, and Latin-1/Windows-1252 decode one source byte to two output bytes.

The implementer had also stated `danglingTail == 0` as a property of `danglingTail`; it isn't — that
function is encoding-agnostic. The real chain, now recorded and **executable**: under UTF-8 a null unit
can only mean `peek` returned zero bytes, so `in_hand == 0` and `danglingTail` yields 0; under UTF-16 a
unit can be null with `in_hand == 1` (a lone trailing byte), so it is genuinely nonzero and a byte-wise
arm would **silently drop that residue**. That asymmetry is a third independent reason the gate must
stay, and the one a future reader is least likely to find.

## Deliberately un-asserted

The `span()`-under-delivers fallback is unreachable in every constructible configuration and is kept
anyway, **not converted to an assertion**. Reviewer's reasoning, endorsed: removing it risks treating a
present byte as end-of-field — silent truncation, the worst outcome in this project's taxonomy — while
an assert would trade that for a ReleaseSafe panic, which counts as a crash under the same bar.
`std.debug.assert` appears only three times in all of `backend/src`, so an assert would also be against
house style.

## Closed-out backlog, with the cost of leaving it

This is the last cell of the arc, so these are numbers rather than intentions.

1. **`matchCursor` per-column residual ~260 ms** against a 539 ms floor (inflate 421 +
   mmap-equivalent 118) — per-column cursor bookkeeping, ~3 `peek`s per column (quote probe, field
   scan, terminator classify). Holds the 2000-column fixture at 1283 ms. Leaving it costs ~1.3–1.5× on
   local gz search; taking it means bulk-reading the quote and terminator probes, where the equivalence
   argument gets materially harder.
2. **Quoted bodies** — a separate uncosted item, and now a known ~1.8% regression.
3. **`scanToStructural`** — unit-wise for all encodings, not on the gz search path; contributes to the
   index sweep and open-time field counting only.
4. **`scanUtf8Rows` — ≤434 ms, of which the byte-at-a-time row walk is the dominant term.** A *bound*,
   not a measurement: it is `index_scan` 855 − inflate 421, and the sweep also checkpoints and
   accumulates column stats. Deferred for the **correctness** reason, not the methodological one: it is
   quote-stateful, owns "a terminator is consumed whole, or not at all", and its own comment records two
   **opposite-direction** silent miscounts a pending-LF flag once caused. Locking it needs an oracle over
   row **counts** across span boundaries — a different instrument from the two this arc built.

## Process notes

- **Profiling before building, twice in two cells, changed the work both times** — here it corrected the
  briefed ceiling; last cell it redirected off a 2% target onto a 42% one.
- **The reviewer audited a self-dismissal by independent derivation** rather than by asking for the
  labels. That is the pattern to reuse: derive the benign set from the code, then check the claim
  against it.
- **A green gate said nothing about a branch that did not exist yet.** 297 tests could not reach the new
  code, and an infinite loop proved it. The third instance this week of a green gate being silent — and
  the first caught by attacking our own code rather than by luck.
- **A disproven hypothesis was reverted, not kept.** The encoding-branch hoist changed nothing, so it
  went, rather than shipping a change that implies a fix it did not deliver.
