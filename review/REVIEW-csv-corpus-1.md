# REVIEW — csv-corpus build (generate-at-test wiring)

Reviewer: independent; loyal to `ARCH-csv-corpus.md` (AC1–8) + the frozen contract, verified by
measurement. Adversarial. Did not edit code.

> Orchestrator note: reviewer subagent's verdict verbatim. I independently re-ran `bash .aidev/gate.sh`
> (PASS) on this tree before committing. Scope: AC1–5 + AC7. AC6 (on-demand huge-row perf lane) is NOT
> yet built — tracked as a follow-up; assessed here as excluded per the orchestrator's instruction.

**Verdict: PASS.** AC1–5 and AC7 are genuinely met, verified by independent measurement (not merely a
green gate). Frozen contract integrity intact. Three non-blocking advisories; none gates acceptance.

## Measured
- Root gate `bash .aidev/gate.sh` → PASS (backend 118/118 incl. the 2 corpus tests, csvgen selftest
  142/142, macOS 75/75, root). ~38 s.
- Determinism: two `gen.py --all --seed 1337` runs → byte-identical across all 57 files (56 `.csv` +
  `manifest.json`).
- AC4 independent C probe (links `liblesssheet.a`, replicates the frozen path: AUTO sniff + MANUAL index +
  first `ls_window_set(0,512)`) over all 56 light cases.
- AC5 independent: gate-built debug binary, `LESSSHEET_DUMP_EXIT=1`, 3 reps/case.
- AC7 guard mechanism verified against installed Zig 0.16.0 std.

## Crux-by-crux
- **Crux 1 — conformance sweep NOT vacuous: CONFIRMED.** `all_tests.zig` (§corpus ~:3523) iterates the
  generated `manifest.json` `cases[]`, skips `heavy`/`.gz`. Well-formed: asserts `ls_column_count`,
  `ls_row_count_get().count` + `.exact`, `ls_dialect_get().encoding`, separator — ONLY where the manifest
  field is an integer (ragged/null skipped, per the exactness rule). Malformed: `st == .ok or .io`, and if
  opened, `sampleServableBounded` touches every served byte (OOB borrow traps under test safety) — a real
  no-crash/no-UB proof. Completeness floor `seen>=40` / `malformed_seen>=5` / `popCount(enc_mask)>=5`
  cannot be met by an empty/short/zero-malformed/<5-encoding corpus. Measured: 56/8/5. The one carve-out is
  `blank_lines_interspersed` (`>=`); any NEW interior-blank case hits the strict `==` branch and fails loud.
  Probe opened all 56 with substantive output — no silent skips.
- **Crux 2 — hermetic + deterministic (AC1): CONFIRMED.** Corpus into build-managed dirs
  (`backend/.zig-cache/o/<hash>/corpus/`, `apps/macos/.build/corpus-cache/`) — both `git check-ignore`d;
  `git status` after a gate run shows only the two wiring files, no committed corpus. Byte-exact double-run.
  `--all` emits no >8 MiB file, no `.csv.gz`. Missing/broken python3 fails the build loudly.
- **Crux 3 — AC7 selftest guard genuinely guards: CONFIRMED (source-verified).** `gen.step.dependOn(&gen_selftest.step)`;
  `gen_selftest` has no output args → `hasSideEffects()==true` → runs every build, never cache-skipped;
  non-zero term fails via `handleChildProcessTerm`. A regressed generator/oracle fails the build BEFORE
  gen/tests. selftest also guards case-removal + manifest honesty. Ran 142/142.
- **Crux 4 — AC4 + AC5 by measurement: CONFIRMED.** AC4: all 56 light < 500 ms; worst `wide_100k_cols`
  **207 ms** (~2.4× headroom, O(head) holds), rest < 30 ms. AC5 (debug binary): the 4 normal reps
  167–230 ms; `wide_100k_cols` **438/461/468 ms** (close to budget — advisory 2).
- **Crux 5 — gate + frozen integrity: CONFIRMED.** Wiring non-frozen (backend `FROZEN_PATHS=(contracts tests)`,
  macОС `(Sources/Contracts Tests Package.swift)`; the `.aidev/profile.sh` AC5 gen-step is the
  ARCH-sanctioned location). csv-corpus frozen files byte-identical to `e24bb02`; the only Tests/Contracts
  changes since are the four column-windowing files (separate committed work). `build.zig`/`profile.sh`
  deltas match the freeze plan exactly.

## Non-blocking advisories
1. `[impl]` trivial — a gate run leaves `tools/csvgen/__pycache__/` untracked (from `import gen` in
   `selftest.py`). Fix: `.gitignore` `__pycache__/` (or `PYTHONDONTWRITEBYTECODE=1` on the python3 steps).
   [Applied by the orchestrator in the build commit.]
2. NOTE — AC5 `wide_100k_cols` ~438–468 ms vs 500 ms on the debug binary (~90–94%). The frozen test's
   3-launch retry only re-runs a launch that emits NO marker, not an over-budget one, so scheduler jitter
   on slower/busier hardware could flake it. Root cause = frontend paint at 100k cols (a designed-in
   residual the test itself flags), not the wiring. If it flakes: frontend perf (see backend wide-row-lex
   follow-up) or an architect width-rep change.
3. NOTE — AC5 says "release binary" but under `swift test` the launched binary is the DEBUG build.
   Harmless/conservative (debug slower → stricter bar). Frozen-test wording; out of scope.

## Bottom line
csv-corpus AC1–5 + AC7 PASS — generator wired into the frozen suites, conformance genuinely enforced,
hermetic + deterministic, oracle-guarded. AC6 (on-demand huge-row perf lane) remains to build.
