# REVIEW — GTK network-loading fixes (frontend batch)

**Verdict: PASS (2 rounds).** Bound to tree-hash `175394ca…`, trusted gate 10/10. The FRONTEND half of
the network-loading bug cluster the author found on his desktop (32 MB stats.govt.nz URL). The CORE half
(#1 hang, #2 deep-jump, #5 round-trips, jump-scan progress) is a **separate backend cell** — those are
the actual latency/hang fixes; this batch is the frontend-side fixes + loading status.

## Fixes (all `src/main.c`)
- **#4 — gutter row-number font → sans (deterministic).** New `gutter_font_desc = "Sans 10"` (non-bold;
  created + freed in `main()`); `grid_draw`'s gutter loop flips `layout`→`gutter_font_desc` then restores
  `app->font_desc` (the header block's pattern). Data stays Mono 10, header Sans Bold 10.
- **#3 — invalid-jump reject shake (runtime-verify).** The `.lsg-shake` keyframes animated
  `margin-left/right` → changed the entry's allocation → the `GtkPopover` re-measured/re-anchored mid-shake
  and visually detached. Rewrote to `transform: translateX(...)` (paint-time, no allocation change).
  Reviewer confirmed GTK4 DOES support CSS `transform` (correcting a stale earlier-slice claim). Reject
  wiring unchanged.
- **#6 — jump/find popover follows the button on resize (runtime-verify).** Button-parented popovers don't
  auto-re-anchor on parent resize in GTK4; `on_area_resize` now `gtk_popover_present()`s any MAPPED popover
  (find + jump).
- **#5-frontend — net-open loading status → the unified header-bar progress.** The URL open drives the
  same reusable header-bar progress copy uses (the author's title-bar-progress direction): pulse while
  connecting → determinate "Fetching N%" as head bytes arrive → hide at first paint / every terminal
  (DONE/FAILED/CANCELLED). **Subsumes the old net `AdwBanner`** (removed cleanly; filter banner untouched);
  the header ✕ is cancel-aware (net vs copy).

## Round 2 — overlap fix (reviewer's non-blocking `[impl]`, folded in)
Removing the net banner made copy + net-open share the ONE header-progress widget, and they are NOT
mutually exclusive (a copy of the OLD doc can run while a URL open of a NEW doc is in flight until DONE) →
flicker / hidden survivor bar / mis-routed ✕. **Fix (both directions):** `copy_stop_and_join` at the top
of `on_url_response` (after the URL commit, before `app->net` goes non-NULL — a URL open replaces the doc,
like the filter path); `do_copy` (sole copy entry) refuses to start while `app->net != NULL`.
**Reviewer PASS:** serialization holds (all synchronous main-thread code between `copy_stop_and_join` and
`app->net = lsg_net_open_start`; `g_thread_join` blocks without iterating the main loop → no interleave →
at most one of `copy_op`/`net` non-NULL); no regression (`app->net` nulled at every net terminal → a copy
is allowed once an open completes). False "mutually exclusive" comment corrected.

## Discipline
`src/main.c` only; no frozen drift; gate 10/10. #3/#6 shake+popover visuals + the net-open look are
the author's desktop/runtime pass; the code-level correctness (banner removal, progress lifecycle, overlap
serialization) is reviewed sound.

## Follow-up: valid-deep-jump-vanishes → jump-close hardening (2 rounds, PASS)
the author: a VALID deep jump (row 220k, which EXISTS in the 224k-row net doc) did nothing + the input
vanished. Diagnosed: **PRIMARY = the core #1/#2 HttpRange-mutex hang** (the ~26 MB scan to row 220k
freezes the main thread; the separate BACKEND cell fixes it → responsive scan + land). **SECONDARY =
a pre-existing frontend gap:** `on_jump_popover_closed` (the slice-3 handler) cancelled+restored a
SCANNING jump on ANY close, so an incidental autohide during the freeze abandoned the valid jump. NOT
a regression of this batch (the diagnosis ruled out #3/#6/#5).
- **R1 (preserve):** a `jump_explicit_close` flag distinguishes Escape (explicit → cancel+restore) from
  an incidental autohide (PRESERVE the scan → the global `grid_poll_tick` timer folds it → lands). ✕
  untouched (self-handles). Reviewer confirmed the flag lifecycle is leak/misread-free, the land path is
  not hijacked (LANDED before `closed` fires), and doc-reset tears the scan down (no UAF).
- **R2 (retire — reviewer's blocking `[impl]`):** preserving a scan past its popover meant it could be
  alive when FIND or COPY takes the shared scan slot, but only FILTER had the symmetric cleanup → a
  preserved jump + Find = a phantom-SCANNING **stuck-state** (`ls_search_start` cancels the CORE scan to
  IDLE but `app->jump` stayed SCANNING; an IDLE poll never resets a live flow → the poll never stops AND
  `net_drive` keeps yielding → net deep-scrolls show 0 rows, RE-introducing the symptom) + a COPY
  mis-land. **Fixed** by retiring `app->jump = lsg_jump_initial()` when find (the `ls_search_start`/`nav`
  slot-take) and copy take the slot, mirroring `do_apply_filter`; deliberately NOT on the empty-query
  `ls_search_cancel` path (ABI 1256-1264: cancel leaves the jump slot unaffected → a preserved jump
  legitimately survives a find-clear). Copy `lsg_document_jump_cancel`s + retires before its worker's
  async `ls_jump_start`. **Reviewer PASS:** the slot-interaction set is now COMPLETE + consistent
  (filter/find/copy retire; find-cancel + net_drive-yield preserve) — no phantom-SCANNING path remains.
Gate 10/10, `main.c` only. The interactive deep-net-jump behavior needs the BACKEND mutex fix for its
primary responsiveness → the author's real-host pass on the combined build. See [[gtk-frontend]] task #21
(systematic scan-slot coordination — the ad-hoc coordination that produced this + prior findings).
