# REVIEW — security hardening Wave 2b, backend (d)/(e)/(f) — run `sec_w2b2`

Decision record written by the orchestrator at convergence. Cell: native Opus-5 implementer ⇄
native Opus-5 reviewer, 4 rounds. Branch `feat/kbdnav-a11y`. ARCH:
`docs/architecture/ARCH-security-hardening.md` (signed 2026-07-24, amended — see CHANGE-REQUEST below).

## Outcome

**Reviewer verdict: CONDITIONAL PASS, cell closed** after conditions (2) and (3) were applied in
round 4. Trusted gate re-run by the orchestrator on the final tree: **PASS** — ReleaseSafe native +
aarch64-linux-musl + x86_64-linux-musl cross-builds, `zig fmt --check` clean, `zig build test
-Doptimize=ReleaseSafe` **273/273**, csvgen corpus **142/0**, streaming peak-RSS flat 1MB..100MB.
Zero `@setRuntimeSafety(false)`. `api/lesssheet.h` byte-identical throughout.

## What shipped

- **(d) gzip-bomb plumbing — REMOVED** as accepted risk per the signed amendment (a compression
  ratio cannot distinguish a bomb from legitimately compressible CSV; memory is already
  O(viewport)-safe and cancellable). Zero dangling references; reviewer-verified.
- **(f) copy neutralization — NUMBER-AWARE.** `=`/`@` always neutralized; `+`/`-` only when the
  value is not a plain number, so numbers copy RAW. One choke point (`window.decodeCellAt`), which
  both `ls_cell_copy` and `ls_copy_next` funnel through; display/search/filter stay raw. Reviewer
  hand-checked `isPlainNumber` against the frozen `api/lesssheet.h` grammar byte-for-byte.
- **(e) network — kept working, made honest.** See the defects below; this is where all seven
  round-1 findings landed.

## Defects found and fixed (all in (e))

The gate was GREEN at 273/273 before any of these were found. Green was not sufficient: the entire
`RealTransport` path is unexercised by the hermetic fake taxonomy.

1. **CRITICAL — every HTTPS open panicked (ReleaseSafe).** Round 1 dialed via
   `client.connectTcpOptions` *before* `client.request`, bypassing the TLS prelude that populates
   `client.now` and rescans the CA bundle (the only assignment is `std/http/Client.zig:1721`,
   inside the `if (protocol == .tls)` block that runs before `options.connection orelse …` at
   :1725). **Measured**, live public HTTPS CSV: HEAD `4076382` panics `attempt to use null value`
   via `net_source.zig:286 probe → :267 dial`; fixed tree opens cleanly. Fix: delete `dial`, let
   `request()` own connect.
2. **MAJOR — AC-e1's connect deadline was inert.** `std.http.Client.ConnectTcpOptions.timeout` is
   declared and never read (one occurrence in the entire file, the declaration at :1442);
   `connectTcpOptions` calls `host.connect(io, port, .{ .mode = .stream })` with no deadline. The
   knob was deleted rather than shipped inert. → CHANGE-REQUEST item 1.
3. **MAJOR — net find/filter over a short body spun forever counting phantom rows.** Fixed across
   **seven** drivers (the implementer correctly showed the reviewer had named the wrong two), via
   one predicate `base.scanStalled` + one terminator per subsystem. **Measured discriminating**: at
   HEAD both live drivers sit at `scanning` forever at the 5 MiB wall; fixed they terminate. The
   *count-inflation* half of the finding did not reproduce and was withdrawn.
4. **MEDIUM — net `.csv.gz` short body reported complete.** Fix implemented (`Gzip.laneAtBudget`
   gating `spanTerminal`) but **NOT demonstrated**: the prescribed fixture (full gzip body,
   `advertise_length = true`, `short_body_at` swept 20–95%) is **byte-identical on both trees**.
   Recorded in `src/source.zig` as REASONED-CORRECT, NOT PROBE-CONFIRMED. Must never be written up
   as tested.
5. LOW — connection leak on the `request()` failure path; moot once `dial` was removed.
6. AC-e2 seam was test-shaped (`redirectDowngrades("https","http")` on literals is a constant
   `true`); `schemeOf` deleted in favour of the already-parsed `uri.scheme`. → CHANGE-REQUEST item 2.
7. NIT — stall predicate moved to logical bytes and excludes `stop_atomic`, so cancellation no
   longer publishes a bogus `.done`/1.0 jump.
8. NIT — lane→session mapping consolidated (`sessionForLane`, `laneAtBudget`, `forward_lane`).

## The hang (round 3) — `ls_net_open_release` blocked forever

Found by the orchestrator while testing the sentence CHANGE-REQUEST item 1 proposed to write into
the ARCH. That sentence claimed a hung host was "bounded by the cancellable fetch model + user
cancel"; measurement said otherwise.

| scenario | round-2 tree | round-3 tree |
|---|---|---|
| black-holed host (SYN dropped) | open fails after **75.4 s** (OS connect timeout) | release **0.000 s** |
| peer accepts then never answers TLS; cancel then release | cancel 0.000 s, job reports CANCELLED — then **release never returned** (killed ~200 s) | release **0.000 s** |

**Root cause:** the worker ran on a raw `std.Thread.spawn`, so `Thread.current` was unset and
`Threaded.Syscall.start` (`Io/Threaded.zig:1348`) treats every syscall on it as **uncancellable**.
Cancel set state the parked thread could never observe; release joined a thread that would never
return. Nothing to do with sockets or TLS.

**Fix (WWJD — one change, no new knobs):** the worker is an `io.concurrent` task and `release`
joins via `Future.cancel`, which interrupts the blocked read with `pthread_kill(.IO)`. Rejected as
wrong-shape: a receive-timeout knob (we had just deleted an inert one, and a cancelled job should
stop *now*), detaching instead of joining (hides the bug, leaks the thread), and hand-rolling std's
connection sequencing (what caused defect 1).

`concurrent`, not `async`, for two independent reasons: `async` may run eagerly inline (making
`ls_open_url_start` blocking), and it passes `@ptrCast(&future.result)` into the vtable, pinning the
future's address so the by-value `Future(void)` in `NetOpenJob` would be UB.

**Consequence, accepted for v1:** the executor is one process-global `Io.Threaded`, never
deinitialized (a DONE job hands its transport to the doc, and the ABI allows release in either
order, so the `Io` can be owned by neither). `Threaded.init` (`:1652-1663`) therefore permanently
replaces the process-wide disposition of **SIGIO and SIGPIPE** with a no-op handler, `flags = 0`
(no `SA_RESTART`). Judged low risk: SIGPIPE replacement is equivalent at the syscall boundary, and
we only ever signal executor-owned threads. **Open requirement:** wave (g)'s scoped+chained SIGBUS
handler and this grab must become ONE recorded signal-disposition policy for `liblesssheet.a`.

## Known-open, filed forward

**FINDING 9 [impl] — `ls_close` still hangs forever on a silent peer.** Same class, one layer down:
`doc.worker` (`open.zig:211`) is a raw `std.Thread`, `sourceShutdown` only stores a flag, and
`net_source.zig:686` blocks in `fetchInto` with the mutex down. **Reproduced and measured** by the
orchestrator on the final tree — after a successful open, with the scan worker parked, `ls_close`
never returned (SIGKILLed at 90 s). User-visible as a permanent app freeze on window close.

NOT fixed here: converting the index worker touches the local-file scan path for *every* document,
too much blast radius for an otherwise-converged hardening cell. Recommended as its own cell, a
sibling of wave (g). The fix is the one already proven at the job layer. Harness: `probe_close.c` +
`half_silent.py`.

**Referred out (not a finding):** row-count estimates exceed the true count on a truncated document
(667 538 vs 600 000). `exact=false` and `complete=false` are both reported, so it is
declared-approximate, not silent wrong data, and it is identical on both trees. The open question is
a frontend one — what the viewport renders when a user scrolls past the true last row.

## CHANGE-REQUEST (`backend/.aidev/CHANGE-REQUEST.md`) — two-key complete, awaiting architect + the author

Both items are ARCH wording on the SIGNED 2026-07-24 amendment. No `api/`, contract, or test change.
Signed by the implementer, **co-signed by the reviewer**.

- **Item 1 (AC-e1) — infeasible.** No connect deadline is deliverable through `std.http.Client` in
  Zig 0.16. The wording the reviewer co-signed is scoped to the open path and names the limitation:

  > No deadline fires on its own. **During open**, a hung or non-responding host is bounded by user
  > cancel: `ls_net_open_release` interrupts the blocked connect/read rather than waiting it out, so
  > neither a black-holed host's 75 s OS connect timeout nor a peer that accepts and then answers
  > nothing is ever waited through. **This bound does not extend past open: a document's background
  > scan worker is not an executor task, so an in-flight fetch on it cannot be interrupted and
  > `ls_close` can block on a silent peer. Tracked separately; see finding 9 (sec_w2b2).**

  The reviewer's key is given against **that** text — not the original, and not the implementer's
  first replacement, which overreached in the same way the original did.
- **Item 2 (AC-e2) — wording, option (a) detect-and-discard.** std follows the redirect inside
  `receiveHead`, so the plaintext GET is already issued before we can inspect the scheme; we discard
  the response and fail with `LS_NET_ERROR_INSECURE_REDIRECT`. True prevention would require
  `.unhandled` plus a hand-rolled reimplementation of `Request.redirect` — rejected. The wording must
  name what travels in cleartext: the request line to the redirect target plus `Range`, and no
  credentials, because we send none.

## Process notes

- Every reviewer claim about std was independently re-derived from
  `/opt/homebrew/opt/zig/lib/zig/std/` before being acted on; two were wrong and were corrected —
  the finding-1 panic line (`:364` is a tail-merged misattribution of the real `client.now.?` null
  at :357) and the finding-4 fixture diagnosis (the probe already had the prescribed shape).
- Rounds were not committed individually, so round 4's "comment-only" claim could not be isolated in
  git; it was verified by gate plus re-measuring the silent-peer probe instead. **Commit at round
  boundaries next time.**
