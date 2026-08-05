# tools/fuzz — the pre-launch fuzz harness

Coverage-guided fuzzing over the less-sheet C ABI. This is the dev tool for
**security-hardening wave (c)** (`docs/architecture/ARCH-security-hardening.md`,
AC-c1 / AC-c2 / AC-c3). It is **not gate-blocking** — AC-c3 calls the campaign a
one-time pre-launch cadence, so nothing here runs in `.aidev/gate.sh`.

## The one command

```sh
bash tools/fuzz/fuzz.sh                   # 20k iterations per target (smoke)
bash tools/fuzz/fuzz.sh 5000000 --fresh   # a real campaign, from the seeds only
bash tools/fuzz/fuzz.sh --minutes 30      # wall-clock budget (see AC-c2 below)
```

Comparing two harness versions? Use `--minutes`. An iteration is not a constant
amount of work — see *"An iteration is not a unit of work"* below.

Triage levers (both used to pin finding F1, and both worth knowing before a long run):

```sh
zig build test -Donly="fuzz net"          # replay/fuzz ONE target
zig build test -Dseed-limit=40            # only the first 40 corpus entries
```

`-Donly` answers "which target", `-Dseed-limit` answers "slow, or wedged?" — time
N=1, 40, all and look at the scaling.

It builds the harness, replays the committed corpus, runs the campaign, decodes
the coverage map, prints a per-module coverage report, and writes the whole
transcript to `tools/fuzz/campaign/campaign-<host>-<timestamp>.log` (the AC-c3
campaign log). It exits non-zero if the campaign found anything **or** if any
AC-c1 hotspot module was never entered.

Requires only `zig 0.16.0` and `python3` (the latter only with `--regen`).
**No new dependency**: Zig 0.16 ships its own coverage-guided fuzzer, so there is
nothing to install. That is also the only option on this machine — Apple clang has
no libFuzzer runtime (`libclang_rt.fuzzer_osx.a` is not shipped), and neither
AFL++ nor Homebrew LLVM is installed.

## What it fuzzes

Four independent fuzz targets in `harness.zig`, each with its own corpus, all
sharing one coverage map:

| target | input the fuzzer controls | what it reaches |
|---|---|---|
| `csv` | a local CSV file's bytes + dialect/window/search/copy knobs | `csv_reader`, `source` (mmap), `window`, `index`, `search`, `encoding`, `matcher`, `filter`, `nav`, `column*` |
| `gz_raw` | the raw bytes of a `.csv.gz` file | the gzip source + `std.compress.flate`'s whole error space |
| `gz_trunc` | a payload **and** a truncation offset; the harness deflates and cuts | mid-DEFLATE-symbol truncations — task #40's crash shape, generalized |
| `net` | a served body + the fake-transport fixture matrix (range/length/status/redirects/faults/`drop_after`/`short_body_at`) | `net_source`, the spool, range vs sequential fill, gzip-over-spool |

`NetFixture.withhold` is deliberately **not** used — see the long comment at
`oneNet`. It makes the fake WAIT for a gate the test must raise, and a fuzz target
cannot honour that: if the drawn gate sits below what the open head needs, the open
blocks and the code that would raise the gate is downstream of the blocked call.
The frozen suite is the right home for that knob, because a test knows its own
fixture's size (`flate_b2a`/`flate_b2b`, AC13).

Everything is built **`ReleaseSafe`** — the mode we ship. That is deliberate and
load-bearing: a Zig safety panic in the shipped mode *is* a crash against the
standing product bar, so the campaign is looking for exactly the faults a user
could hit. The targets assert nothing about returned values; the property under
test is that the process survives arbitrary bytes and the API stays callable.
Value correctness is the frozen suite's job (285 tests).

### The net-source seam

`net_source` is the one hotspot with no C-ABI route. The production entry point
`ls_open_url_start` owns a real `std.http.Client`, which needs a live server —
neither hermetic nor fuzzable. The backend's frozen contract exposes exactly one
injection point, `api.openUrlStartFake` + `api.NetFixture`, and it is
**deliberately not in `api/lesssheet.h`** so that header stays byte-identical.

So the `net` target starts its job through that Zig seam and does everything
else — `ls_net_open_poll` / `cancel` / `release`, and the entire read surface of
the document the job produces — through the same C ABI as the other three
targets. Only the byte provider is injected; the reducer, the spool, the fill
strategies and the gzip composition are production code on their production
path. This is the same seam the frozen net suite uses.

## Measured behaviour (2026-08-04, M-series mac, ReleaseSafe)

Seed replay, each target isolated with `-Donly`:

| target | entries | replay |
|---|---|---|
| `csv` | 219 | clean, 27 s |
| `gz_raw` | 146 | clean, 21 s |
| `gz_trunc` | 31 | clean, 21 s |
| `net` | 70 | clean, 21 s |

The committed campaign log (`campaign/`) is the accumulated state of three runs of
5000, 5000 and 2000 iterations per target: **32 676 runs, 2382 unique,
4415/22085 PCs (19.99%), no crash, exit 0** — and all seven AC-c1 hotspot modules
entered:

```
csv_reader ENTERED 427/733    source     ENTERED 284/497    net_source ENTERED 180/364
window     ENTERED 184/370    index      ENTERED 138/316    search     ENTERED 115/433
encoding   ENTERED 291/343
```

This is a SMOKE campaign proving the harness reaches the code (AC-c1), not the
AC-c2 campaign — that one needs orders of magnitude more iterations, and F1 fixed
first.

Other project files reached in the same run include `lexer` 92%, `sniff` 94%,
`root` (the C-ABI entry points) 74%, `matcher` 41%, `filter` 40%, `column` 42%.
19.30% of the whole binary is unremarkable — most of the rest is std — so read the
per-file table, not the global number.

**One open finding already, F1** — see `findings/README.md`. It is a *hang*
(`ls_open` never returns on a UTF-16 stream with an odd trailing byte over a
streaming source), it is reachable with default options, and it **blocks the AC-c2
campaign** until fixed. A quarantine keeps the harness runnable meanwhile; `fuzz.sh`
prints every quarantine in force at the top of each campaign log.

## The matcher differential oracle (`zig build diff`)

```sh
zig build diff             # deterministic sweep: 5 fixed seeds x 4000 cases
zig build diff --fuzz      # the same checks, coverage-guided (Smith-driven)
zig build test             # runs the corpus replay AND this oracle
```

The four targets above are crash oracles: they assert nothing about returned
values, because "the process survives" is the property a fuzzer can check
cheaply. `matcher_diff.zig` is the opposite and exists for one reason: the
scan-side matcher (`matcher.StreamCell`) carries the throughput work — an early
verdict exit, a pre-folded query, and a **vectorized anchor prefilter** that
skips positions the scalar KMP would have rejected. A false negative there drops
matches *silently*: no panic, no leak, just a wrong count. Nothing else in this
directory could see it.

So it checks three implementations of ONE verdict against each other, per case:

| implementation | who uses it in production |
|---|---|
| a naive brute-force compare written in the oracle | nothing — it is the reference |
| `matcher.cellMatches` (whole cell) | `ls_window_match_flags`, nav re-lex, filtered-window predicate |
| `matcher.StreamCell` (streaming) | the full-file search / filter / count scan |

`cellMatches` and `StreamCell` are deliberately two implementations (see the
comment at `matcher.cellMatches`) so a row match and a cell highlight can never
disagree — for the ordering predicates they are genuinely different algorithms
(exact-decimal parse-and-compare vs an incremental digit FSM), and the oracle is
what pins them together.

Two generation details do the real work, and both are load-bearing:

* **queries drawn as substrings of the cell** (half the cases, with random case
  flips) — a random query almost never matches, so a false negative would hide
  behind a random "no" forever;
* **every awkward feed split** — one call, 1/2/4-byte units (the decode-per-unit
  streaming cursor path), and cuts at 15/16/17/31/32/33/63/64/65… because the
  prefilter only claims positions with a full block plus lookahead left and hands
  the tail back to the scalar KMP, which is the only path allowed to end
  mid-match.

**Verified sensitive, not just green.** Green is not evidence on its own, so the
oracle is kept honest by planting known defects and confirming each is caught.
All five below were re-run against the current tree; each fails within the first
seed, most via a split-feed check:

| planted defect | what it would break in production |
|---|---|
| `i += anchor_vec_len + 1` in the prefilter | vector skip steps over one candidate position per block |
| `feedTextScalar` reads `q.value` instead of `q.folded` | case-insensitive search misses matches |
| `Query.clone` derives no failure table | every worker snapshot (so every full-file scan) loses the KMP table — panics in ReleaseSafe |
| prefilter guard `if (k == 0)` → `if (true)` | skipping while a match is in progress, i.e. discarding KMP state |
| `anchor1_upper = a1` (drops the uppercase twin) | folded second-byte anchor stops matching uppercase input |

The last two pin the exact two conditions the optimization rests on: that the
prefilter runs **only** at cursor 0, and that a folded anchor compare needs
**both** case twins. Re-run this list after touching `feedText`, `Query.init` or
`Query.clone`; a mutation that is no longer caught means the oracle stopped
covering the thing it exists for.

It reaches `StreamCell` / `cellMatches` / `Query` through the single dev-tool
re-export `matcher_internals` in `backend/src/root.zig`. A module rooted at
`src/matcher.zig` would be the obvious alternative and does not work: every file
under `src/` would then belong to two modules at once (`api` already pulls
`src/root.zig` in as `core`), which the compiler rejects.

## Files

| file | role |
|---|---|
| `harness.zig` | the four fuzz targets + the shared `exercise()` drive sequence |
| `matcher_diff.zig` | the matcher **differential oracle** — a VALUE check, see below |
| `gzbuild.zig` | gzip/deflate construction, shared by the harness and the generator so a baked-in cut offset means the same stream in both |
| `seeds.zig` | comptime loader for the four `.pack` corpus files |
| `seeds/*.pack` | **the committed corpus** (466 entries) |
| `seedgen.zig` | builds the packs; also `append`, the regression path |
| `covreport.zig` | decodes the fuzzer's coverage map and checks the AC-c1 hotspot list |
| `findings/` | open findings + their reproducer inputs and standalone driver |
| `fuzz.sh` | the one documented command |
| `campaign/` | campaign logs |

`build.zig` here is a **separate dev build graph** rather than a step in
`backend/build.zig`, because that file is a frozen dependency path
(`backend/.aidev/profile.sh`: `DEPENDENCY_PATHS=( "build.zig" )`) an implementer
may not edit. This graph rebuilds the same two-module core the shipped static
library is built from (`src/root.zig` ⇄ `contracts/api.zig`, libc linked), so the
harness compiles the same code — the contract's comptime C-ABI signature pins
included.

## The seed corpus

466 entries across four packs, from three sources (AC-c1: "seeded from the
`csvgen` corpus + adversarial gz/truncation/wide/ragged seeds"):

1. **The `tools/csvgen` catalog** — all 60 light cases, generated with `--gzip`
   at seed 1337 so the `gz_raw` arm is seeded from the same catalog the gate
   already runs.
2. **A built-in adversarial set** (`seedgen.zig`) covering what a
   correct-by-construction generator cannot emit: unterminated quotes, lone
   quotes, quote soup, embedded NULs, lone-CR and mixed line endings, all five
   encodings including a UTF-16LE BOM with an odd trailing byte, a UTF-8-encoded
   surrogate, a truncated UTF-8 sequence, a 4000-column record, a 20 KB cell (past
   the 4 KiB cap), a 30 KB never-closed quote, ragged records, the
   formula-injection vectors (`=`/`+`/`-`/`@`), and number-grammar edges.
3. **The gzip damage matrix and the two `flate_b1` regression cuts** — fixture A
   cut 50 and fixture B cut 16891 (`review/REVIEW-flate-feed-guard.md`), the
   mid-symbol truncations that produced a *complete, exact, wrong* document before
   the wave-(b) fix. They are byte-exact because `gzbuild.zig` reproduces the
   frozen suite's `deflateRaw`/`gzMember` settings and the generator computes the
   cut against the real stream length (A: 650 bytes, keep 50; B: 36648, keep
   16891).

### Seed format, and why it is a flat pack

A pack is `u32le len || len bytes`, repeated. Each entry is a
`std.testing.Smith` **replay blob** — the wire format Smith documents itself:

```
u32le n || n document bytes || u64le w0 || u64le w1 || u64le w2 || u32le m || m needle bytes
```

Two properties fall out of this, both used:

* **`zig build test` replays the whole corpus deterministically.** Without
  `-ffuzz`, `std.testing.fuzz` runs each corpus entry once through the target
  (`compiler/test_runner.zig`). So the corpus doubles as a regression suite, and a
  fixed crash is verified by replay rather than by re-fuzzing.
* **Corpus entries cannot be culled.** `options.corpus` entries are registered
  below the fuzzer's mutable watermark, unlike an on-disk pre-seed, which the
  fuzzer deletes if it does not win a coverage "best".

The three `w` words are bit-sliced into knobs rather than drawn one Smith value
per knob, so a seed's knob tail is exactly 24 bytes with no per-knob encoding for
the generator to keep in sync — and **all-zero words are a well-formed, in-range
drive that on its own reaches every hotspot module**, which is why the generator
never needs to know `harness.zig`'s bit layout. `harness.zig` carries two
self-check tests that pin the blob round-trip and the corpus floor.

## Triage loop (AC-c2)

On a crash the fuzzer saves the offending input to `.zig-cache/f/crash` and fails
the step. `fuzz.sh` reports it. To close the loop:

```sh
./zig-out/bin/seedgen append seeds/<target>.pack .zig-cache/f/crash   # permanent seed
zig build test                                                        # replays it -> reproduces
# ... fix the core in backend/src/ ...
zig build test                                                        # must now be clean
bash tools/fuzz/fuzz.sh <iters> --fresh                               # re-run clean
```

`.zig-cache/f/crash` is a single fixed filename that a later crash overwrites —
copy it out before continuing.

## Stopping criterion (AC-c2)

AC-c2 wants a *recorded* criterion. The three supported shapes:

* **Iteration-boxed** — `fuzz.sh <N>` runs N iterations *per target* (Zig's
  `--fuzz=N` limit is per fuzz test, counted in mutation cycles). The log records
  N, the wall time, and the final coverage.
* **Wall-clock-boxed** — `fuzz.sh --minutes M` lifts the iteration cap and stops
  the campaign after M minutes. A process-group watchdog does the stopping, and a
  flag file makes a budget expiry distinguishable from a finding in both
  directions; the coverage map is mmap'd and updated live, so it survives.
* **Coverage plateau** — run repeatedly *without* `--fresh` (Zig accumulates both
  corpus and coverage across runs) until `PCs covered` stops moving between logs.
  Each log carries the number, so the plateau is evidenced by the log sequence.

### An iteration is not a unit of work — do not compare N across versions

The csv target draws **synthesized document shapes** (see `oneCsv`), and they
differ in cost by two orders of magnitude:

| shape | document | share of draws | share of csv seeds | cost |
|---|---|---|---|---|
| ordinary | ≤1 MiB, the `rep` amplifier | 55/64 | 202/219 | ~1-5 ms |
| `many_rows` | >2048 rows, ~166 KiB | 8/64 | 15/219 | ~5 ms |
| `deep` | >8 MiB, forces the off-main filtered nav | 1/64 | 2/219 | **~82 ms** |

So "200,000 iterations per target" means different work for different harness
versions, and two campaign logs are **only** comparable by iteration count if they
ran the same harness. `fuzz.sh` prints a `budget:` line naming the unit and the
shape table for exactly this reason. **Use `--minutes` when comparing versions.**

Measured example (M-series mac, 10 minutes each, same machine and build config):
the pre-shapes harness managed 741,398 runs and the current one 365,724 — half the
iterations for the same wall clock, because a filtered second search pass is real
work. Coverage went *up* (5030 → 5566 PCs) on half the iterations.

The shape sentinels are **non-zero on purpose**. 93 of the 219 committed csv
entries carry `w0 == 0` exactly (the generator zeroes the knob words), so a
`shape == 0` selector does not mean "1 in 64" — it means "the default for 43% of
the corpus". Choosing `0` for the >8 MiB shape once turned a 20k-iteration smoke
run into an 18-minute one. Whatever an absent or zeroed draw decays to is part of
the design, not an accident — the same reason `csv_bytes` covers all of 0..255.

Note `--fuzz=N` is headless and single-instance; bare `--fuzz` (no limit) instead
runs forever across all cores with a web UI, and the two cannot be combined.

## Reading the coverage report

```
-- required hotspot modules (AC-c1) --
  csv_reader   ENTERED      412/1130 PCs in 1 file(s)
  ...
```

Counts are instrumented basic blocks (PCs), not lines; "seen" means executed at
least once, accumulated across every run sharing the cache. Module names are
matched on the file *stem*, not as substrings — otherwise `source` would silently
claim `net_source.zig`, which is exactly the distinction AC-c1 enumerates both
for. `covreport` exits 2 if any required module was never entered.

`--all` also lists std/compiler-rt files; the default shows project files only.

### Aiming: `--cold <module>`

A per-file percentage says a module is weakly covered; it does not say *which*
code was never entered, which is the only thing that tells you what to change in a
target. `--cold` resolves each PC to its line, attributes it to the enclosing `fn`
by parsing the module's own source, and prints per-function seen/total plus the
cold line ranges:

```sh
./zig-out/bin/covreport <binary> <coverage-map> --cold search,window
```

```
-- cold regions: search.zig  118/433 PCs seen --
  function                           lines  seen/total     cold
  resolveNavLockedFiltered            436-495      0/31        31   NEVER ENTERED
  filteredNavFitsBudget               359-396      0/29        29   NEVER ENTERED
  ...
```

That output is what turned "`search` is at 27%" into "the entire filtered
coordinate half is unreachable because `exercise` cancelled its search *before*
setting the filter" — a one-line ordering bug in the harness worth 210 PCs. It is
report-only and never changes the exit status, so the AC-c1 gate property is
unaffected.

Two practical notes:

* Pass the **fuzz-mode** binary (`.zig-cache/o/<hash>/lsfuzz`, rebuilt by
  `--fuzz`), not the plain test binary. With the wrong one almost nothing resolves
  and every module reads as near-zero — a mismatch that looks like a coverage
  collapse rather than an error. `fuzz.sh` picks it via a timestamp marker.
* `covreport` writes to **stderr** (`std.debug.print`). Capture with `2>&1`, not
  `2>/dev/null`.
