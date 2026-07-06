# Contract Change Request — viewer-ui / test `c2: a candidate that splits consistently beats single-field candidates` @ backend/tests/all_tests.zig:416

Signed:  [x] implementer   [x] reviewer
(both required; the reviewer's signature also certifies the numbers below were independently re-checked)

## Grounds (tick at least one)
- [x] A. Infeasible within the current contract
- [ ] B. Substantial, quantified improvement

## If A — infeasibility

**Summary.** One frozen behavior test (`c2` splits, line 412-417) is unsatisfiable
*together with* the frozen numeric header grammar that the rest of the suite pins.
No implementation can make all 49 tests pass. 48/49 pass with a grammar-correct core;
the lone failure is line 416.

The test:
```zig
var od = try openBytes("x;y\nz;w\n");                 // line 413
try std.testing.expectEqual(@as(u8, ';'), api.ls_dialect_get(od.doc).separator);  // 415 — PASSES (sniffs ';')
try expectDims(od.doc, 2, 2);                          // 416 — expects 2 DATA rows, 2 cols
```
`expectDims(doc, data_rows, cols)` (line 95) asserts `ls_row_count_get(doc).count == data_rows`.
Row counts exclude the header record (api/lesssheet.h: "record 1 ... is EXCLUDED from
data-row addressing and row counts"). `"x;y\nz;w\n"` is **2 records**. So `count == 2`
requires **header OFF** (both records are data). But the frozen HEADER RULE
(api/lesssheet.h lines 145-156; ARCH criterion 3) is numeric-only:

> Record 1 is the header UNLESS every cell of record 1 (under the effective dialect) is numeric.

Record 1 under the (correctly sniffed) `;` dialect is `["x","y"]` — neither cell numeric —
so the grammar makes record 1 the **header** ⇒ 1 data row (`"z;w"`) ⇒ `count == 1`.
Hence `expected 2, found 1`.

- Attempts (≥2), each with the specific reason it failed under the current signature:
  1. **Grammar-correct header (implemented, shipping).** `has_header = !allNumeric(record1)`.
     `"x;y\nz;w"` → record1 non-numeric → header ON → 1 data row → line 416 fails
     (`expected 2, found 1`). This is the ONLY reading consistent with api/lesssheet.h and
     with the *other* header tests (see below). Result: **48/49**.
  2. **Any rule that makes `"x;y\nz;w"` header-OFF** (e.g. "header only when row 1 differs
     in type/length from later rows", Python-`csv.Sniffer`-style; or "identical field
     counts ⇒ data"; or "non-default sniffed separator ⇒ no header"). Each such rule was
     checked against the suite and **breaks a *different* frozen test**, because
     `"x;y\nz;w"` is structurally indistinguishable from files the suite pins as header-ON:
       - `c5` (line 786-790) asserts `header == true` **explicitly** and `expectDims(1,2)`
         for `"\"x,y\",q\n\"line1\nline2\",w\n"` — also a **2-record, all-non-numeric**
         document. A rule making `"x;y\nz;w"` header-OFF makes this header-OFF too → c5 fails.
       - `c2` no-structure (line 395-403): `"a\nb\nc\n"` — all-short-text, `expectDims(2,1)`
         (2 data rows of 3 records ⇒ header ON). Any length/type/"identical-rows" rule that
         drops the header here yields 3 data rows → fails.
       - `buildSniffFixture` with a sniffed non-comma separator (`;`, TAB, `|`) — `expectDims(4,3)`
         (header ON) → a "non-default sep ⇒ no header" rule fails these.
     There is no content-, shape-, quote-, or separator-based rule that yields
     `{a\nb\nc: ON, c5: ON, buildSniffFixture: ON, "x;y\nz;w": OFF}`; the first three and the
     fourth are the same case (non-numeric record 1) with opposite required outcomes.

- Failing gate / compiler / type-checker output (with the numeric grammar implemented):
```
GATE: conformance -> zig build            # PASSES
GATE: behavior -> zig build test
error: 'all_tests.test.c2: a candidate that splits consistently beats single-field candidates' failed:
       expected 2, found 1
       backend/tests/all_tests.zig:416:5 in test ... (expectDims(od.doc, 2, 2))
Build Summary: 1/3 steps succeeded (1 failed); 48/49 tests passed (1 failed)
GATE: FAIL — behavior tests failed.
```
Probe of the shipping core for the two fixtures (identical grammar outcome):
```
"x;y\nz;w\n"                     -> sep=; cols=2 header=true total=1   (this test wants total=2)
"\"x,y\",q\n\"line1\nline2\",w\n" -> sep=, cols=2 header=true total=1   (c5 line 790 wants exactly this)
```

## Minimal change (as a diff)

The test's *intent* (sniffer prefers a splitting separator `;` over the single-field `,`)
is fully exercised by lines 413 & 415; the dims assertion just needs to match the grammar
that makes `"x;y"` the header. The fixture has exactly **1 data row** (`"z;w"`) under `;`.

```diff
--- a/backend/tests/all_tests.zig
+++ b/backend/tests/all_tests.zig
@@ test "c2: a candidate that splits consistently beats single-field candidates"
     try std.testing.expectEqual(@as(u8, ';'), api.ls_dialect_get(od.doc).separator);
-    try expectDims(od.doc, 2, 2);
+    try expectDims(od.doc, 1, 2);   // "x;y" is the sniffed header (non-numeric row 1); 1 data row "z;w"
```

Equivalent alternative (planner's choice) if the author wants a genuinely-2-data-row
fixture: change the fixture so record 1 is all-numeric (header off), e.g.
`openBytes("1;2\n3;4\n")` with `expectDims(2,2)` — still demonstrates `;` beats `,`.
(No core change either way; the shipping core already satisfies both.)

## Cost / blast radius
- Other contract items / tests / modules affected: **none.** api/lesssheet.h and
  backend/contracts/api.zig are unchanged (no signature/type/semantic change). Only this
  one test's dims constant is corrected. The other 48 tests are unaffected and already pass.
- The Swift/frontend side is unaffected (this is a Zig-core behavior test only).
- Changes EXTERNAL I/O?   [x] no    [ ] yes → this goes to the ARCHITECT, not the planner.

---

## Reviewer verification (second key) — 2026-07-06

Co-signed: grounds A confirmed by independent re-derivation and measurement. Verification was
adversarial and did not rely on the implementer's numbers:

1. **Re-derived the contradiction from the frozen artifacts.** Line 415 pins sep=`;` for
   `"x;y\nz;w\n"` (2 records; no quote candidate byte occurs, so no dialect reading alters record 1
   = `["x","y"]`). api/lesssheet.h HEADER RULE (numeric-only, pinned grammar) ⇒ header ON;
   "EXCLUDED from ... row counts" ⇒ count == 1. `expectDims` (tests line 95) asserts count == 2.
   Unsatisfiable under the frozen semantics.
2. **Re-ran the numbers myself.** Gate run by reviewer: 48/49, sole failure all_tests.zig:416
   `expected 2, found 1` — reproduced on 3 runs / 3 seeds. Independent C-ABI probe (compiled from
   api/lesssheet.h against the built liblesssheet.a, /tmp/lsprobe) reproduces the implementer's
   probe table exactly:
   `x;y\nz;w\n → sep=; cols=2 header=true count=1` · c5 fixture `→ sep=, cols=2 header=true count=1`
   (the frozen c5 test at lines 786-790 demands exactly this for the structurally identical case).
   Forcing header OFF is the only configuration producing count=2, and the test does not force it.
3. **Adversarial reconciliation attempt (beyond the implementer's attempt list).** I constructed a
   contrived header rule that passes all 49 test assertions ("header OFF iff separator sniffed AND
   ≥2 cols AND no quoted field in the head AND record 2 not all-numeric; else the pinned grammar").
   It is rejected as a resolution: it violates the frozen normative text of api/lesssheet.h
   (HEADER RULE / LS_SNIFF = "apply the grammar") and ARCH criterion 3, i.e. it is test-gaming, not
   an implementation within the contract. Therefore the defect is in the frozen test, not solvable
   in code: `[contract]` is the correct tag. (Note: the CR's claim that *no* suite-threading rule
   exists is overstated — one exists but is contract-illegal; the conclusion is unaffected.)
4. **Fix check.** Either proposed repair is consistent with the grammar and keeps the test's
   sniffing intent (line 415 untouched): `expectDims(od.doc, 1, 2)`, or fixture `"1;2\n3;4\n"` with
   `expectDims(od.doc, 2, 2)` — probe-verified on the shipping core (`sep=; header=false count=2`).
   Blast radius "none" verified: no change to api/lesssheet.h, contracts/api.zig, or any other
   test; no external I/O change.

Full review: review/REVIEW-5-backend.md (verdict PASS absent the disputed test).
