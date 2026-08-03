# Network-gzip mutex-held wedge — the last unbounded route in the signed security ARCH

**Status: CONVERGED — reviewer PASS at `7fcdd84`** on an orchestrator-run `--require-frozen` gate
(284/284, csvgen 142/0, `zig fmt`, native ReleaseSafe + both musl crosses, `api/lesssheet.h` 0-line).
Two review rounds. Branch `feat/kbdnav-a11y`.

| | |
|---|---|
| Freeze | `eaaa48f` (`netgz1`) |
| Build | `181fb96` (round 1), `7fcdd84` (round 2) |
| Signed design | `docs/architecture/ARCH-security-hardening.md` `:444-449` — AC-e1's explicitly excluded case |
| No ARCH amendment needed to *fix* it | AC-e1's claim was already scoped to exclude gz, so closing it strengthens the claim rather than contradicting signed text |

## The defect

The ARCH named it precisely and left it open:

> **STILL UNBOUNDED for network gzip — open, its own cell:** a commit-side bound cannot cover it.
> `Gzip.produce` calls `ensureCompressed(seek + chunk_bytes)` unconditionally on every inflate op — a
> fixed read-ahead, not a demand the row needs … So **"bounded by user cancel" holds for open, for
> close-via-the-worker, and for plain net CSV — NOT for network gzip.**

`ensureCompressed` blocks on a ranged GET or a sequential drain, so a read from the UI thread waited on
the peer. Measured by the lock: `ls_window_set` issued **5 / 5 / 2 ranged GETs** at 64 / 2 000 / 50 000
rows behind the frontier, `ls_cell_copy` 4 more. Third instance of this wedge family on the branch
after `a5c3a69` and `b69f765`, and the one the commit-side guard provably could not reach.

## The fix

`produce` calls `presentCompressed(want)` when the caller lacks a **fetch permit** — the compressed
twin of `commitBoundNoFetch`: same formula over the present extent, no GET, no drain, and deliberately
**no lock**, because `ensureCompressed` holds the provider mutex *across* its blocking `fetchInto`, so
even acquiring it would queue the UI behind a silent peer. Byte-identical to `ensureCompressed`
whenever the prefix is present.

The permit is a thread-local, **default deny**, opted into by three designated fetcher bodies:
`index.workerMain`, `net.runFake`, `net.realWorker`. Ambient rather than a parameter because the
discriminator is the call stack, not the data — `cursorAt` and `csv_reader` are shared verbatim between
worker and window lane, and `sourceCursorAt`'s signature is frozen. Default-deny fails loud (the
frontier stops) rather than silent (the UI wedges).

A UI read with absent bytes parks `.budget`: resumable, no rows served, no terminal published. Two
guards are both required — `fenceCanMove`, and `mayPublishTerminal`, which prevents a conclusion drawn
at an artificial fence from moving the document's end **down** (a truncation caused by a read, on a
healthy peer).

**Round 2 — F2, and the shape of the answer matters.** The reviewer asked whether a permit-less read
could strand `.damaged` on lane 0, the shared forward session that `Cursor.deinit` resets only out of
`.budget`. It could: `cursorAt` takes lane 0 when `internal >= forward_logical`, and that path reaches
`produce`. Fixed by construction rather than by argument:

```zig
if (may_fetch) return hr.awaitsBytes();
return hr.awaitsBytes() or self.terminal_kind.load(.acquire) == 0;
```

The permit-less answer is the permitted answer **OR** one more reason to park — pointwise never less
true. Since `.damaged` requires `!resumable`, a strictly larger `resumable` set can only *shrink* the
`.damaged` set. So no permit-less op can strand any session, lane 0 included, and where the answers
differ the outcome is `.budget`, which `produce` lifts when the fence rises. The reviewer re-derived
this independently from the pre-cell predicate rather than accepting it.

The round-1 formulation was also a latent regression on the sequential arm (`awaitsBytes()` true with
`terminal_kind != 0` returned false where baseline returned true); the `or` removes it.

## Evidence

**The lock (`netgz1`, planner).** Asserts on `NetFixture.fetch_attempts` that no mutex-held path raises
the tally. The planner needed **four fixtures** to find the driving condition, which the test
documents: the row must be past the inflated open head (a read inside `Gzip.head` never runs an inflate
op) **and** its compressed position within one chunk of the fetched edge. Satisfiability was verified,
not assumed — with only the two tally assertions relaxed in a scratch copy the test passed fully, so
nothing but the mutex-held fetching separated RED from GREEN.

**Orchestrator probe on the ARCH-named path** (`windowSetFiltered`, which the ARCH calls the
ship-blocker), both fixtures, `fetch_attempts` sampled around each call:

```
[bounded] windowSetFiltered back=64 / 2 000 / 50 000 → 5→5, 5→5, 5→5, rows=64 each
[bounded] ls_search_nav                              → 5→5
[healthy] windowSetFiltered back=64 / 2 000 / 50 000 → 5→5, 5→5, 5→5, rows=64 each
[healthy] ls_search_nav                              → 5→5
```

The **healthy-peer** run is the strong result: that is the silent-truncation scenario the guard exists
for — every declined read-ahead sitting one chunk below an edge the scan will raise moments later — and
it comes back at zero transport requests *with correct rows*.

**Drive sequence, recorded because two roles got it wrong first:** a filtered network view advances only
under a *filtered jump* (`index.zig:137` gates the filter's own background scan on `!doc.net`), so the
order is `ls_filter_set` → `ls_jump_start` → wait for the landing → measure. My first two attempts set
the filter after the jump had already landed, and concluded — wrongly — that the fixture shapes were
incompatible.

## Perf — accepted on mechanism, NOT on measurement

Reported: gz index scan 904.3 → 901.8 ms (−0.28%). But the untouched mmap control moved **−9.15%**
between the two binaries, which puts the harness's resolution floor near ±9% and makes the gz number
carry no information. The reviewer accepted anyway, on mechanism: the round-2 delta is one boolean
disjunct in a function called once per inflate op with no per-byte work, so there is no route by which
it could cost measurably.

**Escalated rather than carried a third time:** this project currently **cannot detect a sub-10%
regression on the gzip path.** There is no gz-over-network bench fixture at all, so for two consecutive
cells the code under review has had no NFR measurement of its own subject, and the bespoke harness's
control swings ±9% on unchanged code. Against a standing bar of "be maniacal about performance, measure
every perf change", the instrument is the weakest link in the loop. A gz fixture plus a control stable
to ~1% would make the next cell's perf claim mean something.

## Out of scope, with reasons

- **Instance 2, `column.zig:1051`'s mutex-held lane acquire.** It acquires with the mutex held, so no
  foreground call can hold a lane at that moment (it needs the same mutex) and nothing retains a lane
  across calls — the copy cursor keeps a `Pos`, not a lane. A network-stalled lane holder is therefore
  always the mutex holder, i.e. instance 1. Latent lane-starvation, not a drivable wedge.
- **The sequential-fill arm** has no hermetic driver (measured both ways: `withhold` never gets the
  frontier past the open head; under `drop_after` EOF is known so no transport call happens).
- **`LS_FILTER_CANCELLED` is NOT a defect.** A filter on a network document reaching `.cancelled` with a
  populated partial view looked wrong, and the reviewer's first lean was that it might be. The frozen
  ABI settles it (`api/lesssheet.h:953-957`): active filter, scan stopped before EOF, counts frozen,
  view still filtered and resumable, with `total_exact = false` as the frontend's discriminator. That is
  exactly what was measured, on both a bounded and a healthy peer. No cell.

## Carried out

1. **The ARCH text now UNDERSTATES what the code guarantees.** `:444-449` still says "STILL UNBOUNDED
   for network gzip", and scopes "bounded by user cancel" to open, close-via-the-worker and plain net
   CSV, "NOT for network gzip". Both are false now. A signed document understating the guarantee is the
   direction that makes future roles re-open settled work — wants an amendment recording the closure and
   the mechanism. **This is signed acceptance-criteria text, so it is the architect's + the author's, not a
   prose fact-fix.**
2. **`api/lesssheet.h`'s `LS_FILTER_CANCELLED` cause list** says "a jump-scan or match-scan took the
   slot", which does not describe the network case (the filtered jump that *was* driving the scan
   landed, and nothing else drives it). Prose only, root planner's.
3. **`netgz1` re-freeze** (planner): fix the false premise that `ls_window_set` holds the Document mutex
   throughout — `window.windowSet` locks only for snapshots — add the filtered arm at the three
   distances plus `ls_search_nav`, and record the drive sequence in the test's own comment.
4. **Frontend check:** both frontends preserve `total_exact` through to their snapshot types
   (`CoreDocumentSession+Search.swift:187`, `lsg_filter.c:169`), but the *render* sites for a paused
   filter are unconfirmed — macOS has no filter-specific one, GTK has `lsg_filter.c:107`. A paused
   filter must read as a partial count, never as a cancellation.
5. **Watch item on the permit.** Its correctness rests on an enumeration that is small and complete
   today, but a fourth designated-fetcher body added without a permit fails as a silently stopped
   frontier, not a compile error. The `fetch_permit` block comment is the thing to update in the same
   commit, and `publish` is the cheap place to re-verify coverage.
