# REVIEW — csv-gz

**Final verdict: PASS** (reviewer, claude-opus-5), bound to
tree `bcab7bc44fffae56dfb9ef7a8a63d4383e454f4d51bb45f56ce37425f65c3cd1`. No residual `[impl]`, `[contract]`,
or `[design]` findings. Built on branch `feature/csv-gz` on the reader-interface reorg base (`af83db9`),
frozen contract `b19fe39`.

## Cell configuration
- **Implementer:** `claude-native` runner (claude-opus-5),
  workspace-write via isolated-promotion (repo-root mirror; only `backend/src` promoted back). A prior Round 1
  with claude-native Sonnet was reverted (perf regression + a hang, 14 ACs unreached after 5.5h).
- **Reviewer:** `claude-native` runner (claude-opus-5).
- **Orchestrator gate:** `bash .aidev/gate.sh` run by the orchestrator; the implementer's own claims were
  never accepted as evidence. Round budget extended 5→10 by the user for this large refactor (converged at 5).

## Scope
Transparent `.csv.gz`: gzip detected by magic (`1f 8b`), not filename. A streaming, checkpointed gzip Source
feeds the existing CSV Reader through the same document/window/search/filter/nav/copy surface, launch→first
rows < 500 ms, never retaining or fully inflating the file. Delta on the Reader/Source reorg; C ABI
(`api/lesssheet.h`) byte-identical (AC1). Frozen: `contracts/api.zig`, `tests/all_tests.zig`. Seeds +
implementation under `backend/src/`.

## Round history
- **R1** — gate green (`zig build test` 151/151; the 18 RED `gz_ac2–19` resolved, no regressions to the prior
  133). Isolated-promotion boundary held: frozen surface byte-identical.
- **R1 review → 6 `[impl]`** — AC5 open ceiling lifted early; AC11 axis mixing; AC13 unbounded materialize on
  ordering predicates; AC15/17/18 checkpoint spill was an 8-byte marker (no real snapshot/eviction/ceiling);
  AC19 source mutex held across inflate/parse + racy shutdown; req4 non-KMP text matcher.
- **R2** — all 6 fixed (real snapshot spill + 16 MiB eviction + damaged-EOF; streaming decimal ordering;
  leased lanes + atomic shutdown; precomputed KMP). **Review → 3 residual `[impl]`**: AC11 positions not
  carrying immutable dual coords; Req2 `DualLimit.physical` ignored; AC20 mmap match still per-unit.
- **R3** — immutable dual-coordinate `Pos`; dual-limit cursor enforcement incl. replay; direct mmap cursor.
  **Review → 1 residual `[impl]`**: `madviseDontNeed` double-applied the BOM base.
- **R4** — madvise fix. **Review → code PASS**, conditional on the reviewer-measured NFRs.
- **NFR pass surfaced 2 real `[impl]` defects the small-fixture tests could not** (verified with `gzcat|wc`,
  `grep -c`): **AC17** — a valid >2/4 GiB single-member gzip truncated at ~2 GiB (open-time 4 MiB physical
  fence not lifted after open → damaged EOF; core reported 144,040,679 rows `exact=true` on a ground-truth
  715,827,882-row / 10 GiB stream). **AC20** — plain-mmap search/filter +62–66% vs `af83db9` (match path
  still routed per-unit through the generic cursor). Both `[impl]`, architecture sound.
- **R5** — `source.zig` `finishOpen` always lifts the open fence (valid 10 GiB reaches true EOF, all rows);
  `csv_reader.zig` UTF-8 mmap matching does bulk contiguous `findScalar`/`findAny` spans for search/filter/nav
  (gzip stays streaming). **Re-measured → both pass; final review PASS.**

## Final NFR evidence (release, quiet Apple-Silicon host; tree `bcab7bc4`)
- **AC22** — executable 2.71 MiB, `.app` 2.86 MiB; `otool -L` only Apple/Swift system dylibs, no
  libz/libcompression (gzip static from Zig-0.16 `std.compress.flate`).
- **AC17** — full 10 GiB scan, `row_count=715,827,881 exact=true`; gzip resident 7.1 MiB (≤16), steady RSS
  35 MiB (≤120), checkpoint file 21 MiB / mode 0600 / unlinked (≤ logical/400+1 MiB), replay 31.98 MiB from a
  1.3 GiB checkpoint (≤32 MiB), landed cell correct.
- **AC20** vs `af83db9` (2 GiB plain, 5 alternating runs, medians): search 11,009→2,738 ms (−75.1%),
  filter 10,851→2,521 ms (−76.8%), windows 3,026→669 ms (−77.9%), steady RSS +288 KiB (≤5 MiB). ~4× FASTER.
- **Cold start** (`first_rows_visible_ms`, 5 runs): plain 167–188 ms; gzip 10 GiB-logical 170–218 ms (<500).
- **Behind-frontier landing**: plain `worst_max_gap_ms` 20–23 ms; gzip checkpoint-replay 11 ms (≤100).
  (gzip-replay landing measured on a maximally-compressible fixture; the ≤32 MiB replay bound + frozen
  `gz_ac16` cover the budget on representative data.)

## Notes / non-blocking backlog (pre-existing, not csv-gz)
- Filtered `ls_cell_copy` `nav_scratch` alloc vs the header's zero-alloc wording; `cellCopy` reads
  `filter_state` outside `d.lock()`. Predate csv-gz; not re-flagged.
- Probe caveat: the AC17 probe's in-process `land_ms`/`scan_ms` initially used a wrong macOS `timeval` layout
  (`tv_usec` is 32-bit) — fixed for the final landing number; never affected the memory/accessor results.
