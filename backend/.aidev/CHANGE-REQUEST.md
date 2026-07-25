# Contract Change Request — security-hardening (sec_w2b) / two mutually-contradictory frozen test pairs

Signed:  [x] implementer   [ ] reviewer
(both required; the reviewer's signature also certifies the numbers below were independently re-checked)

## Grounds (tick at least one)
- [x] A. Infeasible within the current contract
- [ ] B. Substantial, quantified improvement

## Summary

Two independent, provable frozen-test contradictions block 3 of the 276 tests. Everything
else is implemented and GREEN (273/276; `zig fmt --check src/` clean; native +
aarch64-linux-musl + x86_64-linux-musl ReleaseSafe builds all exit 0). The 3 blocked tests
are `cp1` (item f), `sec_d1` and `sec_d1_net` (item d). Neither can be satisfied without a
frozen-test change (forbidden to the implementer), and for (d) the ARCH's core mechanism
premise is empirically false against std.compress.flate.

---

## Contradiction 1 — (f) copy neutralization: `cp1` vs `sec_f1` disagree on a leading `-`

**The two frozen tests cannot both pass.**

- `sec_f1` (AC-f1, `tests/all_tests.zig:9101`) REQUIRES a cell whose first byte is `-`
  to be neutralized in `ls_copy_next`: it copies `"-5"` and asserts `"'-5"`.
- `cp1` (`tests/all_tests.zig:8665`, golden `fv_full_tsv` at `tests/all_tests.zig:8649`)
  copies data row 3 of `fv_fixture` — whose qty cell is the negative number `"-3"`
  (`tests/all_tests.zig:2650`) — via the SAME `ls_copy_next` path, and asserts the golden
  line `"gadget\t-3\tNeedle point\n"` (RAW `-3`, no apostrophe).

The (f) contract (ARCH AC-f1, and `sec_f1`) is first-byte-only with NO number exception, so
`-3` MUST be neutralized to `'-3` exactly as `-5` -> `'-5`. `cp1`'s golden was not updated
when (f) was frozen.

### Attempts (>=2)
1. Neutralize at the single copy choke point `window.decodeCellAt` (covers `ls_cell_copy` +
   the `ls_copy_next` streaming sweep + the pinned record-1 path). Result: `sec_f1`, `sec_f2`,
   `sec_f3` all GREEN; `cp1` flips RED because `-3` -> `'-3`.
2. Restrict neutralization to `ls_cell_copy` only (not the streaming path). Rejected without
   coding: `sec_f1` explicitly drives `ls_copy_next` and asserts the streaming row
   `"'=SUM(A1)\t'+2+3\t'-5\t'@ref"`, so the streaming path MUST neutralize — which is exactly
   the path `cp1` exercises with `-3`. No placement resolves it.

### Failing gate output
```
error: 'all_tests.test.cp1: AC1 TSV framing byte-identical to TSVCopyBuilder ...' failed:
       (expected fv_full_tsv with "gadget\t-3\tNeedle point"; got "gadget\t'-3\tNeedle point")
```

### Minimal change (planner, frozen test)
`tests/all_tests.zig:8653` — update the `cp1` golden to reflect the (f) contract:
```
-    "gadget\t-3\tNeedle point\n" ++
+    "gadget\t'-3\tNeedle point\n" ++
```
Verified: `cp1` is the ONLY pre-existing copy golden that contains a trigger-leading
(`= + - @`) cell; all other copy tests (cc*, cp2, cp3, sc*, gzip copy) are byte-unaffected.

---

## Contradiction 2 — (d) gzip-bomb cap: `sec_d1`/`sec_d1_net` vs the legit high-expansion fixtures

**The ARCH premise "a sustained ratio cleanly separates a bomb from a legit large file
(text CSV <= ~20:1, bomb >> 100:1)" is empirically FALSE against std.compress.flate and the
suite's own fixtures. No sliding-window ratio floor can trip `sec_d1` while sparing the
frozen legit high-expansion gzip tests.**

### Measured compression ratios (std.compress.flate 0.16.0, the shipped compressor)
| fixture | test | required outcome | ratio |
|---|---|---|---|
| `gzHighExpansion("aaaa,bbbb,cccc\n", 8 MiB/15)` | **sec_d1** (bomb) | MUST trip | **514:1** |
| `gzHighExpansion("aaaa,bbbb,cccc\n", 80 MiB/15)` | **gz_ac17** (legit) | MUST fully scan | **514:1** |
| `gzHighExpansion("aaaa,bbbb\n", 135 / 48 / 16 MiB)` | gz_ac15/16/ac7 (legit) | MUST fully scan | 515:1 |
| `genNearCapRows(48)` (~0.94 MiB 'a'-runs) | **gzfs_*** (legit) | MUST fully scan | **1024:1** |
| 64 MiB of 0x00 / 'a' (degenerate zeros/single-byte bomb) | — | (a real bomb) | **~1030:1** |

Two independent proofs of infeasibility:
1. **`sec_d1` and `gz_ac17` use the byte-identical fixture pattern** —
   `gzHighExpansion("aaaa,bbbb,cccc\n", ...)`, same compressor — differing only in length
   (8 MiB vs 80 MiB). Their steady-state ratios are identical, so ANY guard that trips
   `sec_d1` also trips the legit `gz_ac17` (and vice-versa).
2. **Legit and bomb ratio ranges OVERLAP.** Legit CSV fixtures reach 1024:1 (`gzfs`), while
   the WORST std-flate bomb (all-zeros) tops out at only ~1030:1 (the LZ77 32 KB-window /
   258-byte-match ceiling). There is no floor between "every legit fixture" and "any bomb".

### Attempts (>=2)
1. Sliding-window sustained-ratio guard in `source.Gzip.produce` (window 1 MiB inflated,
   floor 100:1 per the ARCH). Result: `sec_d1`/`sec_d1_net` GREEN but SEVEN legit tests RED
   (gz_ac7, gz_ac15, gz_ac16, gz_ac17, gz_tail_eof, gzfs_filter, gzfs_search — all >= 514:1).
2. Raise the floor above the legit ceiling (measured max 1024:1 -> set 4096:1 currently
   shipped). Result: all legit tests GREEN, but `sec_d1`/`sec_d1_net` RED — the bomb fixture
   (514:1) is far below any floor that spares `gz_ac17` (514:1, identical shape). Against std
   gzip the guard is then effectively dormant (nothing reaches 4096:1).
   No intermediate floor exists: `sec_d1`=514 < `gz_ac15`=515 < `gzfs`=1024 < zeros-bomb=1030.

### Failing gate output
```
error: 'all_tests.test.sec_d1: ... trips the abnormal-expansion cap ...' failed: expected true, found false
error: 'all_tests.test.sec_d1_net: ...' failed: expected true, found false
```

### Proposed resolution (ARCHITECT + planner — touches ARCH Technology Decision 3)
The guard MECHANISM is implemented (single knob `base.gz_expansion_ratio_max`, sliding
window, `ScanProgress.expansion_capped` plumbed through `source.expansionCapped` ->
`index.indexPoll`; `sec_d2` false-positive guard GREEN). What cannot hold is the ratio
SEPARATION. Options for the architect:
- **(a)** Change the `sec_d1`/`sec_d1_net` bomb fixtures to a pattern whose ratio genuinely
  exceeds the legit ceiling — but std flate's ceiling (~1030:1) is only ~6% above `gzfs`
  (1024:1), so any workable floor is razor-thin and fragile against legit uniform CSV.
- **(b)** Replace/augment the pure ratio with an ABSOLUTE inflated-work bound (e.g. cap
  forward inflation beyond the served viewport at N bytes) — the ARCH explicitly REJECTED an
  absolute cap; this reverses that decision. NOTE both `sec_d1` and `gz_ac17` issue an
  explicit `scanToEnd` (full-scan demand), so even a demand-gated work cap cannot distinguish
  them — the two documents are indistinguishable by any signal available to the core.
- **(c)** Accept gzip work-amplification as a known risk (memory is already O(viewport); the
  residual is CPU) and drop the (d) [gate] ACs to [bench]/reviewer, per AC-d3's own
  "finalized by bench against real CSV ratios" caveat.

---

## Cost / blast radius
- (f): 1-line change to `tests/all_tests.zig:8653` (`cp1` golden). No src/ or api/ change; the
  implemented neutralization already satisfies `sec_f1`/`sec_f2`/`sec_f3`.
- (d): `sec_d1`/`sec_d1_net` fixture and/or ARCH Decision 3 + AC-d1 tagging. The implemented
  guard + plumbing stay; only the fixture/floor/mechanism decision is the architect's.
- Changes EXTERNAL I/O?   [x] no  (api/lesssheet.h is byte-identical; both are test/ARCH changes)
  — but (d) touches a SIGNED architecture decision, so it goes to the ARCHITECT + human before
  the planner applies any test/ARCH change.

## Current implemented state (all feasible work done)
- (e) network hardening: `sec_e2` (https->http downgrade refused via the pure
  `net_source.redirectDowngrades` seam), `sec_e3` (short body at open -> SHORT_BODY),
  `sec_e3_post_open` (post-open short range does not advance the frontier / no zero-fill /
  no spin) — all GREEN. Real-transport connect timeout + downgrade check wired (human probe).
- (f) mechanism: `sec_f1`/`sec_f2`/`sec_f3` GREEN (single choke point `window.decodeCellAt`).
- (d) mechanism: implemented; `sec_d2` false-positive guard GREEN; only `sec_d1`/`sec_d1_net`
  blocked as above.
- 273/276 GREEN, `zig fmt --check src/` clean, native + aarch64/x86_64-linux-musl ReleaseSafe
  builds all exit 0.

---

## Adjudication — APPROVED (backend planner, 2026-07-25)

**Verdict: APPROVED.** Full record: `.aidev/DECISION-2.md`.
Authority: the signed **ARCH-security-hardening amendment (2026-07-24) + the author sign-off** for the
architecture-touching parts (d)/(e); grounds **A (infeasible within the current contract)** for the
(f) `cp1`-vs-`sec_f1` frozen-test contradiction. (d) and (e) touch a signed architecture decision, so
they were bounced to the architect + human and are applied here only because the ARCH was amended in
place and signed off.

Resolution of the three blocked tests:

- **(f) — NUMBER-AWARE (contradiction dissolved in `cp1`'s favor).** A leading `=`/`@` is always
  neutralized; a leading `+`/`-` only when the cell is NOT a plain number (grammar per AC-f1 /
  api/lesssheet.h COPY OUTPUT SAFETY). The requested `cp1` golden edit (`-3` → `'-3`) is **NOT made** —
  raw `-3` is correct. `sec_f1`/`sec_f2` re-frozen number-aware (`+`/`-` trigger cases switched to
  non-numbers `+cmd`/`-1+1` + grammar edges; plain-number cases assert RAW); `sec_f3` unchanged.
- **(d) — WITHDRAWN (accepted known risk).** The ratio-cap mechanism is dropped (ARCH Decision 3
  reversed). `sec_d1`/`sec_d1_net`/`sec_d2` are **retired** (they read the removed
  `ScanProgress.expansion_capped` field, already deleted in the root `api/` re-freeze). The dormant
  guard plumbing in `src/` is the implementer's to remove next (convergence-plan step 3).
- **(e) — CONNECT-TIMEOUT-ONLY for v1.** Idle-read timeout deferred (no Zig-0.16 std per-read hook);
  confirmed NO frozen test asserts an idle-read timeout. `sec_e2`/`sec_e3`/`sec_e3_post_open` stand.

Applied to `tests/all_tests.zig` only; `contracts/api.zig` was already converged by the root re-freeze
(no planner edit). Re-frozen. The tree stays non-compiling until the implementer strips the dead (d)
`src/` plumbing and implements number-aware copy.

### What evidence would have changed the (d) verdict
Only a bomb/legit SEPARATION signal available to the core — a compression-ratio floor, or any other
in-core signal, that trips every constructible bomb while sparing every legitimate highly-compressible
CSV. The CR bench showed the ranges overlap (`sec_d1`=514:1 < `gz_ac15`=515:1 < `gzfs`=1024:1 <
zeros-bomb≈1030:1) and that the bomb/legit fixtures are byte-identical shapes both issuing a full
`scanToEnd`, so no such signal exists against `std.compress.flate`; absent one, the accepted-risk
reversal (memory O(viewport), CPU cancellable) stands.
