# REVIEW — GTK Settings + dialect override slice

**Verdict: PASS (reviewer round 2).** Branch `gtk/settings-dialect` → master. Native aidev cycle
(architect=fable interactive → planner freeze → implementer ⇄ reviewer, all with the author sign-off).
Orchestrator-verified: trusted `--require-frozen apps/gtk` = GATE PASS (fedora-container `-Werror`/
warning_level=2 compile + `clang-format --dry-run -Werror` + all 12 g_tests, G1–G11), 0 frozen/api drift.
**Zero root-`api/` change** — pure consumer of the existing `ls_dialect_*` / `ls_column_*` ABI.

Full macOS-parity Settings, expressed in native GNOME idioms (the author: "native over identical").

## Design (signed: docs/architecture/ARCH-gtk-settings-dialect.md; umbrella decision 3 amended → AdwPreferencesDialog)
- **Preferences = `AdwPreferencesDialog`, 2 pages:** *Parsing* (header switch, separator/quote/encoding
  rows + "detected/forced:" subtitles + Custom… single-ASCII entry) · *Columns* (search + `#N`, inline
  `AdwExpanderRow` inspector per column — visibility/type/datetime-semantics/number-format/date-preset/
  null-sentinel/width — auto-collapse the prior open row).
- **Header bar (the author's signed layout):** LEFT `[Open file][Open URL]` · title · RIGHT
  `[Find][Jump][Header toggle][Separator ▾][Quote ▾][Settings]`. Copy button dropped (Ctrl+C stays),
  Filter folded into the Find popover; `[Settings]` gear → the dialog + a primary menu (Shortcuts/About).
- **New modules:** `lsg_dialect` (compose/validate/carry-forward → emits `ls_open_options` directly,
  header-shift, encoding picker), `lsg_column` (pure discovery/`#N`/label-search/session-reopen + the core
  bridge over `ls_column_*`), `lsg_formatter` ext (`lsg_format_cell` type+options dispatcher + GDateTime
  presets, GLib not ICU). Session-only, no GSettings.
- **Dialect re-open funnel (F5–F8):** compose → re-open (`lsg_document_open_local`/`lsg_net_open_start`) →
  viewport re-anchor (header toggle ±1 record) → replay-ordinally-or-reset-all + toast → find/filter/jump
  reset. **F8: network docs re-open through the net funnel** (`lsg_net_open_start` + `ls_jump_start`
  landing, never a bare `ls_window_set`) — the durable net-doc rule; the macOS bug is NOT reproduced.

## Rounds
- **R1 — CHANGES REQUESTED (core correct).** Reviewer traced F8 in code (PASS), re-derived F5 against the
  ABI source-row convention (PASS), confirmed all pure logic sound + no test-shaped shortcuts + no leaks +
  Ctrl+C intact. 3 `[impl]` + 1 low: (1) stale `reopen_pending` on a failed/cancelled re-open → a later
  fresh open fires a bogus replay/reset+toast (doc claimed it was cleared; no code did); (2) F7 replay was
  O(columns) core reads on wide docs → ~100k lock+reads at re-open, violating the O(visible) invariant;
  (3) manual column width re-grown by the monotone auto-fit-on-scroll (+ Reset-to-Auto couldn't shrink);
  (4) datetime explicit-offset not range-checked → `+05:99` silently rendered UTC. 5 self-flags: (a) pack
  direction resolved-in-code; (b/d/e) → GUI pass.
- **R2 — PASS.** Fixed via an idempotent `reopen_state_clear` on all 10 fail/cancel + fresh-open paths
  (success paths untouched); the F7 replay cache gated to `has_override || !is_auto(format)` (= exactly the
  set the formatter reads) → O(authored); `grid_autofit_widths` excludes `has_manual_width` columns +
  `on_col_reset` re-samples the auto width (leak-free); `match_datetime` range-checks the offset → invalid
  yields ORIGINAL(raw). Reviewer re-checked the delta: all closed, no regressions, no new issues.

## Human GUI pass (the author, real GNOME — H1–H6, not headlessly gateable)
The logic is gate-green; the UI visuals need `run_gtk_on`: H1 native two-page Preferences · H2 header toggle
synced across the bar toggle + Parsing + preserved viewport + toast (+ H2b header-bar left→right order &
icon presence) · H3 separator/quote/custom/encoding re-open incl. net-doc · H4 live column-edit repaint ·
H5 >10-col search + `#N` + auto-collapse · H6 reset-toast on unsafe re-open + silent find/filter clear.
Non-blocking self-flags to eyeball: dropdown radios don't pre-check the current value (labels/combos do);
Auto columns format only after configured; named symbolics render blank if absent in the installed Adwaita.
