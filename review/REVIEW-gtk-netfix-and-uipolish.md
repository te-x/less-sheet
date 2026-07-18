# REVIEW — GTK network find/filter fix + UI-polish round

**Verdict: PASS (1 round + a jump-glyph addition).** Bound to tree-hash `67a986ff…`, trusted
gate 9/9 GREEN. Driven by the author's live desktop GUI pass (the first real-GNOME test of the GTK
frontend). One NON-BLOCKING `[impl]` fast-follow recorded below.

## Scope
`apps/gtk/src/lsg_find.c` + `src/main.c` (IMPL). The logo GResource (`meson.build` + `data/`) is a
separate planner-blessed DEPENDENCY amend, committed `e9d27e7`. The net-park find test
`/find/resolved-net-park-landing` was frozen RED-first (`4dee820`).

## (A) Network fix — the durable rule
On a network (`http_range`) doc the fetch frontier is DEMAND-DRIVEN (ABI lines ~670, 2116-2129;
core correct-by-design, nfd_ac6/nfd_ac25): it advances ONLY via `ls_jump_start`/`ls_search_nav`;
a bare `ls_window_set` fetches nothing. **Frontend rule: every net-doc landing beyond the fetched
head — find-result, filter-apply, filter-scroll, deep-scroll — drives a jump/nav, never bare
`ls_window_set`.** Probe-diagnosed (`/tmp/netprobe.zig`).

- **Bug 1 (find "Stopped"):** net `ls_search_nav` lands the first match then PARKS at CANCELLED in
  the same poll (nav=FOUND + phase=CANCELLED together). The unconditional `CANCELLED → STOPPED`
  map in `lsg_find_resolved` masked the real "N of M" on every network find. Removed it →
  `notice=NONE`, count folds through. STOPPED now belongs ONLY to the (unchanged, unwired)
  `lsg_find_stopped`, so no genuine user-stop regresses. Also corrects a latent macOS mislabel
  (`FindLogic.swift .cancelled→.stopped`) — the outcome-pin forbids the port from inheriting it.
- **Bugs 2+3 (filter-empty + latent deep-scroll):** `is_network` flag threaded through
  `open_document`; `net_drive_begin/poll` reuse `ls_jump_start`/`jump_poll` folded over the
  ~100 ms `grid_poll_tick` (non-blocking, no busy-loop), wired at filter-apply (drive row 0),
  deep/filter scroll (drive `cur_top_row` when the window returns SHORT); inert on local docs.
  Reviewer-accepted caveat: filtered scroll drives the filtered index as an original row — always
  UNDER-shoots (a match's filtered index ≤ its original row), monotone, single-drive guard
  prevents fetch-storm; worst case = incremental under-fill needing another scroll nudge. No
  overshoot/stall/storm. Net-live fills are NOT gate-testable (no fake-net at the C-ABI) →
  the author's desktop pass.

## Fast-follow (NON-BLOCKING `[impl]`) — RESOLVED (follow-up batch)
`net_drive_begin` and `do_jump_submit` both call `ls_jump_start` on the single core jump slot; the
scroll re-trigger gates only on `!net_drive_active`, NOT on an in-flight USER jump
(`jump.kind == LSG_JUMP_FLOW_SCANNING`). On a net doc a manual scroll during a manual-jump-scan
could retarget the slot to `cur_top_row` and mis-land the jump (network-only, specific
interleaving, often masked by GtkPopover autohide; mislanding not corruption). **Fix:** gate
`net_drive_begin` on `jump.kind != LSG_JUMP_FLOW_SCANNING` (and/or suppress the scroll-drive while
the jump popover is open).

**RESOLVED** in a follow-up batch (main.c, reviewer PASS on tree-hash `628d747`, gate 9/9): gated
`net_drive_begin` with an early return on `jump.kind == LSG_JUMP_FLOW_SCANNING` at the single choke
point — filter-apply still drives (it resets jump→IDLE before driving), the scroll-drive yields to
a live user jump, no stall (a dropped drive re-fires on the jump-landing scroll). The same batch
also (a) reverted data cells → `Monospace 10` (headers stay `Sans Bold 10`; the author: "monospace for
the data, sans serif for the rest" — restores the uniform-advance width geometry + macOS parity)
and (b) made the jump `GtkMenuButton` flat via `set_has_frame(FALSE)` (its custom `set_child` glyph
missed the `image-button` auto-flatten class, so it rendered a persistent frame).

## (B) UI polish (7) — code-level ✓; visual fidelity = the author's desktop pass
1. URL icon `emblem-web-symbolic` (dropped from current Adwaita → blank) → `insert-link-symbolic`.
2. Cells `Monospace 11` → `Sans 10` / header `Sans Bold 10`; `measure_font` feeds the proportional
   `char_advance` to the frozen `lsg_grid_geometry` heuristic (no frozen change; ellipsized, no
   clip); header font restored after draw + freed at teardown.
3. Logo → GResource embedded (no install); the registered resource path
   (`…/icons`) + hicolor gresource layout (`…/icons/scalable/apps/dev.lesssheet.Gtk.svg`) +
   window `icon-name` line up (planner's mismatch concern resolved).
4. Jump icon → custom Cairo glyph replicating macOS `JumpArrowGlyph` (two circles + right-bulging
   arc + SW arrowhead), theme-tinted via `gtk_widget_get_color` (light/dark), libm-free.
5. Jump Enter → entry `activate` → `do_jump_submit` (the internal GtkText consumed Return before
   the bubble controller; removed the dead controller case). Escape stays on the controller.
6. Horizontal scrollbar → `upper = overflow ? content : page` + hide when not overflowing (no dead
   bar; re-shows at the autofit overflow boundary).
7. Header/no-header toggle → correctly DEFERRED to a proper dialect slice (needs source-tracking +
   async forced-dialect re-open + viewport preservation + a `lsg_dialect`/compose module the GTK
   port lacks) — not a main.c wire.

## Discipline
No core changes; no frozen-contract drift; logo dependency amend planner-blessed (no new external
dep, `.ci/Dockerfile` untouched). Verification split: code-level cleared here; net-live fills +
all visual renders (icons, fonts, logo, jump glyph) are the author's desktop / net-live pass.
