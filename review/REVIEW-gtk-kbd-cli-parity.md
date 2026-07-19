# REVIEW — GTK keyboard + CLI parity (Ctrl+O / Ctrl+Shift+O / `less-sheet <path>`)

**Verdict: PASS (round 2).** Native cell (implementer + reviewer = opus); orchestrator-run trusted gate
`--require-frozen apps/gtk` GREEN (10/10, `-Werror` clean) on tree-hash `f7b7f7d8…`; reviewer PASS bound to
that tree. Scope: `apps/gtk/src/main.c` only (+16/−2). No frozen-surface / `tests/` / `meson.build` drift.

the author's ask: match the macOS open shortcuts + CLI in the GTK/Linux frontend — Ctrl+O (file), Ctrl+Shift+O
(network URL), and `less-sheet <path>` opening directly incl. `.csv.gz`.

## What shipped
- **Ctrl+O → open file / Ctrl+Shift+O → open network URL.** Wired into the existing capture-phase window
  key controller `on_window_key` (same `GtkEventControllerKey` that handles Ctrl+F/G/L), reusing the exact
  `action_open` / `action_open_url` the header-bar + launch-screen buttons trigger. A single
  `keyval == GDK_KEY_o || GDK_KEY_O` branch selects on the **Shift mask** (not the o/O keyval case, which is
  layout-dependent) — which also dodges the Caps-Lock trap (CapsLock sets `GDK_LOCK_MASK`, not `SHIFT_MASK`,
  so CapsLock+o still opens a LOCAL file). Both arms return `GDK_EVENT_STOP`. Mirrors macOS ⌘O / ⌘⇧O
  (`AppUI.swift` `.newItem` CommandGroup).
- **CLI `less-sheet <path>` incl. `.csv.gz` — verified, no code change needed.** `G_APPLICATION_HANDLES_OPEN`
  → `on_open` → `open_file` → `lsg_document_open_local`, with NO `.csv`-only / extension / MIME filter
  anywhere (the file dialog sets no filter either, so `.csv.gz` is pickable via Ctrl+O too). The core detects
  gzip by content; the frontend passes the raw path through, exactly as macOS does. Smoke-proven in a
  fedora:42 arm64 container against the real bridge + real `liblesssheet.a` (`.csv.gz` → OPEN OK, identical
  to the plain `.csv` control). The command NAME (`less-sheet` vs the dev `less-sheet-gtk`) is a packaging
  concern (flatpak/deb), not this change — the open *mechanism* is what was verified.

## Rounds
- **R1 — PASS on mechanics, one `[impl]` finding.** Reviewer confirmed: Shift-mask selection correct +
  Caps-Lock-safe; `on_window_key` is `GTK_PHASE_CAPTURE` so the shortcuts are global (work from the grid, a
  focused entry, and the blank launch screen — matching ⌘O menu globality); no clash with Ctrl+C (grid) /
  Ctrl+F/G/L; `action_open`/`action_open_url` defined above the handler + `(void) button;` so the `NULL` arg
  is safe; CLI `.csv.gz` delegated filter-free to the core, smoke evidence sound; structure single-source
  (reuses the button actions, no duplicated logic), tree clean. **Finding 1 [impl]:** the two new shortcuts
  were undiscoverable via the frontend's OWN convention — find/jump/copy buttons advertise "(Ctrl+F)" etc. in
  their tooltips, but the Open buttons stayed bare. A GNOME-a11y discoverability inconsistency (the author's hard
  requirement), fixable trivially in-scope.
- **R2 — PASS.** Implementer added the accelerator to all four Open surfaces via the same
  `gtk_widget_set_tooltip_text` + `"<Action> (<Accel>)"` convention: header `open_btn` (3005) = "Open File
  (Ctrl+O)", `url_btn` (3012) = "Open URL (Ctrl+Shift+O)"; launch-screen pills `open` (2871) / `open_url`
  (2876) got matching tooltips where there were none (the highest-value spot — first screen a new user sees).
  Accelerator strings match the actual handler. Reviewer re-checked only the delta: confirmed, no residual.

## Deferred (correctly out of scope)
- **A GMenu/hamburger primary menu + `GtkShortcutsWindow`** — a pre-existing gap affecting ALL shortcuts
  equally (Ctrl+F/G/L/C never had a menu either); this change does not make it worse. Belongs in a dedicated
  a11y/menu slice, not here. Do not build it as scope-creep.

## Non-blocking observation (desktop GUI-pass glance)
Because `on_window_key` is capture-phase + global, pressing Ctrl+O / Ctrl+Shift+O while the in-window URL
`AdwAlertDialog` is already open could stack a second dialog. Consistent with the pre-existing capture-phase
Ctrl+F/G/L behavior; not introduced here and not gating — worth a quick manual check on the desktop pass.

## Human verify (not headlessly gateable)
Tooltip display + the interactive shortcuts are visual/interactive → the author's desktop pass: Ctrl+O opens the
file picker, Ctrl+Shift+O opens the URL dialog, hover shows the accelerator on all four Open surfaces,
existing Ctrl+F/G/L/C unaffected, and `less-sheet-gtk <file.csv.gz>` opens directly.
