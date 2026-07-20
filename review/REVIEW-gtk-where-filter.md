# REVIEW — GTK predicate "Where" filter + (×) clear-filter

**Verdict: PASS.** Build cell (implementer + reviewer, opus), `master` commit `b88eff5`, `apps/gtk/src/main.c`
only. Orchestrator gate `--require-frozen apps/gtk` = GATE PASS (container `-Werror` + clang-format + 12
g_tests), 0 frozen/api drift. **No new contract** — pure UI over the predicate engine already frozen +
gate-pinned from the find slice (`lsg_find_submit` validation, `lsg_document_search_start`/`filter_set`
bridge, `match_flags`; `tests/test_find.c`/`test_filter.c` unchanged).

Closes the reading/searching parity gap on GTK: find · jump · filter · **predicate**.

## What shipped
- **`Text | Where` mode switch** in the Find popover (GtkStackSwitcher + 2-page GtkStack; prev/next +
  status + Filter-to-matches shared). Where body = a searchable column `GtkDropDown` + an operator glyph
  dropdown (`= ≠ < > ≤ ≥`, tooltips + a11y labels) + one value entry.
- **`find_read_draft`** = the single widgets→`find.draft` funnel (find, filter, toggle-gate). Column model
  built lazily (`where_ensure_columns`, on first Where entry/show — open stays O(viewport)) from
  `lsg_document_column_labels_copy_many`; hidden columns kept as legal targets, tagged "(hidden)".
  Mode/column/op changes re-run; value validated at SUBMIT.
- **Reject feedback generalized** into shared `entry_reject_feedback`/`_clear` (jump re-routed through it):
  `.error` + shake gated on `gtk-enable-animations` (reduce-motion), NO core call on reject.
- **Predicate filter:** `do_apply_filter` routes the same request to `lsg_document_filter_set`;
  `filter_update_toggle_sensitivity` widened to any non-IGNORED draft.
- **(×) clear-filter:** `AdwWindowTitle` replaced by a custom centered title widget (`.title` name over a
  subtitle row: `.subtitle` status + a flat/circular `window-close-symbolic` button, visible iff
  `filter.active` → `do_clear_filter`). `update_title_subtitle` stays the single subtitle source.

## Reviewer-confirmed (the residue the gate can't see)
Op map 1:1 (`EQ=0..GE=5`); column dropdown index == real column index (search doesn't shift `selected`);
borrowed `text`/`value` consumed synchronously by submit (no UAF, per the contract); **jump-reject
behavior-identical after the refactor + leak-free** (destroy-notify frees the ctx, re-trigger `g_source_remove`s
first, all 3 teardown paths remove the timer); **all 4 `adw_window_title_set_*` sites migrated, zero
stragglers**, (×) hidden→zero-alloc when unfiltered, title fields nulled on destroy; filter-toggle re-entry
guarded (`filter_ui_guard`); memory clean (string-list/expr/factory ownership, label-array free with matching
`n`, byte-ownership stolen).

## Non-blocking notes (the author's GUI pass / optional follow-ups)
1. **[design, the author's call] Where auto-runs `= ''` on mode-entry** → highlights empty cells. This is genuine
   contract/macOS parity (EQ accepts an empty value = matches empty cells). Fine to ship; *optionally* gate
   the auto-run on a non-empty value if the instant highlight feels surprising.
2. **[nit, pre-existing] Untracked reject-shake idle** — `reject_shake_add`'s GSource isn't tracked/cancelled
   (the 700ms timeout IS). Practical risk ~zero (fires next loop iteration; keyframes start/end at
   `translateX(0)`). Pre-existing (old `jump_shake_add` had the same). Optional hardening: track + remove the
   idle id.
3. **[nit] Stale "(hidden)" tag** — computed at first Where entry, refreshed only on a new doc; toggling
   column visibility in Settings mid-doc leaves a stale tag. Column-index mapping is unaffected → predicate
   correctness intact; purely cosmetic. Optional: re-arm `where_columns_dirty` on a visibility change.
4. **[a11y-nit] the (×) button** has a tooltip but no explicit `GTK_ACCESSIBLE_PROPERTY_LABEL` — folds into
   the upcoming accessibility slice.

## Human GUI pass (the author, `run_gtk_on`)
Build a `Where <col> <op> <value>`; confirm predicate find-highlight + Filter-to-matches both apply it; an
ordering op (`< > ≤ ≥`) with a non-numeric value → red-blink + shake, no crash; the (×) beside the filter
status clears the filter.
