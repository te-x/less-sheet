# Task #9 — the structural scan: 33 lines, 42% of the match-scan floor

**Status: reviewer round verdict — code correct, 2 findings both on claim accuracy, both addressed.
Committed `d130029`.** Baseline `28c4818`.

| | |
|---|---|
| Footprint | `backend/src/{csv_reader,lexer,root}.zig`, `tools/fuzz/{lexer_diff.zig,build.zig,README.md}` |
| Byte-identical | `api/lesssheet.h`, `backend/contracts/`, `backend/tests/`, `apps/` |
| Implementation size | **33 non-comment lines** |
| Gate at close | ROOT PASS — EXIT=0, 4× `GATE: PASS`, 297 tests, run by the orchestrator |

## The defect

The CSV field scan ran on `std.mem.findAny`, which in Zig 0.16 resolves to `findAnyPos`
(`std/mem.zig`) — a plain nested scalar loop, three compares plus a bounds check per byte, over every
byte of the file. `findScalarPos` eighty lines above it in the same file **is** vectorized, which is
why the gap survived unnoticed. Two sites ran the identical call, so this landed ONE helper,
`lexer.findStructural`, consumed by both, rather than a point patch. The quoted-field arm was already
on vectorized `findScalar`.

## Profiling first changed what got built

The previous cell left a ~205 ms floor, and the reviewer's hypothesis was that ~10M unconditional
`StreamCell` constructions dominated it. **Library ablation, the ground truth: replacing the scan
removed 85 ms of a 204 ms floor (42%); the constructions were worth ~2%.**

The obvious fix for that 2% was then **implemented and measured rather than assumed**: making `ps`
optional (`undefined` would be UB the moment a read escaped its guard) costs a ReleaseSafe unwrap
check on every `feed` — **+10.2%** on a full-column text scan to save ~2% on a predicate scan.
Reverted, with the reasoning recorded at the site so it is not retried blind.

The implementer also stated that its standalone replica **under-predicted** the narrow win (24 ms
inlined / 56 ms opaque vs 85 ms measured) and quoted the ablation instead. The discrepancy is itself
explicable: the narrow fixture calls the scan ~10M times, so per-call overhead dominates and an
inlined standalone under-represents it — which is why its long-cell prediction (9.8×) matched the
library exactly (9.6×) and its narrow one did not.

## Measured

Min of 8 interleaved outer × 2 inner, ReleaseSafe, base = pristine `28c4818` rebuilt in the same
session, ms:

| fixture / spec | base | final | ratio |
|---|---|---|---|
| narrow 210 MB `search/floor` | 203.4 | 117.9 | **0.580×** |
| narrow `search/nomatch` | 293.9 | 198.7 | 0.676× |
| narrow `search/early` | 280.4 | 187.0 | 0.667× |
| long-cell 210 MB `search/floor` | 107.9 | 11.0 | **0.102×** |
| wide 2000-col, match FIRST col | 355.6 | 140.3 | **0.395×** |
| wide, match LAST col (in-fixture control) | 379.1 | 300.2 | 0.792× |
| `index_scan` (control, all 4 fixtures) | — | — | **0.990–1.014×** |

Long-cell scan now runs at **21.7 GB/s** against 2.2 GB/s — this machine's single-core streaming
ceiling, so nothing further is available by unrolling.

**Attribution by in-fixture null control.** On the wide fixture the vector scan alone gives 0.843×
(first) / 0.797× (last); the early-out then adds 299.9 → 140.3 = **0.468×** when the match is in the
first column and 302.0 → 300.2 = **0.994×** when it is in the last. Same fixture, same build, same
query kind — only the match position differs, and the early-out can only help when the match is
early. The mechanism shows up precisely where predicted and nowhere else.

**Independent corroboration the implementer did not claim** (reviewer's): on narrow `floor` the
predicate is on column 2 and never matches, so `pfeed` is false for columns 0-1 and `primary_col` is
never set — the early-out contributes **exactly zero** there. That delta is therefore pure vector
scan: `203.4 − 117.9 = 85.5 ms` against the ablation's independently obtained 85 ms, and 42.0% against
the stated 42%. Two different methods agreeing to 0.5 ms.

## WHICH PATHS EACH NUMBER COVERS — the review's forced correction

`csv_reader` dispatches uniformly: `.mmap => <content-based lexer.*>` versus
`.gzip, .http_range => <cursor-based *Stream>` (`:263/285/307/327/388`), and the cursor family never
calls `findStructural`. **So the vector scan is unreachable for gzip and http_range on every path** —
bounds, materialize, selected, cell and match alike. Every figure in the table above describes a
**local uncompressed UTF-8 file**; a local `.csv.gz` or a network document gains nothing from the
vector half.

The **early-out half does cross over**, because it was applied to `matchCursor` too — and that was
measured, not assumed. Gzipped 2000-column fixture:

| local `.csv.gz`, 2000 cols | base | final | ratio |
|---|---|---|---|
| `search`, match FIRST col | 3242.7 | 2687.6 | **0.829×** |
| `search`, match LAST col (control) | 3275.4 | 3276.9 | 1.000× |
| `index_scan` (control) | 402.3 | 401.5 | 0.998× |

The flat control proves it in both directions: 17% on gzip from the early-out, and zero from the
vector scan, or `last` would have moved too.

Contrast worth keeping: the matcher cell before this one touched `StreamCell`/`Query`, which the
cursor family **does** use, so its ~4× reaches gzip and network. This cell's vector half does not.

## Correctness, verified rather than asserted

- **Terminator invariant preserved.** `findStructural` decides only *where a field ends*, never how a
  terminator is classified — both callers' classification code is untouched, so CRLF is still consumed
  whole by the caller. Left-to-right first-match holds: `firstTrue` returns the lowest set lane of the
  OR of three compares, and blocks are walked in increasing `i`.
- **`sep` aliasing CR or LF is genuinely safe**, not merely claimed: the splat `vsep` simply equals
  `vcr` and the OR is the same set — exactly how `findAny(&.{'\r','\r','\n'})` behaves.
- **No over-read.** The guard `hay.len - i >= structural_vec_len` is *exactly* the condition for
  `hay[i..][0..N]` to be in range, so `i + N <= hay.len` always; the tail loop resumes at the `i` the
  block loop left, with no gap and no overlap. The helper is pure — no state across calls, no retained
  pointer — and both callers consume the offset immediately in the same frame.
- **The early-out is sound at both row loops, including the filter side.** `primary_col` is only ever
  assigned under `if (primary_col == null …)`; `filter_ok` initialises to `filter_ctx == null` and is
  only ever assigned `true`. Both monotone. Critically a skipped cell's verdict is never read — which
  matters, because an **unfed `StreamCell` under an `.ne` predicate reports `matches() == true`**, so
  reading one would have been a live bug. Every `cur.advance` in `matchCursor`, including the
  escaped-quote `cur.advance(peek.src_len)`, is a sibling of the guarded feeds rather than inside them,
  so the cursor walk and `col` sequence are bit-identical with the flags off.

## The lock

`tools/fuzz/lexer_diff.zig` — total equivalence against the `std.mem.findAny` it replaced, **plus an
independent self-check that the returned offset really is the FIRST structural byte.** That second
part is the strongest thing about it: two implementations drifting *together* still fails, which a
pure differential oracle would miss. Hammers the block/tail seam: every length to 4 blocks+3, a needle
at every offset for all three needle bytes, every two-needle pair, dialects where `sep` aliases CR or
LF, and a dense/sparse random sweep. **Proven sensitive, 5/5 planted defects caught** — dropped CR
compare, `firstTrue`→`lastTrue`, stride+1, deleted tail, block-aligned offset.

The reviewer went looking for a sixth probe and concluded there isn't one worth adding: the only
genuinely dangerous variant is an over-read (`>= structural_vec_len - 1`), and that is *guaranteed*
caught without being planted, because the sweep walks every length from 0 to `block*4+3` so some input
always lands on the last partial block and the slice bound check panics.

## Findings, both on claim accuracy

**F1 — `findStructural`'s "every UTF-8 structural scan calls this" comment was false** for at least
four UTF-8-reachable scans: `csv_reader.scanUtf8Rows`, `lexer.scanToStructural` (via `recordBounds` /
`sniff.countFields`), `csv_reader.matchCursor`, and the `lexStream`/`cellStream`/`decodeColumn` family.
Narrowed to the accurate claim — *the two **byte-wise** UTF-8 structural scans call this* — with an
explicit map of what does **not** route through it, so the next cell inherits a map rather than a
slogan.

**F2 — the perf record needed its path scope stated**, above. The reviewer's original wording
("`.mmap` only") was itself slightly too strong, and the implementer corrected it **by measuring** the
gzip early-out rather than by arguing — the right move.

## Incidental find

The two replaced sites passed **different needle orders** — `{sep,'\r','\n'}` in `csv_reader` versus
`{sep,'\n','\r'}` in `lexer`. Immaterial, because `findAnyPos` iterates positions outer and values
inner so order cannot change the returned index. But it means the single-order oracle legitimately
covers both, and one helper makes the inconsistency undriftable.

## Filed forward, in priority order

1. **`matchCursor` FIRST** — a user's search over a local `.csv.gz` runs it and waits: **3.2 s on the
   wide fixture against 0.14 s for the same document uncompressed.** A UTF-8 fast path over the
   cursor's current span. *The orchestrator had recommended the index sweep first; the reviewer
   overruled that and was right — the index sweep is a background path no interactive budget depends
   on.*
2. **`scanToStructural`** — unit-wise for all encodings; a UTF-8 fast path applies.
3. **`scanUtf8Rows` LAST, for the correctness reason and not the methodological one.** It is
   quote-stateful, it owns "a terminator is consumed whole, or not at all", and its own comment records
   two **opposite-direction** silent miscounts a pending-LF flag once caused. Changing it needs an
   oracle over row **counts across span boundaries** — a different lock from the offset oracle built
   here, which would not catch a drifted count at all. That it also serves as the clean `index_scan`
   control is good methodology but is *not* a correctness argument.
4. **Scattered knob**: the unit-wise structural predicate `enc.unitIsByte(u, sep) or … '\r' or … '\n'`
   is re-expressed at **seven** sites (`lexer.zig:80,267`, `csv_reader.zig:534,933,991,1051,1207`).
   Predates this cell, which *reduced* byte-wise sites from two to one. Name it once when the UTF-8
   fast path lands.

## Process notes

- **Profiling before optimizing paid twice**: it redirected the work off a 2% target onto a 42% one,
  and it prevented shipping a "fix" that measured **+10.2%**.
- **An in-fixture null control beats a cross-fixture comparison.** Same fixture, same build, same
  query, only the match position moved — 0.468× vs 0.994× localises the mechanism in a way no
  before/after pair across two fixtures could.
- **The implementer overruled a reviewer finding by measuring it**, and was right to. F2's "`.mmap`
  only" was the reviewer reasoning correctly from dispatch code about the *vector* half and
  over-generalising to the whole cell.
