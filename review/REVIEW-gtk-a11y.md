# REVIEW — GTK accessibility slice (keyboard cell-nav + AT-SPI + AdwShortcutsDialog)

**Verdict: PASS (1 round, clean).** Build cell (implementer + reviewer, both opus, run-id `gtk_a11y`)
on branch `feat/kbdnav-a11y`; implementation commit `8e00de0`, frozen contract `838c886`. Orchestrator
ran the trusted gate `--require-frozen --relay gtk_a11y` = **GATE PASS** (integrity OK / conformance OK /
behavior GREEN 13/13, `a11y` 19/19) on the new **fedora:43** base; `verify-relay` PASS (implementer +
reviewer handoffs byte-exact). Implements the deferred **H6 / decision-4** of `ARCH-gtk-frontend.md`;
signed design `docs/architecture/ARCH-gtk-a11y.md` (APPROVED 2026-07-21).

the author's four scope decisions (2026-07-21): grid = **labeled region** (not a per-cell AT-SPI table);
keyboard cell selection + horizontal scroll **in scope**; **AdwShortcutsDialog** (real shortcuts window,
GAction promotion); **skip mnemonics**. FR1 later corrected to **seed-only/no-step** (2026-07-22,
cross-frontend with macOS; doc `60650a8`).

## What shipped (`apps/gtk/src/lsg_a11y.c` + `main.c` only — both IMPLEMENTATION_PATHS)
- **Pure module `lsg_a11y` (gate-tested):** cursor/selection reducer (seed / move-collapse / shift-extend
  / page / home-end / horizontal / capped select-all / clear; clamped; empty-extent no-op), byte-exact
  announcement builders (cursor + 80-char UTF-8 clip; `N rows × M columns selected`; find-landing),
  grid-description builder, the single 16-entry accelerator table (APP/GRID/DISPLAY scopes), FR4
  control-name table.
- **Widget wiring (gate-blind; reviewer structural lens + the author's Orca pass):** grid `GtkDrawingArea`
  role=GROUP + name "Data grid" + dynamic description; polite `gtk_accessible_announce` for exactly the
  FR3 set (cursor LOW; extend/select-all, filter, find-landing, copy-complete MEDIUM; silent on
  scroll/scan-ticks/estimate); AT-SPI names on all 12 bare controls (single `lsg_a11y_control_name`);
  decorative glyphs role=NONE; **AdwShortcutsDialog** generated from the accel table (old
  AdwPreferencesDialog stub + `add_shortcut_row` removed); GAction promotion via
  `gtk_application_set_accels_for_action` (`on_window_key` removed); grid keys stay grid-scoped (G-A7);
  keyboard cursor over the reducer (seed-no-step, minimal auto-scroll on the existing `vadj`/`hadj`
  net-park, Ctrl+A, Ctrl+C single-cell, Esc lowest-priority clear); accent active-cell outline from
  `adw_style_manager_get_accent_color_rgba` (no literal color).

## Reviewer-confirmed (the residue the gate can't see)
Tests general (no test-input-keyed constants). Announcements fire once on discrete events (copy-complete
inside the `finished && !CANCELLED` branch, not per-tick). G-A7 holds **structurally**: the grid key
controller is attached in the **bubble** phase, so a focused find/jump/Where `GtkText` consumes Ctrl+C /
Ctrl+A first. C memory-safe: `a11y_announce` owns+frees its msg (callers pass fresh strings);
`a11y_column_name` returns heap on all branches (matching `g_free`); borrowed `gtk_label_get_text` not
freed. SSOT respected (one accel table, one control-name source, one `a11y_view_rows` resolver).

## Non-blocking [impl] notes (reviewer; no [contract]/[design] findings)
1. **N1 — SSOT for a derived value.** The "fully-visible row count" `(h − header_h)/row_h` is inlined at
   three new sites (main.c:1773-1775, :1805-1808, :1867-1869). Correctly distinct from `cur_span.row_count`
   (overscan), so reusing the span would be wrong — but the three copies could fold into one
   `a11y_visible_rows(app)` accessor. Low severity, single file. **Disposition:** bundle into the
   post-GUI-pass fix round rather than spend a dedicated round.
2. **N2 — Shift+arrow as the very first grid keypress** (empty selection) seeds a 1×1 and announces
   "1 rows × 1 columns selected" (MEDIUM) rather than the seeded cell's "Row R, Col: value" (LOW), because
   `grid_cursor_apply` gates on the raw `extend` flag (main.c:1896). Debatable; **an H-A2 Orca judgment
   call for the author's live pass.**

## ACCEPTED WITHOUT AN ORCA PASS (the author, 2026-08-04) — read this before trusting the a11y claims

the author built and ran the app on GNOME (Arch/arch, Ryzen 3600) and reported "gtk looks and feels
good". He then decided explicitly: **"I don't know how to test Orca accessibility, so let's trust the
implementation."**

So, stated plainly so nobody later mistakes this for verified:

- **PASSED by human inspection:** H-A5 (no regression), the accent ring / light-dark look from H-A4,
  and the app building and launching on a real GNOME desktop.
- **NOT VERIFIED, accepted on the implementation + the gate:** **H-A2** (Orca announcements match
  FR3, including the `grid_cursor_apply` raw-`extend` judgment call at `main.c:1896`) and the
  screen-reader half of **H-A4** (every control *named* under Orca). **H-A3** (shortcuts window via
  `Ctrl+?` / `Ctrl+F1` and the menu) was not separately confirmed either.
- What *is* machine-verified underneath: the display-free cursor reducer, the announcement and
  description builders, and the accelerator/name tables are all gate-tested in `lsg_a11y.c` (13/13
  meson suites). What no gate can check is whether AT-SPI actually surfaces them to a screen reader.

If accessibility is ever claimed publicly, or if a user reports a screen-reader problem, **this is the
gap to close first** — it needs someone with Orca, not more tests.

One defect was found and fixed during that session: **Shift+wheel did not scroll horizontally**
(`d8ac6b4`) — the scroll handler never read the modifier, and a mouse wheel reports only a vertical
delta, so with a plain mouse a wide document could not be panned at all.

## (was) Pending: human GNOME/Orca pass (the author, `run_gtk_on`)
H-A1 keyboard-only select+copy end to end; H-A2 Orca announcements match FR3 (watch N2); H-A3 shortcuts
window via Ctrl+? / Ctrl+F1 + menu, complete/correct; H-A4 every control named under Orca + accent ring
follows live GNOME accent in light/dark; H-A5 no regression. Reassemble/rebuild on GNOME before testing.

## Process note
Ran **in parallel** with the macOS keyboard-nav cell (`mac_kbdnav`, disjoint component). `role-runner`
`tree-hash` is **repo-wide** (folds in HEAD + `git status`), so it cannot be compared verbatim across
parallel cells — the post-review digest drift was entirely the macOS cell's `apps/macos` writes;
component-scoped `git diff … -- apps/gtk` confirmed the reviewed tree unchanged.
