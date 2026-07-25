# DECISION-2 — backend — CHANGE-REQUEST `sec_w2b`: two frozen-test contradictions + one std limitation (security-hardening d/e/f)

**Verdict: APPROVED.** Date: 2026-07-25.
Authority: the **signed ARCH-security-hardening amendment (2026-07-24) + the author sign-off** (the
architecture-touching parts (d)/(e)), and grounds **A — infeasible within the current contract** (the
(f) `cp1`-vs-`sec_f1` frozen-test contradiction). Applied by the backend planner as convergence-plan
step 2.

## The claim (from `.aidev/CHANGE-REQUEST.md`, cell `sec_w2b`)

Three of 276 tests were blocked with no implementer-side fix:

1. **(f) contradiction** — `cp1` (golden `fv_full_tsv`, copies `fv_fixture` row 3 whose qty is the
   negative number `-3` through `ls_copy_next`, asserting RAW `-3`) and the old `sec_f1` (copies
   `-5` through the SAME streaming path, asserting `'-5`) cannot both pass under a first-byte-only
   `=+-@` neutralization rule. Two placement attempts documented; no placement resolves it.
2. **(d) infeasibility** — no sliding-window expansion-ratio floor can trip `sec_d1`/`sec_d1_net`
   (bomb fixture 514:1) while sparing the legit high-expansion gz fixtures (`gz_ac15` 515:1 …
   `gzfs` 1024:1), and the worst constructible `std.compress.flate` bomb tops ~1030:1 — the ranges
   overlap with no usable floor; `sec_d1` and `gz_ac17` are byte-identical fixture shapes; both
   issue a full `scanToEnd`, so no work-cap distinguishes them either. Measured, two attempts.
3. **(e)** — idle-read timeout has no Zig-0.16 `std.http.Client` hook (connect timeout only).

(d) and (e) touch **signed architecture** (Technology Decision 3; the timeout policy), so the
planner does not decide them unilaterally — they were bounced to the architect + human. The ARCH was
amended in place on 2026-07-24 (Decision 3 REVERSED to accepted-known-risk; idle-read DEFERRED) and
the author signed off. This decision applies that signed outcome and resolves the (f) contradiction in
`cp1`'s favor (number-aware neutralization), exactly as the amendment's "Amendment consequence, for
the backend planner" and "Amendment convergence plan step 2" direct.

## Planner verification (by inspection — the tree is transiently non-compiling; no build run)

- **(f) grammar matches the frozen contract VERBATIM.** The reworked `sec_f1`/`sec_f2` assertions are
  taken directly from `api/lesssheet.h` COPY OUTPUT SAFETY (root-frozen, commit `2b06e5c`):
  RAW `-3, +2.5, -0.5, +1e9, -2.5E-3` (and `-5`, `-1.5e3`); NEUTRALIZED `=SUM(A1), @ref, +cmd,
  -1+1, -.5, -3., -1,000, --3, -3e, "-3 " (trailing space), bare +/-`. The grammar pinned is
  `digit+ ( "." digit+ )? ( ("e"|"E") ("+"|"-")? digit+ )?` after one leading sign, whole-value,
  ASCII, no whitespace/separator/bare-or-trailing-dot/second-sign/trailing bytes; fail-safe =
  over-neutralize.
- **The trailing-space edge (`-3 ` → `'-3 `) is testable.** The CSV lex/window/copy serving path
  does NO whitespace trimming (grep of `src/`: `trimAscii` is column-TYPE inference only;
  `net_source` trims HTTP headers; `matcher` trims for NUMERIC PREDICATE compare — none touch the
  raw bytes `ls_cell_copy` serves). The frozen contract itself (api/lesssheet.h) explicitly notes
  this copy grammar is deliberately STRICTER than the header/matcher numeric grammar and must not
  reuse it. So a trailing-space cell is preserved and neutralized.
- **`cp1` golden UNCHANGED** — `tests/all_tests.zig:8653` still `"gadget\t-3\tNeedle point\n"`; raw
  `-3` is correct under the number-aware rule (the CR's requested `cp1` golden edit is NO LONGER
  needed and was NOT made).
- **(d) retirement is complete on the test side** — the removed tests were the ONLY code-level
  readers of `ScanProgress.expansion_capped` (root already removed the field); `sec_d2` could not
  outlive the field. `gzHighExpansion` stays (8 legit gz tests still use it); no bomb-only
  `NetFixture` helper existed (its `redirect_downgrade`/`short_body_at` serve (e)).
- **(e)** — confirmed NO frozen test asserts an idle-read timeout (the net suite covers connect
  fault → `.timeout`, `redirect_downgrade` → `insecure_redirect`, `short_body_at` → `short_body`).
- `zig fmt --check tests/all_tests.zig` passes (well-formed + canonically formatted); top-level test
  count 276 → 273.

## Resolution applied (`tests/all_tests.zig` only)

- **Retired** `sec_d1`, `sec_d1_net`, `sec_d2` (gzip-bomb cap withdrawn — accepted known risk).
- **Reworked** `sec_f1` and `sec_f2` to the number-aware AC-f1 grammar: `=`/`@` always neutralized;
  non-number `+`/`-` neutralized (`+cmd`, `-1+1`, and the grammar edges above); plain numbers copy
  RAW; byte-exactness + `ls_cell_copy` + `ls_copy_next` + orthogonal-to-quoting coverage kept; the
  streaming RAW-number row (`-5\t+2.5\t-1.5e3\t-3`) is the load-bearing regression guard that pins
  the exact path `cp1` exercises with `-3`.
- **Kept** `sec_f3` (display/search/filter see the RAW cell) unchanged; **kept** `cp1` unchanged.
- Rewrote the Wave-2b comment block to document the amendment ((d) withdrawn, (f) number-aware, (e)
  connect-timeout-only).

## Blast radius

- `backend/tests/all_tests.zig`: comment block + 3 tests removed + `sec_f1`/`sec_f2` reworked; every
  other test byte-unaffected.
- `backend/contracts/api.zig`: **no planner edit** — already converged by the root `api/` re-freeze
  (`ScanProgress` has no `expansion_capped`; `CopyResult` prose is number-aware).
- `api/lesssheet.h` + macOS AC23 guard baseline: **root planner's domain** (converged, `2b06e5c`);
  outside this component's scope.
- `src/`: **no planner change.** The tree stays NON-COMPILING until the implementer strips the dead
  (d) plumbing (`gz_expansion_ratio_max`, the `source.Gzip.produce` guard, `source.expansionCapped`,
  the removed-field ABI plumbing) and makes the single copy choke point number-aware per AC-f1
  (convergence-plan step 3) — the next dispatch.
- External I/O: none introduced by this decision.

Snapshot re-frozen via `bash ~/.claude/aidev/freeze.sh backend` after this convergence. The git
anti-tamper layer flags the uncommitted frozen-path drift (`contracts/api.zig` from root +
`tests/all_tests.zig` from here) until the orchestrator commits it (expected).
