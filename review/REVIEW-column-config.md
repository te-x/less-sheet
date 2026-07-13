# REVIEW — column-config (backlog P1: column data types + formatting + visibility)

**Final verdict: PASS (code + automated NFR).** Two parallel, provably-independent cells. Backend cell
reviewer PASS bound to tree `2f08274f…`; macOS cell reviewer static PASS bound to tree `f013d51367…`.
`api/lesssheet.h` additive-only and byte-identical for all pre-existing bytes (frozen at `8174b0b`). Root gate
PASS (api integrity + backend 142 corpus + macOS 131 Swift tests).

**One human gate remains open:** AC21's interactive-latency measurement (panel open / search / scroll /
redraw via a desktop Instruments trace) is a hard human acceptance gate the reviewer cannot clear headlessly.
Structural O(viewport) verification and the headless cold-open runs support it but do not replace it. Handed
to the author for the live pass.

## Cell configuration
- **cc-backend** — implementer (claude-opus-5, isolated-promotion) ⇄ external claude
  reviewer (claude-opus-5). IMPLEMENTATION_PATHS=`src`. Type model + inference + ABI.
- **cc-macos** — same runners; IMPLEMENTATION_PATHS=`Sources/{LessSheetApp,LessSheetKit}`. Compact column
  control panel + display-only formatting. Disjoint paths, independent gates.
- Orchestrator ran every gate and the NFR; implementer claims never taken as evidence.

## What shipped
Format-neutral column **type model** in the core: declared/inferred/override/effective slots
(effective = override > inferred > declared > unknown), v1 kinds text/boolean/integer/decimal/date/datetime,
orthogonal null policy (empty = empty text by default; optional per-column byte sentinel) and conflict/
proposal state. Inference is **bounded + lazy**: a 256-row first-sample head, then evidence only from
materialized window events — never an eager O(file) or all-column scan. Publication requires **eight distinct
eligible source rows**; provisional (1–7) → published (8, bounded) → exhaustive (every row examined, exact).
Proposals mirror the same eight-distinct rule; accept-proposal stays in Auto. Window-safe query/update surface
(`ls_column_*`, 12 functions, 4 fixed-layout snapshot structs). macOS: a chromeless Liquid-Glass panel
(virtualized/searchable column list, O(panel viewport), safe on wide_100k_cols) replacing the per-column
checkbox section; display-only formatting (copy/Find/filter still operate on raw canonical values); everything
per-session, nothing persisted.

## Round history (cc-backend — the hard cell)
The bounded-yet-exact inference counter oscillated across the exactness edges; each round the reviewer held
the contract's exact-8-distinct / exact-exhaustive line:
- **R1** 9 `[impl]` (cold-open neutrality, missing window-event path, under-lock sampling, per-column rescans,
  O(state) get_many, AC7 precision/negative-scale, AC8 merge/override-conflict ordering, AC10 declared slot).
- **R2–R3** source-byte budget overrun (multibyte), paused-gzip inflater-lane deadlock, evicted-row re-count.
- **R4–R6** coverage-range-cap edges: discarding disjoint coverage (never-exhaustive) vs dropping a new row
  at the cap (uncounted).
- **R7** forward-index frontier drove false-exhaustive; 512-row ring re-counted evicted rows.
- **R8** exhaustive moved to classified-row coverage (frontier defect resolved); first-sample cap bypassed
  for ≤4 MiB docs; a distinct row still dropped at the range cap.
- **R9** initial-head cap fixed; automatic exhaustive continuation flagged as O(all rows); residual
  overflow→tracked double-count.
- **R10 — PASS.** Automatic exhaustive continuation removed (rows past the head examined only via materialized
  windows); the 8-count keyed to fixed **eight-row exact proof sets** per candidate/proposal bucket — bounded
  and exact, no drop-at-cap, no double-count, no overflow→tracked repeat. Reviewer confirmed no new
  concurrency/boundedness issue.

## Round history (cc-macos)
- **R1–R4** — panel virtualization + formatting + the NativeGrid width/geometry invalidation branches
  (changed IDs → global fallback; changed origin → live-geometry repaint; changed visible width → repaint
  from first changed column; stable geometry → exact-cell redraw). Static reviewer PASS at R4; no
  invalidation loop; raw copy/Find/filter unaffected.

## NFR evidence (ReleaseFast, single host; reviewer accepted, no near-budget caveat)
Recipe: cold-open test-filter + a public-C-ABI probe (`/tmp/column_nfr.c`) on wide_100k_cols plain **and**
gzip — `--request-first 98976 --request-count 1024 --cancel-after-ms 5 --assert-live-at-cancel
--submit-find-jump --interactive-budget-ms 100 --metadata-ids 16 --override-state-counts
1000,10000,50000,100000 --metadata-repetitions 1000`.
- Open + first window: plain max **23.1 ms**, gzip max **53.2 ms** — ≪ 500 ms.
- Preemption: inference job **live at 5 ms**; cancel / interactive window / priority-jump effect / Find all
  **≪ 100 ms** on both formats.
- `ls_column_metadata_get_many`: median/p95 **flat (~1 µs)** from 1k through 100k populated overrides — O(requested), not O(stored state).
- Cold-open corpus test-filter PASS (one first-attempt csvgen streaming-RSS self-test boundary flake under
  load; clean on immediate re-run).

Result: `zig build` green; `zig build test` 193/193 + csvgen 142/0; macOS 131/131; root gate PASS.
