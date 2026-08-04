# tools/fuzz — the pre-launch fuzz harness

Coverage-guided fuzzing over the less-sheet C ABI. This is the dev tool for
**security-hardening wave (c)** (`docs/architecture/ARCH-security-hardening.md`,
AC-c1 / AC-c2 / AC-c3). It is **not gate-blocking** — AC-c3 calls the campaign a
one-time pre-launch cadence, so nothing here runs in `.aidev/gate.sh`.

## The one command

```sh
bash tools/fuzz/fuzz.sh                   # 20k iterations per target (smoke)
bash tools/fuzz/fuzz.sh 5000000 --fresh   # a real campaign, from the seeds only
```

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

## Files

| file | role |
|---|---|
| `harness.zig` | the four fuzz targets + the shared `exercise()` drive sequence |
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

AC-c2 wants a *recorded* criterion. The two supported shapes:

* **Iteration-boxed** — `fuzz.sh <N>` runs N iterations *per target* (Zig's
  `--fuzz=N` limit is per fuzz test, counted in mutation cycles). The log records
  N, the wall time, and the final coverage.
* **Coverage plateau** — run repeatedly *without* `--fresh` (Zig accumulates both
  corpus and coverage across runs) until `PCs covered` stops moving between logs.
  Each log carries the number, so the plateau is evidenced by the log sequence.

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
