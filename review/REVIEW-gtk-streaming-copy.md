# REVIEW — GTK Slice 5: streaming copy (+ title-bar progress)

**Verdict: PASS (2 rounds).** Bound to tree-hash `47b85f17…`, trusted gate 10/10 (18 `/copy` g_tests +
all existing). The heaviest GTK parity slice — a port of the macOS streaming copy over `ls_copy_*`.

## Frozen contract (RED-first, freeze `c556b02`)
`include/lsg_copy.h`: a pure display-free copy view-model (`LsgCopyFlow` — STREAMING/STALLED/DONE +
COMPLETE/BUDGET/CELL_CAP/FRONTIER/CANCELLED) + a bridge (`lsg_document_copy_open/next/close` → opaque
`LsgCopyJob*`) over `ls_copy_open/next/close`. Close-guard = the seam's `control_lock` (held by
`lsg_document_close`) + re-check the core handle; **leaf-before-root** (a job must not outlive its
document — no ARC). 18 g_tests (11 pure + 7 real-core byte-identity). No ABI gap.

## Round 1 — engine + UI
**Impl:** `lsg_copy.c` view-model (port of `DocumentModel.streamCopy` + `CopyOutcome`: MAX-fold rows,
byte-budget cut, cell-cap, STALLED→advance→resume with the filtered no-progress guard→FRONTIER, cancel→
terminal) + the bridge. `main.c`: Ctrl+C + header-bar Copy button, drag-rect / whole-row / whole-column
select, **muted-gray marquee** (theme fg α 0.20; find highlights accent), an **off-main `GThread` worker**
(grid keeps scrolling — window lane vs control lane), `GdkClipboard` hand-off, and a **reusable header-bar
progress + ✕ cancel** (`build_header_progress`/`show`/`set`/`hide` — determinate ≥0, pulse <0, op-agnostic
= the unified title-bar progress pattern the other long ops will reuse).

**Reviewer:** close-guard/deadlock, leaf-before-root, never-block-UI (AC4), fold algebra, progress/cancel
all SOUND — but 1 × **blocking `[impl]`**: the copy worker advances the frontier on STALLED via the shared
core scan slot (`lsg_document_jump_start`, per the ABI) with ZERO coordination with the other frontier-
advancers → (A) a competing jump / `net_drive` scroll-fetch / filter to a row `< stalled_row` re-stalls the
copy on the same row → no-progress guard → **silently truncated copy** (likely on network docs); (B) the
worker's jump mis-lands a user jump; (C) filter-mid-copy pulls bytes in a stale coordinate space → wrong
bytes. Not g_testable (the common local fully-indexed copy has no stalls → green gate misses it).

## Round 2 — serialize the single scan slot (all `main.c`)
**Impl:** while `copy_op != NULL`: `net_drive_begin` early-returns; `do_jump_submit` denies (reject-blink);
`do_apply_filter`/`do_clear_filter` `copy_stop_and_join` BEFORE `ls_filter_set`/`_clear`; and — a correct
in-class extension the implementer flagged — `find` (`find_run_query`/`do_find_step`/the wrap in
`find_poll_fold`) yields too, with the wrap-nav **deferred** + re-issued next tick after the copy ends.
Optional trim: NUL-append in place + `blob->data` to `gdk_clipboard_set_text` (drops the ~64 MiB `g_strndup`).

**Reviewer: PASS.** Enumeration COMPLETE (grepped all 9 scan-slot bridge callers — 8 external now
guarded/stop-joined, the 9th is the copy worker's own advance); the AUTO indexer only advances forward
(monotone, can't retarget below `stalled_row`), bare `ls_window_set` never scans, new-doc/dialect routes
through leaf-before-root `copy_stop_and_join`. The `find` guard is the same data-loss class → correctly
KEPT. Deferred wrap-nav re-fires exactly once (`find_wrap_issued` guard; not stuck on cancel — `copy_dispose`
nulls `copy_op`). `copy_op` cleared on EVERY end path (complete/cancel/FRONTIER/teardown). Filter stop-join
deadlock-free (cancel-checked ~2 s wait outside `control_lock`). Clipboard trim safe.

## Non-blocking follow-ups — TRACKED
- **Reverse-clobber (symmetry):** a copy STARTING during an in-flight jump/find/filter-scan can clobber
  THAT op (mis-landed jump / frozen find count / paused filter-scan) — mostly unreachable (dismissing the
  popover to grid-copy cancels the in-flight scan) and self-healing (a CANCELLED filter-scan auto-resumes
  under AUTO); NOT copy data-loss. Optional `do_copy` pre-cancel/deny for full symmetry.
- **Filter-mid-copy drops the partial silently** — `copy_stop_and_join` abandons the in-progress copy with
  no clipboard delivery + no user notice; safe (no UB) but wants a toast.

## Deferred v1 ergonomics (acceptable, not parity-blocking)
Shift-click extend, keyboard (shift+arrow) selection, crisp marquee outline (fill-only for now).

## Gate / discipline
10/10 (18 copy + all). Scope: `src/lsg_copy.c` + `src/main.c`. No frozen drift. Interactive
copy-while-scroll/jump/filter/find on a network doc = the author's desktop pass.
