# DECISION-1 — viewer-ui / backend — CHANGE-REQUEST: test `c2: a candidate that splits consistently beats single-field candidates`

**Verdict: APPROVED** (grounds A — infeasible within the current contract).
Date: 2026-07-06. Keys: implementer + reviewer (review/REVIEW-5-backend.md), adjudicated by planner.

## The claim

Frozen test at `backend/tests/all_tests.zig:416` — `expectDims(od.doc, 2, 2)` on fixture
`"x;y\nz;w\n"` opened with all-LS_SNIFF — is unsatisfiable together with the frozen HEADER RULE
and row-count rule of `api/lesssheet.h`. No implementation can pass all 49 behavior tests;
a grammar-correct core scores 48/49 with this single failure.

## Planner's independent verification (from the frozen artifacts, then measured)

1. The fixture contains no quote-candidate byte, so no dialect reading alters record 1; two LF
   terminators + "a terminator after the last record does not add a record" give exactly
   2 records.
2. Frozen line 415 itself pins `separator == ';'` (and the pinned sniff outcome — a splitting
   candidate beats single-field candidates — independently forces `;`, the only candidate byte
   present). Record 1 = `["x","y"]`.
3. Header is not forced (all-LS_SNIFF); `LS_SNIFF` for header is normatively "apply the grammar".
   HEADER RULE: record 1 is the header UNLESS every cell is numeric; `"x"` cannot match the pinned
   numeric grammar `sign? (digits ('.' digits?)? | '.' digits) (('e'|'E') sign? digits)?` — header ON.
4. Header ON ⇒ record 1 "is EXCLUDED from data-row addressing and row counts" ⇒ count = 1; the
   file is under LS_OPEN_HEAD_MAX_BYTES ⇒ count exact at open (both index modes).
5. `expectDims` (tests line ~95) asserts `count == 2`. 1 ≠ 2 — unsatisfiable. Reproduced
   first-hand pre-repair: `zig build test` → 48/49, sole failure `all_tests.zig:416`
   `expected 2, found 1` (planner seed 0x1e36be2d; reviewer had 3 further seeds + C-ABI probes).

The one known suite-threading implementation (reviewer's adversarial construction: "header OFF iff
separator sniffed AND ≥2 cols AND no quoted field in head AND record 2 not all-numeric; else the
grammar") is REJECTED as a legitimate reading: under LS_SNIFF the header decision IS the pinned
grammar; that rule falsifies the normative text of api/lesssheet.h regardless of which assertions
it threads, and misclassifies real files (`name;age\nalice;30` would lose its header). The suite
corroborates the grammar, not the outlier: c5 (~line 786) pins `header == true` + `expectDims(1, 2)`
for a structurally identical 2-record non-numeric document, and the no-structure test (~line 395)
pins `expectDims(2, 1)` for `"a\nb\nc\n"`. Line 416's `2` was an isolated wrong constant in the
frozen tests — a contract defect, not an implementation defect.

## Chosen repair (and why this one)

Of the two repairs in the CR, I chose the **fixture change**, not the constant change:

```zig
// before:  var od = try openBytes("x;y\nz;w\n");  ...  try expectDims(od.doc, 2, 2);
// after:   var od = try openBytes("1;2\n3;4\n");  ...  try expectDims(od.doc, 2, 2);
```

Rationale: the test's declared intent is SNIFFER preference (its name; the load-bearing assertion
`separator == ';'` is untouched). With an all-numeric record 1 the header is OFF by the grammar, so
`expectDims(2, 2)` reads purely as "the winning candidate split the document into a 2×2 data grid" —
orthogonal to header semantics, which keep their own dedicated pins (c3 block, c5, no-structure).
This preserves the original author's evident intent of two visible data rows, whereas amending the
constant to `(1, 2)` would make a sniffer test's expectation depend on the header rule. Sniffing is
unaffected by the fixture change: `;` remains the only candidate byte present and splits both
records into 2 consistent fields. Coverage of "sniff `;` on non-numeric text" is retained elsewhere
(forced-quote test `"a;b\nc;d\n"` asserts sep `;`; buildSniffFixture sweeps all candidate pairs).
An explanatory comment referencing this decision was added at the test site.

## Blast radius

- `backend/tests/all_tests.zig`: this one test block only (fixture bytes + comment; assertions
  unchanged in form).
- `api/lesssheet.h`, `backend/contracts/api.zig`: **unchanged** — no type, signature, or semantic
  change; the header grammar stands exactly as frozen.
- Other 48 tests: untouched and green. Frontend (apps/macos): unaffected (Zig-core behavior test only).
- External I/O: none (no architect escalation required).
- Core implementation: no change required or made; the shipping core passes the repaired suite as-is.

Snapshot re-frozen via `bash backend/.aidev/freeze.sh backend` after the amendment. The git
anti-tamper layer flags the uncommitted frozen-path drift until the orchestrator commits this
amendment (expected).
