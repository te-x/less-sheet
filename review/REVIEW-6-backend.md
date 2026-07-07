# REVIEW-6 — backend (Zig core), feature find-seek

**VERDICT: PASS** (advisory findings only; none blocking, no contract defects).

Scope: backend cell only (parallel-cell policy; apps/macos reviewed separately; root/macos gates
not run — the frontend tree is mid-edit). Inputs reviewed: docs/architecture/ARCH-find-seek.md,
api/lesssheet.h @ d640911, backend/contracts/api.zig, backend/tests/all_tests.zig (frozen),
implementation diff = backend/src/root.zig only (git: contracts/, tests/, api/, build.zig
untouched — no public-surface drift; deletions are the find-seek seed stubs plus the worker-loop
priority restructure only).

## Gate

`bash backend/.aidev/gate.sh backend`, run by me:
- conformance (zig 0.16.0 pin + `zig build`, comptime signature pins): **PASS**
- behavior (`zig build test`): **PASS** (73/73: 49 viewer-ui + 24 find-seek)

## Integration attribution — the Swift `ls_search_start == false` question

**The backend is exonerated. The failure is in the frontend marshaling.** Evidence (probes in
/tmp/lsprobe, all against the real header and the real installed lib):

1. **Layout probe** — probe_layout.c (real api/lesssheet.h through clang) vs probe_layout.zig
   (the real contracts/api.zig + src/root.zig modules), both printing size/align + per-field
   offset/size of every ABI struct and the size + value of every enum/enumerator. Output is
   **byte-identical** (`diff` empty). Key shapes, both sides:
   - `ls_search_request`: size 48, align 8 — kind@0(4) op@4(4) column@8(4) [pad 4]
     value_ptr@16(8) value_len@24(8) scope_ptr@32(8) scope_len@40(8)
   - `ls_search_status`: size 56, align 8 — state@0(4) nav@4(4) progress@8(8) found_row@16(8)
     found_col@24(4) [pad 4] position@32(8) total@40(8) total_exact@48(1)
   - all enums 4 bytes, values exactly as `#define`d/enumerated in the header.
2. **Link probe** — probe_b.c compiled with `zig cc -I api` against
   backend/zig-out/lib/liblesssheet.a (the artifact Swift links, rebuilt by the gate at review
   time), issuing the exact two requests from the failing Swift run on a 2-column fixture:
   - `TEXT("needle", scope NULL)` → **start=TRUE**, DONE total=2, first nav FOUND row 1 col 0 pos 1
   - `PREDICATE(col 1, LE, "2")` → **start=TRUE**, DONE total=2, first nav FOUND row 0 col 1 pos 1

Diagnostics for the frontend implementer:
- The one root cause that explains BOTH observed rejections at once is **value_len arriving as 0**
  (TEXT rejects the empty query; an ordering predicate rejects the empty value as non-numeric) —
  or value_ptr arriving NULL with value_len != 0. Check the Swift bridging of the two length
  fields (`size_t`) and that the value buffer outlives the call.
- Also demonstrated: `PREDICATE(col 1, …)` on a document that sniffed as **1 column** returns
  FALSE legitimately (fixture dialect worth checking) — but that would not explain the TEXT
  failure.
- Fresh-handle `ls_search_poll` is all-zero as pinned; junk kind=7 / op=99 / dir=5 through the raw
  C ABI reject / no-op cleanly (no panic, no state change) even in the Debug lib.

## Measurements (reviewer-run, independent probes via the C ABI)

ReleaseFast lib (built to /tmp/lsprobe/rel), 398 MB / 16M-row generated CSV, Apple Silicon:

| Measurement | Target | Measured |
|---|---|---|
| Plain index scan to EOF (jump, MANUAL) | baseline | 270 ms — **1.41 GB/s** |
| Full TEXT match-scan behind frontier | same order as indexer | 943 ms — **403 MB/s** (≈3.5× indexer per byte; delta = per-cell decode + match ≈ 42 ns/row) |
| Full ordering-predicate scan (col ≤ value) | same order | 988 ms — **384 MB/s** (parseDecimal adds ~3 ns/row) |
| Frontier-ADVANCING text search (fresh MANUAL doc) | paid once | 940 ms — same throughput; subsequent jump into region instant |
| Full-file text search, 2.6 GB extrapolation | single-digit minutes worst case | **≈ 6.5–7 s** (release) |
| DONE-state nav (behind frontier, incl. last-in-file backward) | < 50 ms core-side | **worst 0.28 ms** over 20 navs |
| phys_footprint through open → full index → full search → window | O(checkpoints), app budget < 120 MB | **1 MB flat** at every phase (block_counts for 16M rows = 62.5 KB). maxrss inflation is clean file-backed pages (Darwin lazy DONTNEED) — same accounting pinned in REVIEW-5 finding 6; measure the budget as footprint, not ru_maxrss |

## Acceptance criteria 1–6 (each independently checked, not just "tests pass")

1. **Text matcher** — f1 suite + probes: smart-case pinned both modes, substring at
   start/middle/end, ≥0x80 bytes never fold, header record excluded (probe: header cells
   containing the query not matched), scope exact with lowest-in-scope column reporting. ✓
2. **Predicate matcher** — f2 suite + my **23-case adversarial decimal battery** (all exact) and
   **11-case rejection battery** through the public ABI: magnitude boundaries (9.99e2 vs 1e3,
   msd_pos ±1), sign/zero normalization (-0 == 0 == +0.000 == 0e5), prefix-significand ordering
   (1.2 vs 1.20 vs 1.2000000001), leading zeros, whitespace-padded cells AND values, 2^53±1,
   39-digit integers, 1e±400 vs 1e±399, negative long fractions, exponent-saturation forms
   (deterministic, documented latitude, no crash). Grammar-duplication drift between `isNumeric`
   (header rule) and `parseDecimal` (predicate values): **fuzzed, 9362 strings (exhaustive ≤5
   over "+-.e5 " + long handcrafted), zero disagreement.** ✓
3. **Streaming navigation** — f3 suite + resume probe: exact row+col both directions, behind and
   beyond the frontier; frontier advance verified by subsequent instant jump; progress monotone
   to 1.0 / frozen at cancel. ✓
4. **Counts** — f4 suite (zero/dense/straddling layouts, positions at block edges 1023…8192).
   O(checkpoints) verified two ways: (a) the frozen dense-vs-sparse bytes-delta methodology is
   sound — it counts cumulative allocation volume through the document allocator, the 3.6 MB
   fixture is fully head-indexed at open so the delta isolates search-side allocation, and a
   match-row list would exceed the 64 KiB slack ~25×; (b) my footprint probe (table above).
   Nav is O(constant blocks): block-skip via counters + ≤2 block re-lexes + 1 position block. ✓
5. **Job discipline** — f5 suite + two probes on the Debug (safety-checked) lib:
   - **Stress**: 300 rapid replacements (text/scoped/predicates) with interleaved
     nav/jump/cancel and 3 concurrent poll threads asserting domain/monotonicity/DONE
     invariants → zero violations, then a known-layout search returns the exact total (16) and
     a full forward walk lands all 16 with exact positions — proves gen-discard leaves no count
     corruption and replacement frees no buffer the worker still reads.
   - **Cancel/resume state machine** (the corner the frozen tests skip): cancel freezes counts
     inexact; in-counted-region nav resolves instantly WITHOUT resuming (stays CANCELLED);
     beyond-region nav resumes, serves the nav, and **reverts to CANCELLED before EOF** with
     found persisting and progress monotone; backward last-in-file resumes to EOF → DONE
     total_exact, progress exactly 1.0; ls_close during an active nav-resume joins cleanly.
   - Snapshot audit (code): the worker chunk dereferences only w_value/w_mask/w_ctx (owned
     copies; value_dec re-parsed FROM the copy, so its digit slices point into worker-owned
     bytes), immutable doc fields, mmap bytes, and worker-only scratch. Replacement under the
     mutex frees only doc-side buffers. Chunks commit exactly at checkpoint-interval boundaries
     (or EOF), keeping block_counts index-aligned; discarded chunks lose only in-flight work.
   - Priority jump > search > index: mutual exclusion is enforced at the start sites; a running
     search itself advances the shared frontier and completes the index at EOF, so a long search
     delays but never starves index completion (AUTO bytes_scanned pauses only while re-counting
     already-indexed bytes — acceptable within the pinned model, noted below). ✓
6. **Re-open zero state** — f6 suite + fresh-handle all-zero poll through the C ABI. ✓

Cold start: search machinery is lazy (all-zero init, no allocation/threads until first start;
open path untouched) — open footprint 1 MB, viewer-ui open tests green. Frozen viewer-ui
behavior: 49/49 green; diff confirms no changes beyond the worker restructure.

## Findings (advisory)

1. **[impl] OOM silently corrupts instead of failing the search.** `commitSearch`:
   `block_counts.append(...) catch {}` — a dropped entry shifts every later block's count down
   one index, and `relexBlock`/`findForwardMatch`/`positionOf` index checkpoints/counters
   POSITIONALLY, so navigation/positions go silently wrong after an allocation failure.
   `refreshWorkerCtx`'s `catch {}` is worse: a failed appendSlice can leave the worker's query
   copy empty → a TEXT search matches every row. Probability is negligible (8 B per 2048 rows)
   and the frozen suite cannot reach it, but the graceful path should set the search CANCELLED
   (or mark it failed) rather than degrade silently. Local fix, fully within the contract.
2. **[impl] Degraded no-worker path blocks.** When `Thread.spawn` failed at open,
   `ls_search_start`/`ls_search_nav` scan synchronously to EOF/nav-resolution while holding the
   doc mutex — the header's "never blocks" is bent in this corner. It deliberately mirrors the
   jump slot's fail-open design accepted in REVIEW-5 (terminate rather than hang pollers), so I
   am not blocking on it; a comment cross-referencing that precedent plus chunked stop-checks
   would be enough if revisited.
3. **[note] Pending-forward-nav re-resolution cost.** Each chunk commit re-walks block counters
   from the anchor block under the mutex (O(blocks) skip walk; worst case ~2.4G trivial
   iterations integrated over a full 2.6 GB scan with an early never-matching anchor, ~tens of
   µs per commit). Bounded and unobservable at current scale; a resume cursor would remove it.
4. **[note] `textMatch` is the naive O(cell·query) scan** — measured 403 MB/s with a 6-byte
   query; pathological self-similar queries degrade the constant but the scan stays
   disk-order. `std.mem.indexOfPos` is a drop-in for the non-folding path if ever needed.
5. **[note] `search_total +%= res.matches`** — wrapping add where overflow is impossible;
   plain `+=` states intent better (and would trap rather than wrap on an impossible bug).
6. **[observation → orchestrator/app cell] zig-out ships the LAST `zig build`'s optimize mode.**
   The gate installs a Debug lib (search ≈ 5–10× slower than release). Criterion-10 app
   measurements must link a `-Doptimize=ReleaseFast` build of liblesssheet.a.

No `[contract]` findings: nothing here requires amending the frozen surface, and the pinned
semantics (including the documented exponent-saturation latitude) were all implementable and
implemented within it.

## Probe inventory (reproducible)

/tmp/lsprobe: layout_c.txt ≡ layout_zig.txt (diff empty); probe_b.c (attribution + decimal/reject
battery driver), probe_edge.c (junk enums, NULL value_ptr, empty doc, fresh-handle zero),
probe_resume.c (cancel/resume/revert), probe_stress.c (replacement + 3-thread poll),
probe_perf.c / probe_fp.c (throughput + phys_footprint, release lib in rel/), probe_grammar.zig
(isNumeric ≡ parseDecimal acceptance, 9362 strings), gen.c + big.csv (16M rows / 398 MB).
