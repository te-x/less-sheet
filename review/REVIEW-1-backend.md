# REVIEW-1 — csv-hardening (backend / Zig core), round 1

## Verdict: PASS

Gate `bash backend/.aidev/gate.sh backend` → **GATE: PASS** (conformance: `zig build`
under zig 0.16.0; behavior: `zig build test`). Direct `zig build test` re-run: all
**92 tests green**, including the frozen h1–h17 (+h13b) csv-hardening behavior tests
and all 74 pre-existing viewer-ui/find-seek tests. Full build+test wall clock ~8.8 s.
Frozen paths untouched: `git diff HEAD` shows only `backend/src/root.zig` changed
(nothing under `backend/contracts/`, `backend/tests/`, or `api/`).

The behavior green is real, not gamed: the decoder is a genuine per-code-unit
`decodeUnit` fused into `recordBounds`/`countFields`/`lexInto`; there is no
test-fixture special-casing. Encoding detection, the cap, bounded record-1, and
full-cell search are all driven by the same production code paths the tests exercise.

No `[impl]` blockers and no `[contract]` defects. One low-severity `[impl]`
OBSERVATION is recorded below (does not block; no acceptance criterion is violated).

## What I verified (beyond "tests pass")

- **Detection pipeline order** (`resolveEncoding`, root.zig:333) matches the frozen
  order exactly: forced-bypass → BOM (EF BB BF / FF FE / FE FF) → NUL-ratio → lenient
  UTF-8 validate → Latin-1. Forced encoding still strips a matching BOM
  (`matchingBomLen`, :267).
- **Lenient UTF-8 validation** (`looksLikeUtf8`, :283): a multibyte sequence merely
  cut by the sample boundary passes (every available byte a plausible continuation);
  a genuine bad lead/continuation/overlong/surrogate fails. Confirmed the Latin-1
  `caf\xE9\n` case falls through to Latin-1 (0xE9 followed by 0x0A is not a valid
  continuation → returns false), matching h4.
- **NUL-ratio LE/BE parity** (`detectUtf16NulRatio`, :304): odd-offset NULs → LE,
  even-offset → BE, thresholds 0.70/0.10, requires ≥8 bytes — symmetric, matches h3.
- **Latin-1 maps all 256** (`decodeLatin1Unit`, :1112, never U+FFFD); **CP1252 five
  undefined bytes → U+FFFD** (`windows1252_high` table :1122 has 0xFFFD at indices
  0x01,0x0D,0x0F,0x10,0x1D = bytes 0x81/0x8D/0x8F/0x90/0x9D); **UTF-16 surrogate
  handling** (`decodeUtf16Unit`, :1142): valid pairs decode, lone/dangling surrogates
  → U+FFFD, a high surrogate short of `limit` defers (null) only when `limit` is not
  the true content end (correct windowed vs. genuine-dangling distinction).
- **Option A pass-through** (`decodeUtf8PassthroughUnit`, :1174): UTF-8 is byte-for-byte,
  never validated/rewritten; invalid 0xFF survives in a non-truncated cell (h7). The
  cap fix-up (`utf8TrimToBoundary`, :1196) only runs on a truncated field and only
  removes an incomplete trailing sequence — never rewrites interior bytes.
- **Cap at code-point boundary** (`storeCapped`, :1329): whole-unit atomic append,
  so non-UTF-8 encodings can never split a code point; UTF-8's byte-wise store is
  corrected once per truncated field. Verified the h13 arithmetic (4095 'a' + 2-byte
  'é' straddling 4096 → served 4095, flag true; exact-fit 4096 → whole, flag false).
- **O(head)/O(viewport) / streaming transcode**: `content` stays SOURCE bytes;
  `decodeUnit` transcodes only visited bytes; no whole-file transcode buffer exists.
  `headSourceLimit` (:514) bounds record-1 decode and `headScan` to the budget minus
  BOM; detection reads only a 256 KiB sample. `bytes_scanned = bom_len + frontier_offset`
  stays ≤ budget. The h9 (1 GiB sparse Latin-1 + UTF-16) and h14 (256 MiB sparse
  unterminated record 1) tests assert `<500 ms` open and `bytes_scanned ≤ head budget`
  — these are the implementer's own perf claims and I re-ran them green via the gate
  and a direct `zig build test`. h17 asserts `ls_window_set` over 200 oversized rows
  `<100 ms` with the frontier untouched — green. These embedded measurements are the
  measurement of the non-functional targets; all comfortably inside budget.
- **Full-cell search vs. display cap**: search/nav lex with `cap = null`
  (searchScanChunk :1947, relexBlock :2039, forward-nav :2094) into per-row-cleared
  scratch (`clearRetainingCapacity` each row, :1943/:2036) — full cell seen, working
  memory O(one row) not O(chunk); block counts stay O(checkpoints) (`block_counts`,
  commitSearch :1979). Window path uses `cap = 4096` (:910). h15/h16 confirm a match
  and a byte-exact predicate past the 4 KiB cap; a value equal only to the capped
  prefix does NOT match. Coherent with the contract's Option-A byte-level rule.
- **Bounded record-1 (header off)**: `buildShape` (:529) pins the capped decode in
  `row0_pinned_*`, served directly by `ls_window_set` (:876) so row 0 is instant and
  the frontier never claims a row of unknown extent; freed on close (freeDoc :631).
  Column count = fields decoded in budget (≥1), last field truncated+flagged (h14).
- **Memory / leaks**: no buffer scales with file size; new `row0_pinned_buf/refs`
  freed in `freeDoc`. The testing allocator (leak-checking) plus the c4
  CountingAllocator path are green, so the new allocations do not leak and the
  zero-alloc accessor guarantee (incl. the new `ls_cell_truncated` /
  `ls_header_cell_truncated`) holds.
- **Regressions**: sniffing/header/numeric grammar operate on decoded units;
  ASCII-structural bytes are unaffected (h12 proves identical dialect/header/column
  outcomes across UTF-8 / UTF-16LE / Latin-1). All carried-over tests pass.

## Findings

1. `[impl]` — LOW / non-blocking (no acceptance criterion violated). **Bounded
   record-1 combined with an effective header ON is under-defined and yields spurious
   data rows.** In `buildShape` (root.zig:554–566), when `record1_capped` AND
   `has_header`, `data_start` is set to `res.next` (== the head-budget `limit`), which
   lands in the MIDDLE of the giant unterminated record-1/header field. The background
   worker (`scanChunk`/`recordBounds` from `frontier_offset == limit`, :756/:764) then
   lexes forward from mid-field with no quote context and manufactures bogus "data
   rows" out of header-field fragments (and, for a sparse-NUL tail, one row spanning to
   EOF). This branch is reachable on the DEFAULT auto path: a >4 MiB first line with no
   newline that is non-numeric sniffs header ON (h14 sidesteps it by forcing
   `header_off`). It does not crash, leak, block open, or break O(head) cold-start —
   open still returns fast and the worker runs in the background — and the frozen
   contract does not pin data-row semantics for this degenerate case, so all of
   criteria 9/14 are met. Recommend (within the contract) treating a capped record-1
   whose effective record is the header as 0 data rows (e.g. set `complete = true`,
   `total_rows = 0`, and do not advance the frontier past `limit`), so the file reads
   as a lone giant (capped) header rather than emitting header fragments as data.
   Confirm by opening (auto options) a file whose first line is a single >4 MiB
   non-numeric unquoted field with no terminator, then a data-ish tail, and checking
   `ls_row_count_get` / `ls_cell` do not surface mid-field fragments.

No `[contract]` findings: everything required by ARC criteria 1–17 is satisfiable and
satisfied within the frozen `api/lesssheet.h` + `contracts/api.zig`; the one wart above
is fixable purely in `src/`.

---

# ROUND 2 — verification of the Finding-1 fix

## Verdict: PASS

Gate `bash backend/.aidev/gate.sh backend` → **GATE: PASS**, **92/92** tests green
(`zig build` under zig 0.16.0 + `zig build test`). `git diff HEAD --name-only` for
`backend/contracts`, `backend/tests`, `api` is empty — frozen paths untouched; only
`backend/src/root.zig` changed.

### 1. The change is exactly as specified, scoped to root.zig
New branch in `openWithAllocator` right after the base checkpoint (root.zig:486–499):
`if (doc.has_header and doc.record1_capped) { doc.complete = true; doc.total_rows = 0; }`
(skipping `headScan`) `else { doc.complete = false; headScan(doc); }`. `frontier_offset`
was already set to `doc.data_start` at :485, so it stays pinned at the budget cut. No new
allocations. `buildShape` is byte-identical to round 1.

### 2. The fix is correct
- Capped-header path now reports **0 data rows, exact** (`complete=true`, `total_rows=0`);
  `ls_row_count_get` returns `{0, true}` and `ls_index_poll.complete=true`.
- The AUTO worker cannot manufacture rows: `do_jump`/`do_index` are both gated on
  `!doc.complete` (root.zig:663–665) and no search is active at open, so the worker
  parks and never lexes the still-open header field's tail.
- `bytes_scanned = bom_len + frontier_offset = bom_len + data_start`. In the capped-header
  case `data_start == res.next == headSourceLimit(doc) == min(head_budget - bom_len,
  content.len)`, so `bytes_scanned == bom_len + min(budget - bom_len, content.len)
  ≤ LS_OPEN_HEAD_MAX_BYTES`. Never advances past the budget.

### 3. No regression on the other cases
- `record1_capped = res.capped` (buildShape :556) is set ONLY when record 1 hit the
  budget without terminating (`lexInto` returns `capped = limit != content.len` on the
  hit_limit branch; `false` on normal termination at :1478). A normal file smaller than
  the budget has `lim == content.len` → `capped=false`; a large file whose record 1 is
  normal-sized terminates before the limit → `capped=false`. No false flagging, so no
  file is wrongly forced to 0 rows.
- Capped + header OFF (h14's forced path): `has_header=false` → `else` branch →
  `headScan` (which breaks immediately on the capped record 1); `data_start=0`, pinned
  row0 still served as data row 0. Green.
- Normal (non-capped) opens: `else` branch → `headScan`/index unchanged. All 74
  carried-over tests plus h1–h17/h13b green.

### 4. Gate
`bash backend/.aidev/gate.sh backend` → **GATE: PASS**, 92/92 (re-run independently).

**Finding 1 from round 1 is resolved. No new findings. No open `[impl]` or
`[contract]` items.**
