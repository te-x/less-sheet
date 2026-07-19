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
