# REVIEW-5 — backend (Zig core), feature viewer-ui

Scope: backend cell only (parallel-cell policy; apps/macos reviewed separately; root gate not run).
Inputs reviewed: docs/architecture/ARCH-viewer-ui.md, api/lesssheet.h, backend/contracts/api.zig,
backend/tests/all_tests.zig (frozen), implementation diff = backend/src/root.zig only
(git: contracts/, tests/, api/, build.zig untouched — no public-surface drift).

## Gate

`bash backend/.aidev/gate.sh backend`, run by me:
- conformance (zig 0.16.0 pin + `zig build`, comptime signature pins): **PASS**
- behavior (`zig build test`): **48/49** — sole failure `all_tests.zig:416`
  (`c2: a candidate that splits consistently beats single-field candidates`, `expected 2, found 1`).
- Re-ran the behavior suite twice more (different seeds `0x234bc04c`, `0xcb54529b`): identical
  48/49, same single failure — no flaky/threading failures observed across 3 runs.

## Measurements (reviewer-run, independent probes via the C ABI)

Probe: /tmp/lsprobe/probe.c + probe2.c, compiled against api/lesssheet.h and the built
zig-out/lib/liblesssheet.a (Debug — the gate's default optimize mode).

| Measurement | Target | Measured |
|---|---|---|
| ls_open on 5 GiB sparse doc (MANUAL) | O(head), in-core < 500 ms | **20.5–22.0 ms** (3 runs); bytes consumed (frontier probe) = **36 KB ≤ 4 MiB budget** |
| First 512-row window on that doc | < 50 ms (ARCH crit. 8) | **0.19–0.21 ms** |
| Row-count estimate at open (5 GiB) | present, estimated | 298,261,617, exact=false — sane (18 B rows) |
| AUTO index of a real 2.2 GB / 120 M-row file | progress monotone → complete/exact | monotone across 6,947 polls; complete; count exactly 120,000,000 |
| Scan throughput (Debug build) | none pinned | ~124 MB/s (≈17.4 s for 2.2 GB) |
| 10 windows across the fully-indexed 2.2 GB file | O(window) re-lex | 1.6 ms total (~0.16 ms/window) |
| Core memory during/after full 2.2 GB scan | O(window + checkpoints) | **phys_footprint peak 3.2 MB, steady 3.4 MB** (baseline 1.0 MB); resident_size grew to ~2.1 GB of *clean file-backed* pages (see finding 6) |

Order-of-magnitude evidence, single machine; all comfortably inside budget — nothing is
"close to budget".

## Acceptance criteria 1–8

1. **Forced dialect** — met. c1 tests pass; `validateOptions` matches the header domains exactly
   (byte ∈ [0x01,0x7F] minus CR/LF, quote NONE, header {-1,0,1}, index {0,1}, forced sep==quote
   collision) and rejects before any file access. Never-occurring separator → 1 column, not an error.
2. **Sniffer** — met (the non-disputed parts). All 8 candidate pairs picked despite quoted traps;
   comma/double-quote tie-breaks (candidate iteration in pinned preference order, strict-better
   replacement); head-sample bound is real: scoring is capped at 256 KiB/256 records and my 5 GiB
   probe confirms open consumes 36 KB. Line 415 of the disputed test (sniffs `;`) passes; only its
   dims assertion fails (see CHANGE-REQUEST section).
3. **Header grammar** — met. `isNumeric` implements the pinned grammar exactly (trim 0x09–0x0D,0x20;
   sign? (digits('.'digits?)?|'.'digits)((e|E)sign?digits)?; full match; empty ≠ numeric); all c3
   accepted/rejected forms pass, incl. quote-NONE changing numericness and the empty-document
   header-false-despite-forcing rule.
4. **Windowed access** — met. Zero-alloc access/poll paths proven by the frozen counting-allocator
   test; eviction + byte-identical re-serve (owned window buffer re-lexed from immutable mmap);
   64-bit row math clean (u64 throughout; (1<<32)+2 aliasing test passes); LS_WINDOW_MAX_ROWS clamp;
   window_set never advances the frontier (frozen probe test + code: it only snapshots
   frontier/checkpoints under the mutex).
5. **Index correctness** — met. 600-row gnarly sweep (quoted LF/CRLF, doubled quotes, LF/CRLF/lone-CR
   terminators) passes; checkpoints are only ever appended at record starts; CRLF can never be split
   by a checkpoint (headScan refuses to commit a record whose terminator crosses the budget; the
   worker always scans with limit = content.len).
6. **Progress monotonicity** — met. Frozen c6 tests pass; my 6,947-poll probe observed strictly
   monotone bytes_scanned to completion; jump progress is raised-only within a jump and exactly 1.0
   at done (`updateJump` only increases; span==0 guarded, no NaN).
7. **Jump semantics** — met. Exact landing (frontier_rows > target ⇒ target servable), EOF clamp
   makes count exact, behind-frontier jumps complete synchronously with bytes_scanned unchanged,
   cancel keeps the frontier (never rewound) and DONE persists over cancel per the header.
8. **O(head) open** — met and measured: 21 ms / 36 KB consumed / 0.2 ms first window on 5 GiB
   (250x margin on the 50 ms pin). One pathological gap — finding 2.

Threading model (code review): single pthread mutex + condvar guard frontier/checkpoints/jump slot;
worker is the sole frontier writer and scans chunks with the lock released; window lane
(win_buf/win_refs) is touched only by caller-serialized calls, cells are owned copies so background
scanning never invalidates borrows (eviction-safe borrow rule holds); close sets stop (mutex +
atomic for mid-chunk exit), broadcasts, joins, then frees — no deadlock ordering (one lock), safe
close-while-scanning. Darwin `pthread_mutex_t`/`pthread_cond_t` `.{}` init verified against
installed std source (default field values are the PTHREAD_*_INITIALIZER signatures 0x32AAABA7 /
0x3CB0B1BB — correct static init). `std.c.fstat`, `S.ISREG(u32)`, `posix.mmap`/`madvise`,
`MADV.DONTNEED=4`, `smp_allocator` (thread-safe) all verified against
/opt/homebrew/opt/zig/lib/zig/std/.

## Findings

1. **[contract]** `tests/all_tests.zig:416` is unsatisfiable together with the frozen header
   grammar and row-count rule. Independently re-derived and probe-confirmed — see the
   CHANGE-REQUEST section below. This is the only test failure; everything else is green.
2. **[impl, advisory — non-blocking]** O(head) open is violated for a *pathological first record*:
   `buildShape` decodes record 1 via `lexInto` with no byte cap, so a file whose first record
   exceeds LS_OPEN_HEAD_MAX_BYTES (multi-GB single line, or an unterminated quote at byte 0) makes
   ls_open read O(file) and heap-copy the whole record. The header pins "consumes at most
   LS_OPEN_HEAD_MAX_BYTES"; ARCH explicitly defers "huge single-row hardening" to slice 3 and no
   frozen test covers it, so I am not blocking on it — but the fix is cheap and in-contract (cap
   record-1 decode at the head budget as headScan already caps recordBounds). Track for slice 3.
3. **[impl, nit]** Worker spawn failure at open degrades silently (`worker = null`): under AUTO the
   index never advances past the head, and a jump beyond the frontier then stays SCANNING forever
   (progress frozen, no completion). Vanishingly rare (thread-resource exhaustion), but failing the
   open with .io — or completing such jumps degenerately — would be cleaner than a live-lock state.
4. **[impl, nit]** `freeDoc` never calls `pthread_mutex_destroy`/`pthread_cond_destroy`. Harmless
   on Darwin in practice; POSIX-cleanliness nit for a future touch of this file.
5. **Observation (no action)** — sniffer scoring: the `active`-quote signal dominates `splits`, so
   a quote-active single-column reading beats an inactive splitting one (e.g. `"a;b"\n"c;d"\n`
   sniffs comma/double-quote, one column, rather than `;`). That is the RFC-4180-faithful reading,
   the header says exact scoring is implementation detail, and both pinned outcomes hold on the
   pinned fixtures — noting it so the choice is on record.
6. **Observations for the integration review (measure at app level):**
   - Measure the 120 MB budget as **phys_footprint** (Activity Monitor "Memory" / `footprint(1)`),
     not ru_maxrss: clean file-backed mmap pages inflate resident_size to ~file size and are not
     reclaim-relevant. Core-side footprint measured 3.4 MB steady after a full 2.2 GB scan, so
     essentially the whole 30 MB post-framework headroom remains for the app.
   - Empirically, `madvise(DONTNEED)` does NOT reduce Darwin resident accounting for these pages
     (resident ≈ file size after a scan despite ~260 release calls). Footprint stays flat anyway;
     the call is harmless best-effort hygiene, but don't expect it to move any dial the budget reads.
     The madvise math itself (BOM offset, page alignment forward/backward, keepback window,
     bounds check) is correct by code review.
   - Scan throughput ~124 MB/s in the gate's Debug build (≈80 s to index 10 GB). No contract target
     exists and progress/cancel make it compliant, but the app should link an optimized core;
     re-measure jump-to-end UX on real multi-GB files.
   - `openWithAllocator` + LS_INDEX_AUTO calls the caller's allocator from the worker (checkpoint
     appends) concurrently with window-lane materialization, so that seam needs a thread-safe
     allocator. `ls_open` (smp_allocator) is safe; the frozen tests only combine the seam with
     MANUAL. Doc-comment candidate for the planner next time contracts/api.zig is amended.

## CHANGE-REQUEST adjudication (second key)

**Co-signed: YES — grounds A (infeasible within the current contract) confirmed independently.**

Re-derivation from the frozen artifacts only (before reading the implementer's reasoning in detail):
- `"x;y\nz;w\n"` is 2 records; line 415 pins the sniffed separator to `;` (and passes), so record 1
  is `["x","y"]` under every sniffable quote (neither `"` nor `'` occurs in the fixture).
- api/lesssheet.h HEADER RULE: record 1 is the header UNLESS every record-1 cell is numeric; "x"
  fails the pinned numeric grammar ⇒ header ON. ARCH criterion 3 pins the same grammar "under every
  sniffed/forced dialect".
- api/lesssheet.h: the effective header record "is EXCLUDED from data-row addressing and row
  counts" ⇒ ls_row_count_get().count == 1. `expectDims(od.doc, 2, 2)` (helper at line 95) asserts
  count == 2. 1 ≠ 2 — unsatisfiable.
- Probe-confirmed on the shipping core (independent C-ABI probe, /tmp/lsprobe):
  `x;y\nz;w\n → sep=; cols=2 header=true count=1 exact=true`; forcing header OFF (which the test
  does not do) is the only configuration yielding count=2. The structurally identical frozen c5
  fixture (line 786-790, 2 records, non-numeric record 1) requires header=true + count=1 and the
  core reports exactly that — so the planner's intended semantics unambiguously give this fixture
  1 data row; the `2` at line 416 is a wrong constant.
- Adversarial search for a reconciling implementation: I went further than the implementer and DID
  construct a contrived header rule that passes all 49 assertions (roughly: "header OFF iff
  separator was sniffed AND ≥2 columns AND no quoted field in the head AND record 2 not
  all-numeric; else the grammar" — it threads every dims/header assertion in the suite, including
  the `name,age` and `a\nb\nc` cases). I reject it as a resolution: it contradicts the frozen
  normative text of api/lesssheet.h (HEADER RULE "pinned grammar", LS_SNIFF = "apply the grammar")
  and ARCH criterion 3, and it misclassifies real files (`name;age\nalice;30` would lose its
  header). The contract is the header semantics plus the tests, not the test assertions alone —
  test-gaming is not "within the contract". Hence: not solvable in code within the contract ⇒
  `[contract]` stands.
- The proposed minimal change (expectDims → `(1, 2)`, or alternatively an all-numeric 2-row
  fixture `1;2\n3;4\n` keeping `(2, 2)` — my probe confirms the shipping core gives sep=`;`,
  header=false, count=2 for the latter) preserves the test's sniffing intent (line 415 untouched)
  and touches nothing else. Blast-radius claim ("none") verified: no header/contract-type change,
  other 48 tests already green, frontend unaffected.

Reviewer box ticked in backend/.aidev/CHANGE-REQUEST.md with an independent-verification note
appended (the sanctioned reviewer edit).

## Verdict

**PASS** — conditional on the CHANGE-REQUEST: the implementation would pass the gate absent the
disputed test (48/49 green, stable across 3 seeded runs; every ARCH core criterion 1–8 genuinely
met, measured where measurable). The sole failure is a contract defect in the frozen test, now
two-key co-signed for the planner to adjudicate. Findings 2–4 are non-blocking [impl] items for a
follow-up round or slice 3.

---

## Addendum — re-verification after DECISION-1 and nit fixes (2026-07-06)

**State re-checked:** DECISION-1 (commit aad62c1) amended only `backend/tests/all_tests.zig`
(+ pipeline docs) — the two-key-approved fixture repair `"1;2\n3;4\n"` keeping
`expectDims(od.doc, 2, 2)` at the c2 splits test, exactly the alternative my original probe
verified on the shipping core (`sep=';' header=false count=2 cols=2`; all-numeric record 1 keeps
the header OFF, so the dims assertion is now grammar-consistent). Implementation delta since my
PASS: `backend/src/root.zig` only, 965 → 981 lines, two hunks matching my findings 3 and 4;
grep confirms no other new call sites.

**Hunk 1 — fail-open jump when the worker never spawned (`ls_jump_start`, lines 647-657):**
correct and safe. Runs under the document mutex (lock at entry, defer unlock); placed after the
behind-frontier and complete branches, so it catches exactly the previously-livelocking case
(target ≥ frontier, not complete, `worker == null`) and leaves the normal path untouched.
Invariants hold: DONE ⇒ progress exactly 1.0 (header pin); `landed_row = frontier_rows - 1`
is a valid, servable 0-based DATA-row index (frontier_rows counts data rows from `data_start`,
so no off-by-one against the header-exclusion row-count rule), 0 when there are no data rows —
matching the header's no-data-rows convention. `d.worker` is written once at open before the
handle escapes, so no race. Strict-letter caveat noted: in this degraded mode `landed_row` may
be short of the target without an EOF clamp — acceptable, since the alternative (SCANNING
forever with frozen progress) violates the completion promise worse and hangs pollers; the
branch is reachable only on thread-spawn resource exhaustion and is untestable in fixtures
(code-review-only).

**Hunk 2 — primitive destruction (`freeDoc`, lines 368-381):** correct and safe.
`pthread_cond_destroy` + `pthread_mutex_destroy` before `gpa.destroy(doc)` (destroy before
freeing backing memory; cond/mutex mutual order immaterial with no waiters). Quiescence verified
at both call sites: ls_close joins the worker first (worker's final unlock happens-before thread
exit happens-before join returns — the POSIX-sanctioned unlock-then-destroy pattern), and the
open-failure paths call freeDoc before the spawn line, so the statically-initialized primitives
were never contended. Return values ignored is fine for non-pshared primitives here.

**Gate re-run by reviewer:** `bash backend/.aidev/gate.sh backend` → conformance PASS,
behavior PASS (49/49). No frozen paths touched by the implementer (git: `M backend/src/root.zig`
only).

### Final verdict: PASS
