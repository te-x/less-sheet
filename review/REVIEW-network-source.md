# REVIEW — network-source

Build cell for `docs/architecture/ARCH-network-source.md` (signed off by the author 2026-07-14).
Contract frozen at `daf3a25` (api + backend + macOS) / root re-freeze `20060ce`'s successor commit.
Native implementer (opus) ⇄ native reviewer (opus) cell, run-id `network-source`, 2 rounds.
Orchestrator ran the trusted gate independently after every round; never accepted a role's own claim.

## Round 1 — implementer

Implemented the full feature per ARCH functional requirements 1–12, not just the narrow RED test
surface:
- `backend/src/net_source.zig` (new) — the `http_range` random-access Source: private spool file
  (0600, unlinked, ftruncate+mmap), per-256 KiB-chunk persist-once fetch, bounded 16 MiB RAM cache
  with FIFO eviction, fetch counter; a `Transport` abstraction (injected fake + real
  `std.http.Client`); `buildRandom`/`buildDownloadAll` Source builders (range mode + the
  sequential-fallback/`.csv.gz`-over-network route via download→gzip/mmap).
- `backend/src/open.zig` (new) — `buildDocument`, extracted from the existing open path so
  `ls_open` and the network open share identical head-scan/shape/index/worker construction.
- `backend/src/net.zig` — the full `ls_open_url_*` job lifecycle (fake + real transports, DONE-doc
  construction via `buildDocument`).
- `backend/src/source.zig`, `csv_reader.zig`, `reader.zig`, `index.zig`, `root.zig` — `http_range`
  union variant + Cursor ops; net instrumentation seams wired to live Source state.
- macOS: `CoreSessionOpener.openURL` (real start/poll/cancel/release + 1:1 error mapping),
  `DocumentModel.openURL` funnel, File → Open URL… (⌘⇧O) menu/sheet, URL-as-is window title, the
  AC10 cold-start-marker skip.

Gate: `GATE: PASS` (root, chaining backend + macOS), independently re-run by the orchestrator —
12 backend + 2 macOS previously-RED tests now green, all pre-existing tests still green, frozen
paths byte-identical.

## Round 1 — reviewer verdict: NOT PASS (3 within-contract gaps + 1 verification gap + 1 quality fix)

1. **[impl] AC9 progress/Cancel affordance unwired** — `networkOpenProgress` was written/cleared
   but read by zero views; no progress bar, no live counter, no Cancel; URL entry blocked on a
   modal `NSAlert`.
2. **[impl] AC7 error taxonomy collapsed at the UI** — all 7 `NetworkOpenError` cases rendered as
   one generic `.failure(.io)` panel; `networkOpenError` was stored but never read by any view.
3. **[impl] scope contamination** — an unrelated, pre-existing (uncommitted, from an earlier
   session task) find-highlight/dialect-panel/header-notice UI redesign was sitting in the same
   working tree and would have shipped under this commit. **Orchestrator clarified provenance**:
   not authored by the implementer for this feature; not touched in round 2; split into its own
   commit (`bedf8c7`, see below) instead of being folded into network-source. (Two files,
   `OverlayView.swift`/`ViewerModel.swift`, could not be cleanly hunk-split — the implementer's
   `adoptSession` extraction genuinely restructured the same lines the pre-existing header-toggle
   notice touches — so those two ship in the network-source commit itself, called out explicitly
   in its message.)
4. **Verification gap (not an implementer fix)** — AC3/AC15's partial-access and eviction-under-
   pressure claims are asserted by checks that hold trivially because every frozen fixture is
   under the 4 MiB head bound; the incremental on-demand path is implemented and inspected-sound
   but empirically unproven at gate scale. Routed to the human real-host probe (frozen `tests/`
   cannot add a larger fixture without a planner pass).
5. **[impl] real-transport inefficiency** — `RealTransport` opened a fresh `std.http.Client` +
   TCP/TLS handshake per 256 KiB chunk, and discarded the probe's already-read bytes instead of
   reusing them — a real-world large-file open would cost thousands of handshakes.

## Round 2 — implementer

Fixed findings 1, 2, 5 (3 and 4 correctly out of scope per orchestrator disposition — see above):
- **Finding 1**: a `Progress`/`ProgressFn` callback threaded from every real fetch (never a cache
  hit) through `net.zig`'s job state; a `NetworkOpenCancelToken` (fixing a real bug — the prior
  `Task.isCancelled` check ran inside a plain `DispatchQueue` closure with no ambient Task context,
  so cancellation never actually fired); `NetworkOpenBanner` — an always-visible glass-capsule
  affordance (determinate bar+% / indeterminate spinner+byte-counter, Cancel, Esc), shown
  regardless of `phase`, satisfying "visible from t0."
- **Finding 2**: `NetworkErrorPanel` — distinct fact/fix text for all 7 `NetworkOpenError` cases,
  rendered instead of the generic panel for a network-kind failure.
- **Finding 5**: `RealTransport` now owns one `std.http.Client`/`Io.Threaded` for the job's whole
  lifetime, connection-pooled across every subsequent range fetch; `probe()` runs on the same
  instance.

Gate: `GATE: PASS`, independently re-run by the orchestrator; `swift build` verified clean
end-to-end (several SourceKit diagnostics during the round were confirmed stale/mid-edit noise,
not real errors — same false-positive pattern seen earlier this session).

## Round 2 — reviewer verdict: PASS

Independently re-verified (own `git diff` against every frozen path — empty; own `zig build test`
— 142/142 including all `net_ac*`; own `swift build` — clean) that findings 1, 2, and 5 are
genuinely fixed, tracing the actual code paths rather than trusting the summary. AC1 (on-paper
Parquet/ODS Source-shape proof) and AC2 (frozen-boundary byte-identity) reconfirmed. Findings 3 and
4 stand as noted, non-blocking per their routing.

## Orchestrator's independent verification (every round)

- Re-ran `bash ~/.claude/aidev/gate.sh --require-frozen "$PWD"` myself after each round — never
  accepted an agent's own gate claim. Both rounds: `GATE: PASS` at backend, macOS, and root level,
  no frozen-surface drift.
- Confirmed tree-hash stability between the pre-review digest handed to the reviewer and the
  reviewer's own re-check (`6463976b367d36e797bd8e5023306994bd881b691b47bc1c4e59fef547f5c5a4` —
  identical both times).
- Final acceptance: `bash ~/.claude/aidev/gate.sh --require-frozen --relay network-source "$PWD"`
  → `GATE: PASS` + `RELAY: PASS` — all 4 relay turns (implementer ×2, reviewer ×2) verified
  byte-exact against their ledgered sources.

## Verdict

**DONE.** Landed on master as `bedf8c7` (the unrelated pre-existing UI-polish split out per
finding 3) followed by the network-source feature commit itself.

## Outstanding — human-only verification (not gateable, not blocking DONE)

Per the ARCH doc's own deferral list plus round-1 finding 4:
- **AC3/AC15 at real scale** — open a **>4 MiB** remote CSV against a real range-supporting host and
  confirm the top window renders after fetching only ~4 MiB (not the whole file), and that RAM stays
  bounded while the spool grows past 16 MiB. (Public sample CSVs, e.g. datablist.com's sample-CSV
  collection, are a good source for this — noted earlier in the session.)
- **AC11** — a real `http://` AND `https://` round-trip end to end.
- **AC9 (UI half)** — eyeball the `NetworkOpenBanner` affordance live (determinate/indeterminate,
  Cancel actually stopping an in-flight fetch, Esc).
- **AC17** — File → Open URL… (⌘⇧O) menu/sheet, live.
- **AC10 (runtime)** — confirm no `first_rows_visible_ms` line for a network open, alongside a local
  open still emitting one, via stderr.
- Dark mode / VoiceOver on the new `NetworkOpenBanner`/`NetworkErrorPanel` — never checked (matches
  this project's standing pattern of deferring appearance-mode/accessibility passes to the author).
