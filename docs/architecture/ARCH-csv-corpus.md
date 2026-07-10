# ARCH — csv-corpus (wire the clean-room generator into the frozen tests)

**Feature:** turn the in-repo, clean-room CSV generator (`tools/csvgen/`) into standing test coverage:
an independent **corpus-conformance sweep**, a **cold-open timing sweep**, and an on-demand
**huge-row perf lane** — so our parser is continuously checked against an adversarial, parser-agnostic
oracle, and huge-row verification stops depending on the author's hand-built `/tmp/sparse5g`.

**Read first:** `tools/csvgen/README.md` (corpus + `manifest.json` oracle schema), the frozen
`api/lesssheet.h` (TEXT AND ENCODING, THE SCAN FRONTIER, WINDOW), `backend/tests/all_tests.zig`
helpers (`makeFixture`/`openWith`/`expectDims`/`elapsedMs`), and the workspace `CLAUDE.md` cold-start
budget. Related: `[[formats-roadmap]]` (`.csv.gz` is deferred here — see Non-goals).

## Problem / motivation
The frozen suites synthesize every fixture inline, so they exercise a narrow slice of the CSV format.
`tools/csvgen/` already produces 63 deterministic, adversarial cases (BOMs, 5 encodings, 4 delimiters,
unicode/emoji/ZWJ/RTL, 8 malformed pathologies, shape/size extremes) with a machine-readable
`manifest.json` oracle (exact `column_count` / `data_row_count` / `encoding` / `malformed` per case) and
its own `selftest.py`. None of that breadth is wired into the gate. Separately, every huge-row
responsiveness check today points at `/private/tmp/lsprobe/sparse5g.csv` — a hand-built file not in the
repo, so verification isn't reproducible. This feature closes both gaps **without adding parser features**.

## Decisions already made with the user (do not re-litigate)
- **Fixture delivery = generate-at-test (hermetic).** A build step shells to `gen.py` (fixed seed) into a
  build-cache dir; the frozen tests read that dir + its generated `manifest.json`. `gen.py` + `manifest`
  stay the single source of truth; **no generated fixtures are committed**; the corpus can't drift from
  the generator. This makes **Python 3 a gate prerequisite** (stdlib-only; ships on macOS/Linux).
- **Timing gate = core-all-cases + UI-sample.** Backend asserts cold-open < 500 ms for *every* non-heavy
  case; the frontend launch→first-rows-visible < 500 ms probe is extended to a *representative subset* of
  corpus files (not all 63 — no 63× app launches in the gate).

## Goal
Every gate run: (1) proves the generator/oracle is self-consistent, (2) proves OUR parser matches that
oracle across the whole adversarial light corpus, (3) proves cold-open stays within budget across it, and
(4) makes the huge-row responsiveness proof reproducible from the repo on demand.

## Constraints (the crux)
- **Oracle-bound, not byte-bound.** The conformance sweep binds to the CONTRACT "parser output == manifest
  oracle", enumerated from the generated `manifest.json` — NOT to hard-coded expectations for named files.
  New generator cases are covered automatically; nothing to update per case.
- **Assert exactly where the oracle is exact; assert robustness where it isn't.** One clean rule (see AC2/3)
  removes ambiguity for `"ragged"` / `null` fields — no per-case special-casing, no open questions.
- **No parser behavior change.** Malformed handling is asserted for *robustness* (no crash/hang/UB), not
  changed; leniency stays as-is. **No `api/` surface change** — the sweep uses existing accessors only.
- **Fast gate stays fast.** Heavy cases (> 8 MiB: `tall_3col`, `varying_rows`, `single_big_cell`,
  `single_big_row`, `size_100mb/1gb/10gb`) are NEVER generated in the fast unit gate — for **generation
  cost** (disk + write time), NOT because they miss the responsiveness budget (see §Heavy cases). Their
  cold-open budget is still enforced, on demand, in the perf lane (AC6). The light corpus (`gen.py --all`)
  generates in well under a second (streaming).
- **The < 500 ms cold-open budget is UNIVERSAL — no case is exempt.** The only split is which LANE proves
  it: the fast gate for the 56 light cases (AC4), the on-demand perf lane for the 7 heavy cases (AC6).

## Why the heavy cases are excluded — generation cost, NOT a responsiveness waiver
The user's sign-off asked to confirm the heavy cases are "really heavy" and to explain "why every
exception goes over the limit." The honest finding: **there is no cold-open exception.** Cold-open is
bounded by the HEAD, not by row sizes. `ls_open` faults ≤ `LS_OPEN_HEAD_MAX_BYTES` (4 MiB) regardless of
file size; the first `ls_window_set` re-lexes ONLY rows BEHIND the scan frontier — which at open covers
just that ≤4 MiB head — and `ls_window_set` NEVER advances the frontier itself (api §OPEN COST + §Windowed
row access). So the first-paint lex is ≤ ~4 MiB whatever the row sizes; a 10 GB file cold-opens as fast as
a 10 KB one (measured: big2g, 2.6 GB / 100M rows → ~246 ms). Each heavy case is excluded from the fast gate
purely because generating its fixture there is impractical; each still owes < 500 ms cold-open, verified in
the perf lane (AC6).

**Caveat — the per-window AGGREGATE (out of scope, tracked separately).** The per-row scan cap bounds each
row, NOT the window total. Once the frontier has advanced (background index / jump / match-scan) past a
dense region of many ≥1 MiB rows, a full 4096-row `ls_window_set` into it can synchronously re-lex up to
`LS_WINDOW_MAX_ROWS × LS_WINDOW_ROW_SCAN_MAX_BYTES` = 4096 × 1 MiB ≈ 4 GiB — the per-window aggregate scan
backstop DEFERRED by huge-row-budget (per-row cap only; see `docs/architecture/ARCH-huge-row-budget.md`
§"per-window aggregate scan ceiling"). That is a scroll/jump path, NOT cold-open, and NO csv-corpus case
reaches it (light files are ≤ 8 MiB whole → a full window re-lexes ≤ 8 MiB; the heavy huge-row cases are a
single giant row/cell). csv-corpus does not address it — it is a separate backlog ticket.

| heavy case | size | shape | why excluded from FAST gate | cold-open verdict |
|---|---|---|---|---|
| `tall_3col`      | 134 MB | 3 cols × 3.8M rows | 134 MB write per gate run | < 500 ms (big2g shape: O(head) + tiny window) |
| `size_100mb`     | 100 MB | 3 cols × 1.6M rows | 100 MB write | < 500 ms (O(head)) |
| `size_1gb`       | 1 GB   | 3 cols × 16.8M rows | 1 GB write + disk | < 500 ms (O(head)) |
| `size_10gb`      | 10 GB  | 3 cols × 168M rows | 10 GB write (~minutes) + disk | < 500 ms (O(head)) |
| `single_big_cell`| 67 MB  | 1 row, one ~67 MB cell | 67 MB write | < 500 ms (BOUNDED RECORD 1 keeps open O(head); row scan cap bounds the window) |
| `single_big_row` | 67 MB  | 6 rows, one giant wide row (the sparse5g shape) | 67 MB write | < 500 ms cold-open + < 100 ms landing on the giant row (huge-row-budget bound) |
| `varying_rows`   | 16.7 MB| 90 rows, widths cycling 0 B → 1 MiB | 16.7 MB write; huge-row stress | < 500 ms (row scan cap bounds each ≥ 1 MiB row; only 90 rows total) |

The only quantities that legitimately scale with a heavy file's size are **generation time** (test-infra
cost, off the UI lane) and **background full-index time** (off the UI lane — per the outlier-budget policy
[[outlier-budget-policy]], background time may relax as long as the UI stays responsive, which AC6's
cold-open + landing asserts prove). Note `wide_100k_cols` (2.5 MB, 100k columns × 3 rows) is the widest
case and stays LIGHT — its cold-open (materializing ~300k tiny cells) is asserted < 500 ms in the fast gate
(AC4); it is a natural width representative for the UI sample (AC5).

## Design direction (planner works out the mechanism)
- **Generate-at-test wiring (`backend/build.zig`, not frozen):** a `b.addSystemCommand` runs
  `python3 tools/csvgen/gen.py --all --seed <fixed> --out <cache>` (and `manifest-only` is implied — the
  manifest is always written); the behavior-test run depends on it; the cache dir path is injected into the
  frozen test module via `b.addOptions` (a generated `corpus` options module exposing `dir: []const u8`).
  The frozen test parses `<dir>/manifest.json` with `std.json` and iterates `cases[]`.
- **Backend conformance + timing sweep (`backend/tests/all_tests.zig`, frozen):** new `§corpus-*` tests
  open each non-heavy case via the existing `ls_open` path and assert against the manifest (AC2–4).
- **Frontend UI-sample (`apps/macos/Tests/`, frozen):** extend the existing `first_rows_visible_ms` probe
  to launch the gate-built release binary on ~3–5 representative corpus files (AC5). The macOS test needs
  the same corpus on disk — reuse the generate step (shared cache) or a test-setup generate.
- **Huge-row perf lane (`profile.sh`, not frozen):** generate a huge-row heavy case on demand
  (`single_big_row` — tiny rows + one enormous row, the sparse5g shape — and/or `varying_rows`) at a chosen
  size, run the huge-row landing/materialize probe, assert bounded (AC6). Replaces `/tmp/sparse5g`.
- **Oracle guard:** run `python3 tools/csvgen/selftest.py` in the gate (or fail-fast in the generate step)
  so a generator regression can't make the conformance sweep pass vacuously (AC7).

## Acceptance criteria (testable)
1. **Hermetic generation.** The backend test build generates the light corpus (`gen.py --all`, fixed seed)
   into a build-cache dir before tests run; the corpus dir + its `manifest.json` are available to the frozen
   tests. No committed fixtures (git clean). `python3` is a documented gate prerequisite; a missing/broken
   generator fails the build loudly (not silently skipping coverage).
2. **Conformance — the exactness rule (well-formed).** For every non-heavy case, `ls_open` succeeds and,
   **wherever the manifest field is an integer**: `ls_column_count == column_count`,
   `ls_row_count_get().count == data_row_count` with `.exact == true` (light files ≤ head budget index fully
   at open), and `ls_dialect_get().encoding` maps to the manifest `encoding` (`LS_ENCODING_UTF8..WINDOWS1252`);
   the resolved delimiter matches where the manifest declares one. Sampled cells are servable (non-crashing)
   within the display cap. **Where a field is `"ragged"` or `null`, its exact value is NOT asserted** —
   only robustness (AC3) applies to that dimension.
3. **Conformance — malformed / undefined robustness.** For every malformed case (and any `null`
   dimension of a well-formed case), `ls_open` returns either `LS_OK` (lenient) or a distinct, documented
   `ls_status` failure — **never crashes, hangs, or exhibits UB**; if it opens, a first window materializes
   and cells serve bounded (no out-of-bounds). Decode-breaking cases (broken UTF-8, odd-length UTF-16,
   embedded NUL) are handled by detection/forcing without crashing.
4. **Cold-open — core, all cases.** For every non-heavy case, `ls_open` → first `ls_window_set`
   first-window materialize completes **< 500 ms** (O(head)/O(viewport), never O(file)), asserted with the
   existing `elapsedMs` helper. Guards the cold-start budget across the whole adversarial corpus.
5. **Cold-open — UI sample.** The frontend launch → `first_rows_visible_ms` **< 500 ms** probe passes on a
   representative subset (~3–5 files) chosen to span encoding × EOL × width — MUST include a
   unicode/emoji case and a CRLF case. Launches the gate-built release binary (not a possibly-stale bundle).
6. **Heavy cases — budget ENFORCED on demand (reproducible), not waived.** `profile.sh` generates the heavy
   cases on demand and asserts the SAME < 500 ms cold-open budget on them, proving it holds independent of
   file size:
   - **Huge-row/cell stress** (`single_big_row`, `single_big_cell`, `varying_rows`): assert cold-open
     < 500 ms AND landing/materialize on the giant row/cell stays bounded (< 100 ms landing analog from
     ARCH-huge-row-budget). `single_big_row` is the reproducible, in-repo replacement for `/tmp/sparse5g`.
   - **Size scaling** (at least two points, e.g. `size_100mb` and `size_1gb`): assert cold-open < 500 ms at
     both and that it stays FLAT as size grows — the direct demonstration that cold-open is O(head), not
     O(file). `size_10gb` is available on demand but not required for the proof (the 100 MB → 1 GB flatness
     already establishes file-size independence).
   This lane is NOT part of the fast unit gate (generation cost); it is the on-demand proof that the
   universal budget covers the heavy cases too.
7. **Oracle guard.** `python3 tools/csvgen/selftest.py` runs green as part of the gate (or as a fail-fast
   precondition of the generate step), so a generator/oracle regression can't vacuously pass AC2–4.
8. **Gates green** (backend + macOS + root); no regression to existing tests, cold-start, or the
   huge-row-budget / huge-row-filtered guarantees.

## Non-goals (explicit)
- **`.csv.gz` conformance is DEFERRED** to the formats feature (`[[formats-roadmap]]`): the generator can
  already emit reproducible `.csv.gz`, but there is no gzip parser yet, so `.gz` is excluded from the sweep
  until that lands (at which point the sweep picks it up via the same manifest iteration).
- **Parquet / xlsx** — formats feature.
- **No change to parser malformed *behavior*** (robustness asserted, leniency unchanged) and **no `api/`
  surface change**.
- **Heavy cases in the fast gate** — never; on-demand perf lane only.
- **Row-count estimator fix** (tiny-head/fat-tail) — separate backlog item.

## Contract surface (planner freezes)
- `backend/tests/all_tests.zig` — new frozen `§corpus-conformance` + `§corpus-cold-open` tests (AC2–4),
  reading the injected corpus dir + `manifest.json`. RED at freeze (corpus/oracle assertions unmet by a seed).
- `backend/build.zig` (not frozen) — generate-at-test system command + `addOptions` corpus-path injection;
  test step depends on it. Set up at freeze so the RED test compiles.
- `apps/macos/Tests/` — frozen extension of the `first_rows_visible_ms` probe to representative corpus
  files (AC5), plus its corpus-availability wiring.
- `.aidev` perf/gate scripts (not frozen) — `selftest.py` oracle guard (AC7) and the `profile.sh` huge-row
  perf lane (AC6).
- `api/lesssheet.h` — **no change** (default). If the planner finds a genuine need to expose something new
  across the ABI, that's a root-planner decision to bring back — not expected.

## Open questions
None. Both design forks (fixture delivery, timing scope) are decided; the exactness rule (AC2/3) resolves
the `"ragged"`/`null` ambiguity without per-case judgment.
