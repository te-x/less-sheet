# REVIEW-5 — frontend (apps/macos), feature viewer-ui

Scope: frontend cell only (parallel-cell policy; backend reviewed in REVIEW-5-backend.md; root gate
NOT run — backend behavior is red on the disputed frozen test pending the planner's CHANGE-REQUEST
adjudication, which touches nothing on this side). Inputs: docs/architecture/ARCH-viewer-ui.md,
api/lesssheet.h, apps/macos/Sources/Contracts/*, Tests/ViewerUiTests.swift (frozen), implementation
diff = Sources/LessSheetKit/{CoreDocumentSession,ViewerLogic}.swift +
Sources/LessSheetApp/{AppUI,ViewerModel,GridView,OverlayView,GuessPills,ConfigureWindow,FrameDump}.swift.
Frozen paths untouched (git: Contracts/, Tests/, Package.swift, api/ clean). All verification
headless and TCC-free (stderr markers, LESSSHEET_DUMP_FRAME/SCENE hooks, CGWindowList counts,
proc_pid_rusage phys_footprint probe — per the backend review's integration note, memory is
measured as phys_footprint, not ru_maxrss/RSS).

## Gate

`bash apps/macos/.aidev/gate.sh apps/macos`, run by me: conformance (backend `zig build` +
`swift build`) PASS; behavior `swift test` **25/25 PASS** — against the real linked Zig core
(no mocks; ABI pins, windowed bridging, dialect propagation, jump/visibility/composer semantics).

## Measurements (reviewer-run; release `swift build -c release` + ReleaseFast core; single machine, order-of-magnitude)

| Measurement | Target | Measured |
|---|---|---|
| Cold start, tiny (78 B) | < 500 ms | 169 / 170 / 199 ms |
| Cold start, 2.6 GB / 100 M rows | < 500 ms | 191 / 191 / 202 ms |
| Cold start, 5.4 GB sparse | < 500 ms | 190 / 193 / 193 ms |
| Launch modes: direct exec · open -n --args · doc-launch · no-args | 1 window, 1 marker; no-args = panel, no marker | 1/1 · 1/1 · 1/1 · 2 windows (main + auto open panel), 0 markers |
| Replace (2nd doc-open into running instance, drag/Dock route) | 1 window, marker per open | 1 window, 2 markers |
| Error (missing path) / empty file | silent (no marker), panel/quiet line renders | 0 markers each; dumps confirm error panel + "This file is empty." |
| Steady phys_footprint, 2.6 GB after full AUTO index (dump hook off) | < 120 MB | **32.9 MB** (RSS grows to ~2.5 GB of clean file-backed pages — footprint is the budget-relevant metric) |
| phys_footprint, 5.4 GB sparse through+after index | < 120 MB | 33 MB during scan, 48.1 MB peak/steady after estimate→exact collapse |
| Kit-level probe (real bridge): open → page to 20k (model's exact 1240-row windows) → jump 50% → jump end | — | steady footprint 4.5 MB (baseline 1.6) |
| setWindow+copy per page (main-thread row-serving cost) | no >17 ms hitch | mean 0.18 ms, **worst 0.25 ms** (n=51) — ~68x headroom |
| Beyond-frontier jump to row 100,000,000 (2.6 GB) | exact landing, observable monotone progress | landed 99,999,999; content "100000000,r100000000" byte-exact; 46 polls @100 ms, monotone in [0,1]; 4.83 s (ReleaseFast, ~530 MB/s) |
| Behind-frontier jump (50 M) | instant, exact | done synchronously (<1 ms), content exact |
| ls-open via bridge on 2.6 GB | O(head) | 11.4 ms; row estimate 123.5 M (actual 100 M), exact=false → exact 100,000,000 at completion |

## Acceptance criteria 9–14

9. **Met, measured** (table above). Marker format unchanged (frozen test + observed lines).
10. **Met** — dumps inspected: chromeless full-window grid, spreadsheet fill to BOTH edges (tiny:
   filler rows + columns; huge: dense rows + filler columns; wide 12-col: dense, aligned); overlay
   revealed (filename chip, "Jump to row", pills H · , · " with correct current values, Configure);
   Configure state (same "Comma ,"/"Double quote""" vocabulary as the pills, per-column checkboxes);
   error panel unchanged (fact + fix + selectable path).
11. **Met at state level** — before/after dumps: forced ',' on a semicolon fixture renders ONE
   column ("name;age" / "Ada;36"); forced ';' renders two columns AND the separator pill carries the
   accent override ring (vs neutral pills when guessed). Hidden column (age) disappears and widths
   reflow; Configure dump shows the last visible column checked, disabled, tagged "last visible".
   The literal pill-click → re-open plumbing is frozen-tested (composer/carry/visibility) and
   code-reviewed; a live click is not headlessly drivable (finding 2).
12. **Met at bridge level, measured** (jump rows in the table; the probe drives the same
   CoreDocumentSession the app uses). App-side wiring (JumpFlow fold → pendingScrollRow → scrollTo)
   is frozen-tested at the logic layer and code-reviewed; live scroll-to-row is human-eyes
   (finding 2: no headless jump hook in the app process).
13. **Met with ~2.5–3.5x margin** as phys_footprint (32.9 MB app steady on 2.6 GB; 48.1 MB on
   5.4 GB sparse; +≈3 MB data-layer cost for the scroll/jump pattern from the Kit probe). The
   scroll-10k/jump sequence was driven at the bridge layer, not through live AppKit scrolling
   (no headless hook); grid laziness is structural (rows are direct LazyVStack children, no
   full-height Canvas — confirmed by grep and by file-size-independent footprint).
14. **Measured where possible**: worst main-thread row-serve 0.25 ms (17 ms budget); auto-open
   panel verified headlessly (window count + zero marker); overlay reveal/fade, traffic-light
   hover, live 60 Hz feel listed human-eyes below.

## Contract & code review

- **Borrow-copy discipline**: every `ls_str` is copied to an owned String inside the window lock
  (`setWindow`) or at init (header cells) before returning; U+FFFD replacement via
  `String(decoding:as:)`; no ls_str cached across `ls_window_set`/`ls_close`. All ls_* calls are
  contained in CoreDocumentSession.swift (grep-verified).
- **Threading**: window lane serialized by NSLock (setWindow, close); poll/control lane lock-free
  as the header allows; `ls_open` on a dedicated queue off the main actor. Close exclusivity holds:
  `stopPolling()` cancels AND awaits the poll task before `close()`; the detached poll task holds
  the session strongly, so a deinit-close can never race an in-flight poll. Main-thread core calls
  are exactly the sanctioned set: ls_window_set (synchronous-fast), zero-alloc polls, jump
  start/cancel (never block).
- **Paging hysteresis**: re-page only when the viewport enters a 200-row guard band of the
  1240-row window (or the window is empty/short); at top/EOF edges the guards disable correctly —
  no thrash; short windows are re-materialized from the 100 ms poll only while the index is
  incomplete. Poll loop stops when index complete and no jump scanning (idle documents cost
  nothing); restarted by open/jump.
- **Jump cancel** restores the captured pre-jump viewport (frozen-tested state machine; Esc in
  field closes, Esc/Cancel in scanning cancels); landing/cancel collapse the field.
- **Dialect re-open**: composer carries forced flags from the core's report, forces only the
  changed parameter, rejects out-of-domain/carried-collisions (frozen-tested); visibility carried
  iff column count unchanged, else reset (frozen-tested); LESSSHEET_HIDE_COLS applies only to
  fresh opens.
- **Env hooks inert by default**: LESSSHEET_DUMP_FRAME/SCENE/EXIT, HIDE_COLS, FORCE_SEP/QUOTE/HEADER
  all guarded on env presence; delivered only via env (cannot leak into normal launches).
- **Glass**: `glassEffect`/`GlassEffectContainer` on the live path; the opaque fallback is gated
  solely by the dump-only `overlayDumpChrome` environment key set inside FrameDump.overlayScene —
  the known ImageRenderer limitation is dump-only, confirmed at code level.
- **Kept conventions**: delegate-owned single window (no WindowGroup), frame autosave + center
  fallback, marker from process start via LaunchTiming, single open funnel; skeleton debt fixed
  per req 3 (Settings item removed, no duplicate View menu; Go › Jump to Row ⌘J added).
- **A11y (code level)**: every overlay control labelled (pills: label + value + guessed/set-by-you
  hint; option rows carry isSelected); Reduce Motion zeroes the rise offset and animations.

## Findings

1. **[impl]** ARCH functional req 4 is half-unimplemented: **drag & drop onto the WINDOW does not
   open a file** — no `.onDrop`/`dropDestination`/NSDraggingDestination anywhere in the app
   (grep-verified; the skeleton explicitly excluded drag & drop, so nothing was inherited). The
   Dock-icon/Finder route works (application(_:open:)/openFiles, verified via the doc-launch and
   replace runs). Fix is small and in-contract: accept `.fileURL` drops on the content view and
   route through `DocumentModel.open` (the existing funnel). Not covered by the frozen tests
   (headless-untestable), hence not caught by the gate.
2. **[impl, nit]** No headless driver for an app-process jump/deep-scroll (e.g. an inert
   `LESSSHEET_JUMP=<row>` verification hook, mirroring the existing FORCE_*/HIDE_COLS pattern), and
   no dump scene for the EXPANDED jump field — so criterion 12/13's app-level runs stop at the
   bridge layer, and the req-7 estimated-count copy ("~123.5M rows, estimating…", correct by code)
   never appears in any dump. Would shrink the human-eyes list for every future round.
3. **[impl, nit]** `DocumentModel.closeDocument()` is dead code (no callers).
4. **[impl, nit]** Rapid double dialect-change: a displaced session is closed only via the deinit
   safety net after its poll task unwinds (~≤100 ms), and one stale poll can overwrite
   rowCountInfo/progress for a tick; ordering currently leans on the opener queue being serial
   FIFO. Correct today; an openGeneration guard in `open()`/`applyPoll` would make it robust by
   construction.
5. **[impl, nit]** `onContinuousHover` calls `revealOverlay()` per pointer event → cancel+respawn
   of the fade Task at pointer-move rate; `WindowConfigurator.apply` re-sets window title + 3
   animator alphas on every body re-evaluation (each 100 ms poll tick while estimating). Both
   idempotent and cheap — debounce/gate-on-change when convenient.
6. **Observation**: on the 5.4 GB sparse fixture the footprint steps 33 → 48 MB exactly when the
   index completes (estimate→exact collapses displayRowCount ~292 M → ~57 k; SwiftUI relayout).
   Still far under budget; keep an eye on real 10 GB files.
7. **Observation (packaging, out of slice; echoes REVIEW-5-backend)**: nothing pins the shipped
   app to an optimized core — the gate links Debug (~124 MB/s scan → ~20 s jump-to-end on 2.6 GB
   vs 4.8 s at ReleaseFast). When a packaging/release step exists, pin `-Doptimize` for the
   backend artifact.

## Human-eyes-only (not attempted, per TCC constraint)

- Live Liquid Glass appearance/tint/interactive shimmer (dumps use the opaque fallback by design);
  the live Configure window's native Form layout (its dump is a same-state plain-view mirror).
- Scroll smoothness at 60 Hz, pinned-header behavior while scrolling both axes, estimate-refinement
  thumb drift (numbers say structurally safe).
- Overlay reveal/fade feel (180 ms reveal / 2 s idle fade / pinned-while-interacting), Reduce
  Motion variant, traffic-light hover reveal, window drag by background.
- VoiceOver walk and keyboard reach (⌘J focus, Esc paths, Tab focus over faded overlay).
- Native open panel interaction and cancel-to-empty-grid; drag & drop (blocked on finding 1 for
  the window path; Dock path shares the verified openFiles route).
- Live pill click → instant head re-render + index restart feedback (state plumbing frozen-tested;
  equivalent end states dump-verified).

## Verdict

**FAIL — round required for finding 1 only** (functional req 4's window drag & drop is missing;
in-contract, small). Everything else is genuinely met and measured with wide margins: gate 25/25
against the real core, cold start ≤ 202 ms on 5.4 GB (2.5x under budget), steady footprint
≤ 48 MB (2.5x under budget), exact jump landings with monotone progress, worst main-thread
row-serve 0.25 ms (68x under the hitch budget), no contract drift, borrow/threading rules honored.
Findings 2–5 are non-blocking nits for the same or a later round.

---

## Addendum — 2026-07-06: finding 1 voided by ARCH amendment (user descope); revised verdict

After this review was issued, the author descoped window drag & drop from viewer-ui ("I don't see the
point") and ARCH-viewer-ui.md functional req 4 was amended accordingly. Independently verified by
me against the working tree:

- `git diff docs/architecture/ARCH-viewer-ui.md` contains exactly ONE hunk: req 4 now requires only
  the standard open-document events (Finder double-click / Dock-icon drop) to replace the current
  document, and declares window drop an explicit non-goal ("no dedicated drop-target code exists or
  is required"). No other requirement, criterion, or constraint changed.
- The surviving half of req 4 was already verified in this review: doc-launch runs (1 window,
  1 marker, 176 ms) and the replace run (second doc-open into the running instance: 1 window,
  marker per open) exercise the same `application(_:open:)`/`openFiles` route that Finder
  double-click and Dock-icon drops use.
- No frontend code has landed since the review (git diff stat for apps/macos is identical:
  AppUI 448, FrameDump 198, CoreDocumentSession 24, ViewerLogic 109 changed lines; same untracked
  file set). All measurements, dumps, and code-review conclusions above remain valid — no
  re-testing warranted.

Finding 1 is therefore void (its requirement basis no longer exists). Findings 2–5 stand as
recorded: all are non-blocking nits, to be handled as debt or in a future round. Finding 1's
original text is preserved above for the record.

**Revised verdict: PASS** — against the amended ARCH-viewer-ui.md, every applicable functional
requirement and acceptance criterion (9–14) is genuinely met, measured where measurable (gate
25/25 against the real core; cold start ≤ 202 ms on 5.4 GB; steady phys_footprint ≤ 48 MB vs the
120 MB budget; exact jump landings with monotone progress; worst main-thread row-serve 0.25 ms vs
the 17 ms hitch budget; no public-surface drift; borrow/threading rules honored). Human-eyes items
as listed above.
