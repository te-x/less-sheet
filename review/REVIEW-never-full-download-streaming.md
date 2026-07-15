# REVIEW — never-full-download-streaming

Build cell for `docs/architecture/ARCH-never-full-download-streaming.md` (signed off by the author
2026-07-15). Branch `feat/never-full-download-streaming` (large features kept off master per the author).
Contract frozen at `f97bbb8`. Native implementer (opus) ⇄ native reviewer (opus) cell, run-id
`nfd-streaming`, **2 rounds to convergence**. Orchestrator ran the trusted gate independently after
every round; never accepted a role's own gate claim.

## Feature
Network document access becomes strictly **lazy / demand-driven**: nothing is fetched except what a
concrete user action needs (head-only on open; viewport+buffer on scroll; up-to-next-match on search;
deep-jump/wrap pay-on-demand+cancel), with **no background network scan of any kind**. The AUTO
background indexer + filter/search auto-drive are suppressed for network sources (`net` flag; local
mmap/gzip byte-identical). One `http_range` Source gains a `sequential` fill (no-range servers); gzip
composes over the growing compressed spool (`buildDownloadAll` deleted; `decideProbe`'s `range=!is_gz`
force dropped); unknown-length is first-class. Local is strict-timed; network is best-effort, judged by
fetch-**minimality** (`netFetchCount`), never latency.

## Round 1 — implementer
Built the whole feature (TD1–TD12): the `net` lazy gate (`index.zig` `do_index`/`do_filter`), the
sequential fill + unknown-length growing spool (64 GiB PROT_NONE reservation, MAP_FIXED tail-grow, no
dangling slices) in `net_source.zig`, gzip-over-growing-spool provider in `source.zig`, the real
`decideProbe` classification (`length_known` split), demand-bounded search (`search.zig`), honest DONE
+ `net` wiring (`net.zig`/`open.zig`/`base.zig`/`root.zig`), and the macOS `≥N`-rows unknown-total copy
(`OverlayView.swift`/`ViewerModel.swift`, no new Swift contract). Made the flagged `nfd_ac22`
deterministically green (2 ms shutdown-poll join). Orchestrator gate: **GATE: PASS**, all 24 `nfd_ac`
green (RED→GREEN flip real), 142-corpus green, macOS 160/160.

## Round 1 — reviewer verdict: NOT PASS (1 [impl] finding)
Reviewer independently diffed vs `f97bbb8` and verified 23 ACs *genuinely* met (not vacuously):
fetch-minimality instrumentation counts only real transport reads; the lazy spine has no residual
background advance; local path provably byte-identical (AC21); the unknown-length spool is
MAP_FIXED-growth-safe (base never moves, no use-after-remap); gzip-over-provider composition sound.

**Finding 1 [impl]** — `setFilter` (filter.zig) lacked the `!d.net` guard that `startSearch` got. A
network filter therefore (normal path) sat in `.scanning` forever with no first screen, and (degraded
`worker==null` path) drove a to-EOF filter scan over the wire — an actual full download, violating the
feature's headline constraint. The gate could not catch it: **no frozen AC exercises filter-on-network**
(the implementer had flagged this untested). Tagged `[impl]` (fix within the signed design).

## Round 2 — implementer
Applied exactly the prescribed fix: a `if (d.net) { filter_state = .cancelled; unlock; return true; }`
net-park at the top of `setFilter`, before both the `.scanning` assignment and the degraded synchronous
loop — mirroring the `startSearch` net-park. Strictly `net`-gated (+16 lines, `filter.zig` the sole
change vs round 1). Orchestrator gate: **GATE: PASS** (no regression).

## Round 2 — reviewer verdict: PASS
Reviewer read the `filter.zig` diff itself and confirmed the guard's placement (before both paths),
strict `net`-gating (local byte-identical), and ARCH/`startSearch` conformance — both manifestations of
finding 1 closed. Since the fix isn't gate-lockable (no network-filter AC), verification was by
code-reading (the reviewer's second-key role for residue the gate can't check).

## Orchestrator verification (every round)
- Re-ran `bash ~/.claude/aidev/gate.sh --require-frozen "$PWD"` after each round — never the role's
  claim. Both rounds: GATE: PASS (backend + macOS + api/ integrity), no frozen drift.
- Confirmed tree-hash stability between the pre-review digest and the reviewer's own re-check
  (`659f1e2f69022a5dee5cd1389e868c14721ac3761d9e58378b18189f7b569fcb`, identical both times).
- Final acceptance: `gate.sh --require-frozen --relay nfd-streaming` → **GATE: PASS + RELAY: PASS** —
  all 4 relay turns (implementer ×2, reviewer ×2) verified byte-exact against their ledgered sources.

## Verdict
**DONE.** Landed on `feat/never-full-download-streaming` (freeze `f97bbb8` + the implementation commit).

## Outstanding — carried forward (non-blocking; not gate-checkable)

1. **Frontend first-screen (human visual pass).** With the backend correctly parking a network filter
   `.cancelled`, the macOS apply flow (`landViewport`→`ls_window_set`, no filtered jump) means a network
   filtered view's first screen won't auto-populate until a filtered jump/scroll demand is issued
   (`filter_rows` starts at 0). This is a ViewerModel matter consistent with the ARCH ("first screen is
   a demand") — confirm during the human pass that applying a filter on a network doc issues a filtered
   jump to row 0 so the first screen appears.
2. **Planner follow-up: add a frozen network-filter AC.** No frozen AC exercises filter-on-network, so
   the gate cannot lock finding-1's fix (a green gate proves only no-regression). A planner pass should
   add an `nfd_ac` for network-filter park/on-demand behavior so this can't silently regress.
3. **Real `std.http.Client` transport is a human host probe** (out of gate scope by design — the gate
   exercises only the fake transport; see `[[no-full-download-ever]]`). Verify the streaming/gzip-over-
   provider paths against a real host: open the Azure `.csv.gz` and a large plain CSV over a real
   range server, confirm first paint fetches only ~head (a few MB), scroll/search fetch incrementally,
   and nothing full-downloads.
4. **`jump_cancel` mid-sequential-withhold** — cancellation of an in-flight *withheld* sequential drain
   is delayed until bytes arrive / the stream ends (worker-thread only; UI stays responsive; real
   stalls resolve via the TIMEOUT taxonomy). Accepted best-effort per the ARCH's network-best-effort
   stance.
5. **Frontend deep-jump/scroll "loading rows" affordance + unknown-total `≥N` rows / indeterminate
   spinner** — reuses existing `JumpControlView`/open-job UNKNOWN affordance; confirm live in the visual
   pass (not headlessly gateable).
