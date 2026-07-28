# REVIEW — `net_close_hang`: `ls_close` froze forever on a wedged network peer

Decision record written by the orchestrator at convergence. Cell: native Opus-5 implementer ⇄ native
Opus-5 reviewer, 1 round. Branch `feat/kbdnav-a11y`, base `bade23e`. Fixes finding 9 filed forward by
`review/REVIEW-security-w2b-net.md`. the author directed this ahead of the remaining security waves as
ship-blocking.

## Outcome

**Reviewer verdict: PASS, cell closed**, with one `[impl]` finding carried forward as a NEW open
ship-blocker (see below). Trusted gate re-run by the orchestrator: **PASS** — ReleaseSafe native +
aarch64/x86_64-linux-musl, `zig fmt --check` clean, 273/273 behavior tests, csvgen 142/0, flat RSS.
`api/lesssheet.h` **byte-identical** (`git diff --stat -- api/` empty) — internal fix, no ABI change.

## The defect

After a successful network open, with the document's background scan worker parked in `fetchInto`
against a peer that accepts and then stops answering, `ls_close` never returned. User-visible as a
permanent app freeze on window close.

Measured by the orchestrator, same harness both sides, preconditions confirmed identical in each run
(`jump state=1`; server log `req#4: GOING SILENT`):

```
BEFORE (bade23e):   [5.11s] calling ls_close() NOW
                    PROBE_EXIT=137            <- SIGKILLed at 90 s, never returned
AFTER  (this cell): [5.11s] calling ls_close() NOW
                    [5.11s] ls_close() RETURNED after 0.003s
```

Harness: `probe_close.c` + `half_silent.py` (a range server that serves N requests then
accepts-and-never-answers).

## The fix

`base.Worker = union(enum) { thread: std.Thread, task: std.Io.Future(void) }`; `Document.worker` is
`?Worker`, constructed and torn down only by `startWorker` / `joinWorker`. Network documents get an
`io.concurrent` task on the process-global `netIo()`; local documents keep the raw `std.Thread`.
4 files, `src/` only.

**Both halves are required, and this is the load-bearing part.** Cancellation is **one-shot, not
sticky** — `Io.zig:1183-1188` states it, and `Threaded.Syscall.start:1345-1366` implements it: a
`.canceled` thread returns `.{ .thread = null }`, i.e. back to *uncancellable* syscalls. So
`Future.cancel` alone could not stop a retry loop from re-blocking. `sourceShutdown`'s flag prevents
the *next* fetch; `Future.cancel` unblocks the *current* one. `ls_close` already ordered them
correctly. The reviewer re-derived all of this from std rather than accepting the citations.

## Design decision: branch on `doc.net`, not one uniform path

The implementer branched; the reviewer verified and accepted. The decisive argument is **not**
performance:

`Threaded.init` unconditionally installs **process-wide SIGIO/SIGPIPE handlers**
(`Io/Threaded.zig:1653-1663`). Going uniform would call `netIo()` on every open, so a CSV viewer
opening a purely local file would mutate the host process's signal disposition. The branch actively
*preserves* the `sec_w2b2` signal-policy condition rather than merely not breaking it — handler count
stays one, SIGBUS untouched, wave (g) unaffected.

Single-source-of-truth verified: the reviewer checked all 22 `worker` references; every site outside
`startWorker`/`joinWorker` is a bare null-test, none re-derives net-vs-local, none inspects the union
tag. `doc.net` is the pre-existing computed-once resolver from `sourceIsNetwork`, not a new knob.

## Performance — no regression

Orchestrator's own BEFORE/AFTER (`tools/bench/less_sheet_bench.py`, **ReleaseSafe on both sides** —
the script defaults to ReleaseFast, so `--lib` was passed with ReleaseSafe builds; BEFORE from a clean
worktree at `bade23e`), M2 Pro, warm:

| fixture | op | BEFORE | AFTER | delta |
|---|---|---|---|---|
| 500MB | index_scan | 964.57 ms (0.544 GB/s) | 945.74 ms (0.554) | -2.0% |
| 500MB | search_scan | 1583.67 ms (0.331) | 1543.70 ms (0.340) | -2.5% |
| 500MB | filter_scan | 1547.02 ms (0.339) | 1499.32 ms (0.350) | -3.1% |
| 500MB | open | 12.16 ms | 11.37 ms | -6.5% |
| 500MB | first_window | 0.05 ms | 0.05 ms | 0.0% |
| 500MB | copy_rows | 466.05 ms | 468.29 ms | +0.5% |
| 50MB | index_scan | 93.35 ms | 87.63 ms | -6.1% |

The implementer's independent run disagreed in **sign** on the 500MB scans (+0.3/+1.1/+0.7% vs the
above). Both sets sit inside single-machine noise and both are consistent with the local arm being
byte-identical by construction (same `std.Thread.spawn`, same `join`). Honest conclusion: **no
measurable effect either way**, not "it got faster". No regression on any op; cold-start and
first-window budgets untouched.

## NEW OPEN SHIP-BLOCKER — the same freeze class is still reachable by another route

The implementer filed `window.windowSetFiltered` forward as "appears unreachable". **The reviewer
disagreed, and the orchestrator verified the reviewer is right.**

- `Cursor.peekHttp` (`source.zig:700-718`) caps `avail` by `self.limit`, `hr.knownEnd()` and
  `physical_limit` — and the comment states outright that it is capped **"NEVER by the current
  fetched extent"**, deliberately, so `ensureSlice` drives the sequential drain past the head.
- So a peek can straddle a chunk boundary; `ensureSlice:847-849` then calls
  `ensureChunkRangeLocked(first, last)` on a not-present chunk → a live `fetchInto`.
- `ensureChunkRangeLocked` drops only the **HttpRange** mutex, not the Document mutex.
  `windowSetFiltered` (`window.zig:231-233`) holds `d.lock()` for the whole call.
- Against a silent peer that GET is unbounded, so `ls_close` blocks at `d.lock()` (`root.zig:143`)
  *before* reaching `sourceShutdown`/`joinWorker`. The cancel cannot reach it: the blocked thread is
  the caller's, not the task's.

The implementer's eviction sub-claim was correct and re-derived (`evictLocked:736-752` clears
`resident` but never `present`; a present chunk cannot re-fetch). The hole was "re-lexes behind the
frontier" — behind-the-frontier is not the same as inside-a-present-chunk, because reads are
chunk-granular and can overshoot. A filtered jump to the newest filtered row parks the window exactly
there. Rare is not unreachable.

**Pre-existing** — it would hang identically at `bade23e` — so not a regression from this diff, and
deliberately not chased here. Needs its own cell, scoped to the **mechanism, not the one function**:
any main-thread entry point holding the Document mutex across a `Cursor.peek` on an `http_range`
source has this shape. Candidate fixes: cap the mutex-held read, or cap `peekHttp`'s `avail` so a
Document-mutex-held read never triggers a fresh fetch. The reviewer asked for a confirming probe
first; that is the next cell's first task. Note `windowSetFiltered`'s own comment ("bounded … still
safe on the caller/UI thread") is now demonstrably wrong for net documents.

`spanHttp` (`source.zig:729-733`) IS bounded to the next chunk boundary and is safe. `peekHttp` is the
one that is not.

## Non-blocking notes from the reviewer

- `ensureCompressed:879-883` (random-fill branch) is the only one of four blocking-fetch loops with no
  `shutdown` re-read; it is safe today by an *arithmetic* bound (`comp_fetched` advances a full chunk
  per iteration regardless of fetch success, so at most one `fetchInto` per call) rather than a flag
  check. Not a hang, so not a finding — but add the check for consistency if the file is touched
  again, and the bound is currently unstated.
- `sysio.sleepMs` routes through `io().sleep(...) catch {}`; on an executor-owned thread that IS a
  cancellation point, so a pending cancel can be swallowed there rather than by the fetch. Harmless
  only because both call sites re-check `shutdown` before any further transport call. Worth a sentence
  in the `joinWorker` comment.

## Process note

Perf baselines were captured in ReleaseSafe deliberately. The bench script defaults to ReleaseFast,
which is **not** what we ship — always pass `--lib` with a ReleaseSafe build when producing numbers
that will be quoted.
