# Wave (c) — the fuzz campaign

**Status: AC-c1, AC-c2 and AC-c3 all satisfied.** Branch `feat/kbdnav-a11y`.
ROOT gate green. Tool: `tools/fuzz/`, one command — `bash tools/fuzz/fuzz.sh [iters] [--fresh]`.

| | |
|---|---|
| Harness | `cb4a9f9` (AC-c1 + AC-c3) |
| Defect it found | F1 — lock `d938819`, fix `d8f4c31`-class commit (see below) |
| Quarantine lifted + regression seeds | `25b3819` |
| Campaign log | `tools/fuzz/campaign/campaign-MAC-mac-20260804-180031.log` |

## The campaign

- **902,418 runs**, 8,081 unique, four coverage-guided targets over the C ABI.
- Built **ReleaseSafe** — the shipped mode, so a Zig safety panic counts as a crash.
- Stopping criterion, recorded per AC-c2: **200,000 iterations per fuzz target**.
- **Zero crashes, zero OOMs, zero hangs. No crashing input saved.**
- Seed replay exit 0 before the campaign: every committed corpus entry, deterministically.

All seven AC-c1 hotspot modules **entered**, and this is *checked* rather than asserted —
`covreport.zig` decodes the fuzzer's own coverage map, resolves PCs via `std.debug.Info` with no
external symbolizer, matches on file stem so `source` cannot claim `net_source.zig`, and **exits 2 if
any required module was never entered**.

| module | PCs | | module | PCs |
|---|---|---|---|---|
| `csv_reader` | 559/749 (74.6%) | | `index` | 177/316 (56.0%) |
| `encoding` | 426/475 (89.7%) | | `net_source` | 193/364 (53.0%) |
| `source` | 325/521 (62.4%) | | `search` | 118/433 (27.3%) |
| `window` | 227/370 (61.4%) | | | |

Also incidentally high: `reader` 18/18, `lexer` 153/166, `sniff` 51/54, `root` 180/229.

## What it found: F1 — `ls_open` never returned

**Found on the harness's own seed corpus, before any campaign started** — i.e. the tool paid for
itself before it ran in anger.

`ls_open` hung forever, with no error, no cancellation and no timeout, when the decoded stream was
**UTF-16 ending on an odd byte** and the source was a **streaming** one (local gzip, and the network
source). Reachable from **3 bytes** with default options, because `encoding = auto` sniffs the BOM.
`index_manual` hung too, so it was not the background scan lane.

**A hang, not a crash — which is why nothing had ever caught it.** Zig's fuzzer has no per-iteration
watchdog, so one hit stops a campaign silently and forever; no gate assertion times out a synchronous
C-ABI call either. It had survived every prior round of testing on this branch.

**Root cause.** `enc.decodeUnit` returns null for a unit running past the bytes handed to it. On mmap
the *caller* resolves that against `content.len` (`lexer.recordBounds` → `next = limit`). The
streaming arm had **no end-of-stream verdict at all** — it returned `next == pos, capped = false`,
neither advance nor stop — so every frontier loop re-issued the identical call forever. Each call
returned promptly; the caller's re-issue was infinite.

**The same cause had a silent second face.** `scanRows` broke *before* counting the stub row, so a
>4 MiB UTF-16 gz file did **not** hang — it opened successfully and reported **354,999 rows against
the plain file's 355,000**. A hang is noticed; a dropped row may not be. Both were one defect.

**The lock had to be written below `ls_open`,** because a frozen test that called it would hang rather
than fail and take the 285-test suite with it. The planner froze the progress invariant the spin
violates — a streaming row scan must **advance, report capped, or land on atEnd, never none of the
three** — plus a parity test asserting the gzip Source presents the same rows and terminus as mmap for
the same bytes. That parity arm exists to reject the lazy repair: answering "capped" terminates the
loop but leaves the document permanently incomplete. RED by *failing* in 30 s, not by hanging.

**Fix:** `Cursor.danglingTail(in_hand)` returns the sub-unit residual only when `knownEnd()` is
published *and* every byte up to it is in hand — so an artificial cap still reports capped and
not-yet-arrived bytes still stall retryably. `csv_reader`'s single peek+decode site is split into
`peekUnit` (pure lookahead — must not consume, or the CRLF lookahead swallows a row mmap still
reports), `streamUnit` (publishing decode, drops a genuine stub so the cursor lands on the true end)
and `streamHasRow`. A malformed half character is **dropped**, matching what mmap already did; its row
presents as a normal final row with empty cells and the document is complete.

Verified: 355,000 == 355,000 after, AUTO and MANUAL, `scanned == total`, `exact=1`. Reproducers
re-run by the orchestrator against the ReleaseSafe library at a 12 s deadline — all four return
`status=0`, where `FF FE 41` and the 11-byte case previously never returned.

**Perf, and it went the right way:** gz search 10194 → 9769 ms (−4.2%), filter 10210 → 9768 (−4.3%),
index 3017 → 3038 (+0.7%), plain mmap control within ±1%. A naive version cost **+15%** by losing
`streamUnit`'s inlining; `inline` + `@branchHint(.unlikely)` on the cold tail recovered it.

## The quarantine, and what lifting it bought

Until F1 was fixed the harness had to pin `encoding = UTF-8` on the three streaming targets, because
auto-detection selects UTF-16 from a BOM by itself and one hit wedged the campaign. Lifting it
recovered real coverage: `encoding` **291/343 → 426/475**, `csv_reader` 489 → 559, `search` 114 → 118.
So the defect had been hiding a chunk of the parser from the fuzzer as well as hanging the app.

Both reproducers are now permanent seeds in `seeds/gz_raw.pack` (framed as vanilla Smith blobs so they
drive with `encoding = auto`, which is what the defect needs), and the corpus replays clean with them
in. The network arm needed no new seed — `net.pack` entry 40 already carried it and went RED the
moment the quarantine lifted.

## Scope notes and residue

- **Network reachability.** There is no C-ABI route to `net_source` (`ls_open_url_start` needs a live
  server), so only the job *start* uses the Zig seam `openUrlStartFake`/`NetFixture`; poll, cancel,
  release and the whole document read surface stay C ABI. `NetFixture.withhold` is excluded — its
  contract requires the test to raise a gate, which a fuzz target cannot honour.
- **The net arm of F1 is not locked in-process.** `openUrlStartFake` runs the fake open synchronously,
  so a net repro would hang the test binary. Both arms execute the same
  `csv_reader.boundsFromCursor`, and `net.pack` entry 40 is its standing check.
- **`search` at 27.3%** is the lowest of the seven. Not a defect, but the obvious next place to point
  the fuzzer — most of that module is reached only through richer query shapes than the current
  targets draw.
- **Pre-existing, recorded, not fixed here:** mmap reports `ls_cell_truncated = 1` on the last cell of
  any file with no trailing newline (`lexInto`'s `was_truncated = truncated or hit_limit`) while gz
  reports 0. Identical before and after the F1 fix.
- The tool lives in `tools/` rather than `backend/` because `backend/build.zig` is a frozen dependency
  path; `tools/fuzz/build.zig` rebuilds the same two-module core so the contract's comptime C-ABI pins
  still compile.
