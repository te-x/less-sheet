# ARCH — GTK "Settings + dialect override" slice

Status: **DRAFT for the author's sign-off.** Author: architect (native). Feature branch of the GNOME/GTK4
port (`apps/gtk`), over the frozen cross-component C ABI (`api/lesssheet.h`, zero change). Umbrella:
`docs/architecture/ARCH-gtk-frontend.md` (this slice amends its **decision 3** — see Technology decisions).
Cross-frontend template: the macOS app (`apps/macos`) is the authoritative design source; this slice
inherits its settled behavior as givens and designs only the GTK-native expression.

---

## Problem & scope

The GTK port already delivers the reading/searching experience (viewer + find + jump + filter + streaming
copy). It cannot yet **change how a document is parsed** or **configure its columns** — the two Settings
surfaces the macOS app owns. This slice adds **full macOS parity** for both, re-expressed in idiomatic
GNOME/Adwaita idioms (the author: "native over identical").

Two independent capabilities:

1. **Dialect override** — change header-on/off, field separator, quote character, and text encoding of the
   open document. At the ABI this is a full document **re-open** (`ls_close` + `ls_open` with a new
   `ls_open_options`); there is no in-place dialect mutator. GTK already has the plumbing
   (`lsg_document_open_local(path, const ls_open_options*, …)`, `lsg_document_dialect(doc)`), and the
   network variant (`lsg_net_open` takes `ls_open_options` too).

2. **Column configuration** — per-column visibility; type override (Auto + text/boolean/integer/decimal/
   date/datetime, datetime naive-vs-offset); display format (number grouping + fixed fraction digits; date
   preset); null sentinel; manual width + auto-fit; and the discovery UX (≤10 columns = a full list; >10 =
   search + `#N` direct address). At the ABI these are **in-place mutators** (`ls_column_*`), all already
   frozen in `api/lesssheet.h`; GTK has no wrappers yet.

**In scope:** the two new pure C modules (`lsg_dialect`, `lsg_column`), the `lsg_formatter` type+options
dispatcher + date-preset extension, the Adwaita Preferences UI (an `AdwPreferencesDialog` with a "Parsing"
page and a "Columns" page) reached from a new `[Settings]` primary menu, the three header-bar dialect
quick-controls (header toggle + separator/quote dropdowns), and the dialect re-open + viewport re-anchor +
column-settings-replay path.

**Non-goals (explicit):**

- **No ABI change.** `api/lesssheet.h` is byte-identical; every capability already exists there. No
  root-`api/` two-key.
- **No persistence / no GSettings for dialect or column config.** Session-only, per-document (parity with
  macOS): all overrides live in frontend state, are cleared on close, and are re-derived per open. (Window
  geometry persistence is a separate, out-of-scope concern.)
- **No accessibility pass** — deferred with the rest of the port (umbrella decision 4 / H6). Adwaita rows
  are already accessible; the custom grid's AT-SPI roles are a later pass.
- **No new format / no new dialect parameter** beyond the four macOS exposes (header, separator, quote,
  encoding).
- **No drill-down navigation** in the Columns editor (the author chose inline expander rows — see decision A).

---

## Inputs / Outputs

**Inputs (user):** the header toggle (the header-bar button or the Parsing switch); the
separator / quote / encoding pickers (+ a "Custom…" single-ASCII-character entry for separator/quote); the
column search query (`#N` or a name substring); and per-column edits (visibility, type, datetime semantics,
number/date format, null sentinel, width, auto-fit, reset-to-Auto, show-all).

**Inputs (core, read):** `lsg_document_dialect(doc)` (the effective `LsgDialect` report + its `*_forced`
bits); `ls_column_metadata_get_many` / `ls_column_metadata_poll` (per-column declared/inferred/override/
effective type, conflict/proposal state, null policy, generation); `ls_column_labels_copy_many` (header
labels for discovery/search); `ls_column_conflict_example_copy`; the raw cell spellings the grid already
reads (for the formatter).

**Outputs (to core):** a composed `ls_open_options` fed to `lsg_document_open_local` / the net re-open (the
dialect change); and the in-place column mutators `ls_column_override_set/clear`,
`ls_column_null_sentinel_set/clear`, `ls_column_inference_request/cancel/accept_proposal`.

**Outputs (to user):** the re-parsed grid (re-anchored on a header toggle, top-left otherwise); formatted
cell display; an `AdwToast` on a header change and on a forced column-settings reset; and the Preferences
dialog itself.

---

## Functional requirements

**Dialect**

- **F1 — Four parameters, one funnel.** Header, separator, quote, and encoding are each changeable; every
  change routes through the SAME compose → validate → re-open funnel. A change composes the next open's
  `ls_open_options` by **carry-forward**: each parameter the current report marks forced starts from its
  effective value as a forced value; each non-forced parameter starts `LS_SNIFF` (re-sniffed on the
  re-open, now excluding any newly forced byte). Encoding carries as the forced value when
  `encoding_forced`, else `LS_ENCODING_AUTO` (re-detected).
- **F2 — Validation (silent no-op on reject).** A separator/quote byte must be ASCII `0x01–0x7F`, not CR
  (`0x0D`) or LF (`0x0A`), and a forced separator must not equal the *carried forced* quote byte (and vice
  versa). An invalid selection returns no options and performs no re-open (parity: silent no-op). Header
  and encoding changes are always valid; an encoding change never touches the dialect bytes.
- **F3 — Quick dialect access = three grouped header-bar controls** (macOS parity: its overlay pills cover
  header + separator + quote). A **header toggle button**, a **separator** `GtkMenuButton` dropdown
  (radio: Comma / Semicolon / Tab / Pipe / Custom…), and a **quote** `GtkMenuButton` dropdown (radio:
  Double / Single / None / Custom…). Encoding is Preferences-only (macOS parity — it is not a pill). All
  three quick-controls and the Preferences "Parsing" page reflect and drive the SAME dialect state (the one
  source of truth = the effective dialect report) through the one compose → validate → re-open funnel; each
  shows the current effective value and marks a forced vs sniffed value. (There is no separate menu
  check-item for the header — the header-bar toggle button is its quick affordance.) The header change
  raises an `AdwToast` "First row is now a header" / "First row is now data" (the glyph/switch change alone
  is easy to miss — parity with macOS's auto-fading notice).
- **F3b — "Custom…" inline entry.** Choosing "Custom…" in the separator/quote dropdown reveals a one-ASCII-
  character `GtkEntry` inside the same popover (committed on Enter), routed through the identical compose
  funnel so `lsg_dialect` still owns validation (F2) — a rejected byte is a silent no-op. (Decision F: the
  in-popover entry, not a hop to Preferences — parity with the macOS pill's inline "Custom…" field.)
- **F4 — Encoding picker.** Options in a fixed order: Automatic, then UTF-8, UTF-16 LE, UTF-16 BE,
  ISO-8859-1, Windows-1252. In Automatic mode the row shows the resolved/detected encoding as a subtitle;
  a forced choice confirms the value. Choosing Automatic re-detects on the re-open.

**Re-open behavior**

- **F5 — Header toggle preserves the viewport.** A header on/off re-open re-anchors the grid to the same
  file record: the pure header-shift is `0` when unchanged, `-1` when turning the header ON, `+1` when
  turning it OFF; the grid captures its current top data-row and re-anchors to `top + shift` (clamped).
  Separator / quote / encoding changes rest at the top-left.
- **F6 — Re-open clears find/filter/jump, silently.** The core re-open resets search/filter/jump; the
  frontend resets the matching UI (fold the filter banner + reset the filter control in the Find popover,
  clear the find/jump popovers and highlights). No toast — the folded banner / reset control are
  self-evident (parity).
- **F7 — Column settings replay or reset across a dialect re-open.** Before a re-open the frontend
  snapshots the user-authored per-column settings (override, null sentinel, format, visibility, manual
  width — nothing inferred). After the re-open a pure decision maps them onto the new document:
  **replay ordinally** iff safe — a header-only change with an unchanged column count, or a
  separator/quote/encoding change with an unchanged column count where both sides have a header, no header
  identity is truncated, and the ordered decoded header identities are byte-identical — else **reset all**.
  On replay the frontend re-applies overrides + null sentinels via `ls_column_*` on the new doc (format /
  visibility / width are frontend state, replayed directly). On reset it raises an `AdwToast` "Column
  settings were reset — columns changed".
- **F8 — Network documents re-open through the network funnel.** A dialect change on a network document
  re-opens via the net-open path (with the composed `ls_open_options`), never by feeding the URL to the
  local open (the macOS bug this must not reproduce).

**Column discovery + inspector**

- **F9 — Discovery mode.** `0` columns → an empty state; `≤ LSG_COLUMN_FULL_LIST_MAX` (= 10) → a full
  list of every column; `> 10` → search-only, showing up to the same bound of matches. Exactly one named
  threshold constant resolves the mode (single-source-of-truth).
- **F10 — Search + `#N`.** In search-only mode a search entry matches on a localized, case-insensitive
  substring of the column's searchable text (its header label, or the generic name + 1-based index — e.g.
  column 26 → "AA 27" — when headerless/empty). A `#N` (1-based) or exact-name query resolves to a single
  column directly (out-of-range `#N` → a "No such column" notice). Matching runs in bounded label batches
  (`LSG_COLUMN_LABEL_BATCH_MAX` = 1024), retains at most 10 matches plus a "more — refine your search"
  overflow bit, and returns IDs in source-column order.
- **F11 — Per-column inspector (inline expander).** Each listed column is an `AdwExpanderRow`; expanding it
  reveals the full editor inline: visibility, type (Auto + 6 kinds), datetime naive-vs-offset (only when the
  effective kind is datetime), a guessed-type read-out, conflict / format-unavailable status, number format
  (grouping + fixed fraction digits 0–38) OR date format (Original / Localized Short / Medium / Long) per
  the effective kind, null sentinel (toggle + exact-value entry), and width (adjust + Auto-fit) — plus
  "Reset to Auto" when overridden. At most one row is usefully open at a time; opening a row auto-collapses
  the previously-open one (mitigates the tall-row shove the author flagged).
- **F12 — Show All + live inference.** A "Show All" affordance restores every column's visibility; a
  document-wide "guessing types" progress indicator is shown while inference runs for the displayed columns.
- **F13 — Edits repaint the grid immediately.** Every column mutation (visibility, type, format, null
  sentinel, width) re-materializes the visible window and repaints the grid synchronously — the GTK analog
  of the macOS REPAINT-FAMILY rule (a config mutation must poke the grid, never wait for the next scroll).

**Display formatting**

- **F14 — Type+options dispatcher (frontend-owned).** Given a raw cell, the effective type (kind +
  datetime semantics), and the column's format options, the formatter produces the display string: raw
  spelling for AUTO / no-option columns; lossless grouped/fixed-fraction decimal or grouped integer for
  number columns (exact base-10 arithmetic, half-even, `UNAVAILABLE`→raw when not exactly representable —
  the existing `lsg_formatter` guarantee); and, for date/datetime columns, the raw spelling (Original) or a
  `GDateTime`-formatted localized short/medium/long string (naive vs zoned honored). Find / filter / copy
  keep the RAW value (the ABI rule) — formatting is display-only.

**Chrome placement (this slice's signed header-bar changes; decision E)**

- **F15 — Copy has no header-bar button.** The Copy button is removed from the bar. The copy FEATURE is
  unchanged — `Ctrl+C` on a selection triggers the existing streaming copy job (`lsg_copy` / `ls_copy_*`),
  with its notice + cancel. This slice only removes the bar button; no copy logic changes.
- **F16 — Filter entry point folds into the Find popover.** There is no separate header-bar filter toggle;
  the filter-to-matches control lives inside the Find popover (coupled with the find query). The `AdwBanner`
  and the filter behavior itself are unchanged — only the entry point moves.

---

## Non-functional constraints (verified by measurement / structure, not claim)

- **N1 — Cold-start unchanged (< 500 ms; O(viewport) open).** This feature is entirely demand-driven: the
  Preferences dialog is built only when opened, and column inference / label reads / metadata polls fire
  only for the displayed columns when the Columns page is shown. The open path does NO column inference,
  NO dialect work, and NO whole-file read before first paint. A fresh document displays raw spellings (all
  AUTO) with no inference. (Umbrella G4/G5/H2 invariants preserved by construction.)
- **N2 — O(visible) column work.** On a wide (100k-column) document the Columns page instantiates and
  requests metadata/labels for O(shown columns) only (≤ 10, bounded by the discovery mode — no list
  virtualization is needed because the mode itself caps the visible rows), never O(total columns).
  Inference requests target only the displayed columns.
- **N3 — Re-open is O(head), not O(file).** A dialect re-open is a fresh `ls_open`, which serves its first
  window from the post-open frontier; changing the dialect on a multi-GB file re-anchors and paints as fast
  as the initial open.
- **N4 — Pure logic is display-free + deterministic.** `lsg_dialect`, the pure half of `lsg_column`, and
  the `lsg_formatter` dispatcher touch no widgets and no display server; formatter locale glyphs / dates
  are injectable/pinned so the arithmetic and preset outputs are deterministic under `g_test`.
- **N5 — Single source of truth for knobs.** The full-list threshold (10), the label batch (1024), the
  retained-match cap (10), and the fraction-digit ceiling (38) are each one named constant with one
  resolver; the header state has one source (the effective dialect report) feeding all three affordances.
- **N6 — No leaks / clean cancel.** Opening/closing Preferences, cancelling inference, and dialect re-opens
  leak nothing and are safe against concurrent close (the two-lane lock discipline); every borrowed
  `ls_str` / label / example buffer is copied out immediately (invalid UTF-8 → U+FFFD).

---

## Component decomposition & data flow

Mirrors the established GTK layering (frozen `include/lsg_*.h` contract → display-free `src/lsg_*.c` +
core-bridge functions → widgets in `main.c`), and the `lsg_find` two-layer template: a PURE value
view-model plus a thin `lsg_document_*` bridge that is the single caller of the core, both declared in one
feature header and pinned by `g_test`.

### New module — `lsg_dialect` (`include/lsg_dialect.h`, `src/lsg_dialect.c`)

Pure, display-free — the C analog of Swift `DialectComposing` + `EncodingPicker` + `DialectCandidates`
(`apps/macos/Sources/Contracts/Dialect.swift`). No core calls. Surface (prose; the planner freezes the
signatures):

- A `LsgDialectChange` tagged value (separator byte / quote byte-or-none / header bool / encoding enum).
- `compose(LsgDialect report, LsgDialectChange change) → ls_open_options` **producing the frozen ABI
  struct directly** (no redundant override type) with a reject/accept result; implements F1 carry-forward +
  F2 validation.
- The header-shift helper (F5): `0 / -1 / +1` from old-vs-new header state.
- The encoding picker view-model (F4): ordered options, the option a report shows selected, the resolved
  "detected" encoding.
- The candidate lists (separators `, ; TAB |`; quotes `" '`) as named constants (view-model only; the
  user-facing glyph/label copy lives in the UI).

### New module — `lsg_column` (`include/lsg_column.h`, `src/lsg_column.c`)

Two layers, like `lsg_find`:

- **Pure view-model** (C analog of `ColumnDiscovery` + `ColumnLabelSearch` + `ColumnSessionModel` +
  `GenericColumnName`): discovery mode from column count (F9); `#N` / exact-name direct-address resolution
  and the per-batch localized-substring match with the generic-name fallback + retained-10 + overflow (F10);
  the user-settings snapshot, its full reset, and the replay-vs-reset re-open decision (F7). Values only, no
  core, no widgets.
- **Core bridge** — the `lsg_document_column_*` functions that are the SINGLE place the frontend calls
  `ls_column_*` (extending the document session, taking `LsgDocument *`): metadata get-many / poll, label
  copy-many, conflict-example copy, override set/clear, null-sentinel set/clear/copy, inference
  request/cancel/accept-proposal. Copies every borrowed buffer out immediately. Sits on the poll/control
  lane (any thread; not concurrent with close).

### Extended module — `lsg_formatter` (existing `include/lsg_formatter.h` + `src/lsg_formatter.c` GROW)

The header already anticipates this ("the SETTINGS UI that drives non-AUTO options … and localized
DATE-PRESET formatting are LATER slices"). Add: a `LsgColumnFormatOptions` value (grouping, fraction-digits
or "source length", date preset); the **type+options dispatcher** that composes over the existing kind gate
+ lossless decimal/integer formatters (F14); and **date/datetime preset formatting via `GDateTime`** —
parse the strict `YYYY-MM-DD` / `YYYY-MM-DDTHH:MM:SS[.f][Z|±HH:MM]` spelling and render Original / localized
short / medium / long with `g_date_time_format`, honoring naive-vs-zoned. GLib/`GDateTime` + the C-library
locale, NOT ICU (decision 8, already settled).

### UI — Adwaita Preferences + quick affordances (in `main.c`, new region; possibly a `settings`-scoped set of helpers)

- **`AdwPreferencesDialog`** (decision A amendment) with two `AdwPreferencesPage`s:
  - **"Parsing"** — one `AdwPreferencesGroup`: an `AdwSwitchRow` (header), `AdwComboRow` separator + quote
    (with a "Custom…" entry revealing an `AdwEntryRow` for one ASCII char, routed through the same compose
    funnel so `lsg_dialect` still owns validation), and an `AdwComboRow` encoding (with the detected
    subtitle).
  - **"Columns"** — the discovery search (an `AdwEntryRow` / the page search, shown in search-only mode),
    an `AdwPreferencesGroup` of ≤10 per-column **`AdwExpanderRow`s** (title = label/generic name, subtitle =
    source · kind + a warning marker, a visibility switch/check as the row prefix; the inline inspector as
    nested `AdwComboRow` / `AdwSwitchRow` / `AdwSpinRow` / `AdwEntryRow` + buttons per F11), a "Show All"
    control, and an inference-progress row.
- **`[Settings]` primary menu — NEW.** `main.c` today has no `GActionMap`/`GMenu`; this slice introduces a
  `GSimpleActionGroup` + a `GMenu` behind a header-bar gear/menu button. It opens the `AdwPreferencesDialog`
  (Parsing + Columns) and holds **Keyboard Shortcuts** + **About**. (Open / Open URL stay as their own bar
  buttons per decision E — they are NOT in this menu.)
- **Two grouped dialect quick-controls + the header toggle (F3).** A **header toggle button**, a
  **separator** `GtkMenuButton` dropdown, and a **quote** `GtkMenuButton` dropdown — each dropdown popover a
  radio list of candidates + a "Custom…" row revealing a one-char `GtkEntry` (F3b). The header toggle
  button is the header state's quick affordance (there is no menu check item); it and the two dropdowns and
  the Parsing page all drive the one dialect funnel and stay in sync. Grouped adjacent on the right of the
  bar per decision E.
- **Header-bar layout (decision E — SIGNED exact arrangement).**
  - **Left (`pack_start`):** `[Open file]` `[Open URL]` (stay on the bar — the author's veto of the relocation).
  - **Center:** the document title (`AdwWindowTitle`), unchanged.
  - **Right (`pack_end`):** `[Find]` `[Jump]` `[Header toggle]` `[Separator ▾]` `[Quote ▾]` `[Settings]`,
    plus the reusable header-progress box (shown during long ops). The `[Settings]` gear is the primary
    menu above.
  - **Off the bar:** the **Copy button is dropped** (the copy feature stays — `Ctrl+C` on a selection + the
    copy job — just no bar button); the **filter toggle folds into the Find popover** (no separate bar
    control). See F15 + F16.
- **Re-open / re-anchor path.** A dialect change → `lsg_dialect` compose → close + re-open (local via
  `lsg_document_open_local`, or the net path for a network doc) → rebuild the grid, reusing the existing
  `filter_rebuild_grid` grid-rebuild+re-anchor pattern; apply the header-shift re-anchor (F5) or rest at
  top-left; reset find/filter/jump UI (F6); run the column replay-or-reset (F7) with its toast. The header
  toast (F3) and reset toast (F7) use the existing `AdwToast` overlay.

### What changes vs stays

- **New:** `lsg_dialect.{h,c}`, `lsg_column.{h,c}`, `tests/test_dialect.c`, `tests/test_column.c`; the
  Preferences dialog + primary menu + header-bar toggle + the two `GAction`s in `main.c`; two new
  `meson.build` sources + two test executables.
- **Grows:** `lsg_formatter.{h,c}` (+ `tests/test_formatter.c`); `main.c` (chrome, re-open path); the grid's
  cell paint calls the new formatter dispatcher instead of always-raw once a column carries options.
- **Unchanged:** `api/lesssheet.h` (zero change); `lsg_document.h`/`lsg_find`/`lsg_jump`/`lsg_filter`/
  `lsg_copy`/`lsg_net_open`/`lsg_grid_geometry`/`lsg_window_poll` surfaces (consumed, not modified).
- **Deleted:** nothing.

---

## External interfaces (frozen ABI consumed — zero change)

- **Dialect:** `ls_open` / `ls_open_options` / `ls_open_url_start` (net) and `ls_dialect_get` (read back the
  effective dialect), via the existing `lsg_document_open_local` / `lsg_net_open` / `lsg_document_dialect`.
- **Columns:** `ls_column_metadata_get_many`, `ls_column_metadata_poll`, `ls_column_labels_copy_many`,
  `ls_column_conflict_example_copy`, `ls_column_override_set`, `ls_column_override_clear`,
  `ls_column_null_sentinel_set`, `ls_column_null_sentinel_clear`, `ls_column_null_sentinel_copy`,
  `ls_column_inference_request`, `ls_column_inference_cancel`, `ls_column_inference_accept_proposal`, and
  the `ls_column_type` / `ls_column_metadata` / `ls_column_inference_status` / `ls_column_label_span`
  fixed-layout structs.
- **System / GNOME:** GTK 4.16+ / libadwaita 1.6+ (`AdwPreferencesDialog`, `AdwPreferencesPage/Group`,
  `AdwExpanderRow`, `AdwComboRow`, `AdwSwitchRow`, `AdwSpinRow`, `AdwEntryRow`, `AdwToast`); `GMenu` +
  `GSimpleAction`; `GDateTime` + the C-library locale for formatting.

---

## Technology decisions (chosen option, alternatives, rationale)

Decisions A–D below are this slice's calls; A and B were confirmed by the author on 2026-07-20 (relayed).
GLib-not-ICU is already settled (umbrella decision 8) and is reused unchanged for the date-preset work.

- **A. Columns editor = inline `AdwExpanderRow` per column** (the inspector expands in place inside the
  Columns page's group). *Confirmed by the author* over the alternative **drill-down subpage**
  (`AdwNavigationView` push per column). Rationale: he compared mockups and preferred the inline layout.
  *Known trade-off (designed for):* an open row is tall and shoves the rest down, and only ~one row is
  usefully open at a time — mitigated by the discovery cap (the list is always ≤10 rows) and by
  auto-collapsing the previously-open row.
- **B. Preferences container = `AdwPreferencesDialog` — AMENDS umbrella decision 3.** *Confirmed by
  the author.* The umbrella named `AdwPreferencesWindow`, which libadwaita **deprecated at our 1.6 floor** in
  favor of `AdwPreferencesDialog` (presented sheet-like, attached to the main window). Per "prefer native
  and latest" we adopt the current idiom; the small UX delta from macOS's separate Settings *window* is
  accepted. Two pages: "Parsing" + "Columns". (Umbrella decision 3 is updated to reflect this; the author's
  answer is the sign-off.)
- **C. Compose targets `ls_open_options` directly.** The pure `lsg_dialect` composer emits the frozen ABI
  struct itself rather than a GTK-private override type + a mapping step (as macOS needs, because Swift
  can't hold the C struct as its model). Fewer types, one less mapping, and the validation domain is
  exactly the ABI's. *Alternative rejected:* a mirrored `LsgDialectOverride` type — redundant in C.
- **D. No list virtualization on the Columns page.** Because the discovery mode caps the visible list at
  ≤10 rows for any column count, the O(viewport) invariant is met by the mode itself; the macOS
  `ColumnPanelLayout` (3·visible+8 row virtualization over an `NSTableView`) has no GTK analog here.
  *Alternative rejected:* a virtualized `GtkListView` — unnecessary complexity for a ≤10-row list, and it
  fights the inline-expander choice (A).
- **E. Header-bar layout = signed exact arrangement (the author, 2026-07-20).** Not a proposal — the final
  bar:
  - **Left:** `[Open file]` `[Open URL]` — **stay on the bar** (the author vetoed relocating them into the
    menu; each is a compact single-icon square button, so ~9 items is not too busy).
  - **Center:** the document name (title widget).
  - **Right:** `[Find]` `[Jump]` `[Header toggle]` `[Separator ▾]` `[Quote ▾]` `[Settings]`.
  - `[Settings]` is the primary menu / gear button: it opens the `AdwPreferencesDialog` (Parsing + Columns)
    and holds Keyboard Shortcuts + About.
  - Separator + quote get quick-access alongside the header toggle as `GtkMenuButton` dropdowns (the author's
    chosen form); encoding stays Preferences-only (macOS parity — it is not a pill).
  *(No relocation; the earlier declutter proposal is withdrawn.)*
- **F. "Custom…" separator/quote = an inline entry in the dropdown popover**, not a hop to the Preferences
  Parsing page. Closest parity to the macOS pill's inline "Custom…" field, fewest clicks, stays in context;
  routed through the same `lsg_dialect` compose funnel so validation is shared. *Alternative rejected:*
  "Custom…" opens/focuses the Parsing page — an extra navigation hop for a one-character entry.

---

## Acceptance criteria (testable; grouped by who verifies)

### GATE — deterministic, headless, run in-gate (Linux container)

- **G1 — Builds, links, conforms.** `meson compile` builds the two new modules + the formatter growth under
  `-Werror` (signature drift against the frozen `lsg_dialect.h` / `lsg_column.h` / `lsg_formatter.h` fails
  the build); the app binary is produced; `api/lesssheet.h` is byte-identical (root-gate `api/` integrity)
  and `include/lesssheet.h` stays a symlink.
- **G2 — Dialect compose + validate (`g_test`, pure).** Carry-forward matrix: a forced parameter re-emits
  its effective value as forced, a non-forced one emits `LS_SNIFF`; encoding carries as forced value vs
  `LS_ENCODING_AUTO`. Validation: a byte outside `0x01–0x7F`, CR, LF, or a separator equal to the carried
  forced quote (and the mirror) → rejected/no-op; changing to equal a merely *sniffed* other byte is
  accepted; header + encoding changes always accepted; an encoding change leaves the dialect bytes
  untouched.
- **G3 — Header-shift (`g_test`, pure).** `0` unchanged, `-1` header→on, `+1` header→off.
- **G4 — Encoding picker (`g_test`, pure).** The six options in the fixed order; the selected option for a
  forced vs Automatic report; the detected/resolved encoding surfaced.
- **G5 — Column discovery + search (`g_test`, pure).** Mode thresholds (`0`→empty, `≤10`→full, `>10`→
  search-only) off the single named constant; `#N` 1-based direct address (+ out-of-range → no-such-column)
  and exact-name resolution; localized case-insensitive substring match with the generic-name fallback
  ("AA 27"); the 1024 batch, the ≤10 retained + overflow bit, and source-column result order.
- **G6 — Column session model (`g_test`, pure).** `reset` clears every column to Auto; `decide` →
  replay-ordinally iff (header-only, equal count) or (sep/quote/encoding, equal count, both headered, no
  truncation, byte-identical ordered identities), else reset-all (count mismatch / reorder / rename /
  truncation / a headerless side on a byte change).
- **G7 — Column core bridge (`g_test` over the real core + a fixture).** `override_set` then a metadata
  read shows the effective type = the override, `override_clear` reverts; `null_sentinel_set/clear` reflect
  in `null_policy` + `null_sentinel_copy`; `inference_request` → `metadata_poll` progresses to a resolved
  metadata + label copy-many returns the header labels; a conflict fixture yields a conflict state +
  example copy. Every returned buffer is an owned copy (no dangling borrow).
- **G8 — O(visible) column work (probe).** On a synthetic wide (100k-column) fixture, showing the Columns
  page issues metadata/label/inference requests for ≤10 column IDs only, never enumerating all columns.
- **G9 — Formatter dispatcher + dates (`g_test`, pinned locale/tz).** Integer grouping and decimal
  fixed-fraction (half-even) match the existing lossless guarantee, `UNAVAILABLE`→raw for
  non-representable values; AUTO / no-option → raw spelling; date/datetime presets (Original / short /
  medium / long) render deterministically under an injected/fixed locale + timezone, honoring naive vs
  zoned; a non-date raw under a date column falls back to raw.
- **G10 — Re-open logic wiring (`g_test`, pure).** Compose→`ls_open_options` for each of the four changes
  feeds the correct fields; the replay-vs-reset decision selects the correct branch for header-only vs
  byte changes; find/filter/jump reset is invoked on every re-open.
- **G11 — No leaks / clean cancel.** Open→configure→close, inference cancel, and a scripted dialect re-open
  leak nothing and are safe against a concurrent close (container leak check).

### HUMAN GUI PASS — the author, on a real GNOME desktop (recorded, not gate-blocking)

- **H1 — Native Preferences.** An `AdwPreferencesDialog` with "Parsing" + "Columns" pages looks like a
  standard GNOME Settings surface (light/dark + system accent followed live); the inline column expanders
  read and edit naturally.
- **H2 — Dialect quick-controls stay synced.** The three header-bar controls (header toggle, separator ▾,
  quote ▾) and the Preferences "Parsing" page all reflect the same state — changing any one updates the
  others; each triggers the correct dialect re-open. The header toggle preserves the viewport (re-anchored
  to the same record) and shows the "First row is now a header / data" toast; separator/quote changes rest
  at the top-left.
- **H2b — Signed header-bar layout.** Left: `[Open file] [Open URL]`; center: the document name; right:
  `[Find] [Jump] [Header] [Separator ▾] [Quote ▾] [Settings]` (the `[Settings]` gear opens Preferences +
  holds Keyboard Shortcuts / About). No Copy button on the bar (`Ctrl+C` still copies a selection); no
  separate filter toggle (it lives in the Find popover). The bar reads native and uncluttered.
- **H3 — Dialect changes re-open.** Separator / quote (incl. an in-popover Custom… single ASCII char) /
  encoding changes re-parse the grid; an invalid custom byte is a silent no-op; a network document re-opens
  over the network (not treated as a local path).
- **H4 — Column config is live + correct.** Visibility, type override (incl. datetime naive/offset),
  number grouping / fixed fraction, date preset, null sentinel, and width/auto-fit each repaint the grid
  immediately (no wait-for-scroll); "Reset to Auto" and "Show All" work; the guessed-type read-out,
  conflict, and format-unavailable states show.
- **H5 — Discovery UX.** On a >10-column document the search narrows the list, `#N` jumps to a column,
  out-of-range `#N` shows "No such column"; opening one column's expander auto-collapses the previous.
- **H6 — Re-open toasts + resets.** A dialect change that forces a column-settings reset shows the "Column
  settings were reset — columns changed" toast; a safe change replays the overrides; clearing an active
  find/filter on re-open is silent (folded banner / un-pressed toggle).

---

## Open Questions

None. Every native-UX fork is resolved by the author's 2026-07-20 answers and recorded as decisions A–F +
F3/F3b/F6/F7/F15/F16: columns editor shape (A), Preferences container (B), the signed exact header-bar
layout incl. Open/Open-URL staying on the bar + Copy dropped + filter folded into the Find popover (E), and
quick-access for header + separator + quote (F3). The engineering calls (C: compose→`ls_open_options`;
D: no virtualization; F: in-popover Custom… entry) are baked in with rationale. There are NO remaining
`CONFIRM AT SIGN-OFF` markers — the layout is signed, not a proposal.
