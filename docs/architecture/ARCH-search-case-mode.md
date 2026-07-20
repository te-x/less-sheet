# ARCH — search case-mode ("Match case" toggle)

Status: SIGNED (architect + the author, 2026-07-20). api/lesssheet.h amended and root-frozen by the root planner; the backend matcher and both frontends are re-pinned next by their component planners. Scope: **cross-component** — a
`api/lesssheet.h` change + core (Zig) matcher change + a "Match case" toggle in
BOTH frontends (macOS, GTK). This **deletes the current smart-case rule entirely**
and replaces the invisible in-core case decision with an explicit per-request
`case_sensitive` flag driven by a UI checkbox. It is a v1 frozen-surface change;
there is no backward-compat obligation (we control both frontends and the backend
and rebuild lock-step; there are no external ABI consumers).

Interview givens (the author, 2026-07-20):
- **Q1 — plain 2-state "Match case" checkbox.** OFF (default) = case-insensitive;
  ON = byte-exact. Smart-case is retired.
- **Q2 — the toggle folds predicate `=`/`≠` too.** OFF (default) =
  ASCII-case-INSENSITIVE for BOTH text substring AND predicate `=`/`≠`; ON =
  byte-exact for both. Ordering ops (`<` `>` `≤` `≥`) are numeric — unaffected.
  Two defaults change: uppercase text queries no longer auto-switch to exact
  (smart-case gone), and `= isabella` now matches `Isabella`/`ISABELLA` by default.
- **Q3 — live + session.** One shared "Match case" control in the find popover,
  next to "filter to matches". Flipping it re-issues the active find AND re-applies
  an active filter immediately. State persists for the window session, NOT across
  app restarts.
- **No backward-compat.** v1, lock-step static rebuild, no external ABI consumers
  → make the change cleanly; no SMART/legacy path, no compat gymnastics.

---

## 1. Problem & current model (verified)

Today the case decision is derived **entirely inside the core**, invisibly:

- **Text find = SMART CASE.** A cell matches when the query is an ASCII substring;
  if the query has any ASCII uppercase byte (`0x41..0x5A`) the compare is
  byte-exact, else ASCII-case-insensitive. Bytes `>= 0x80` (all non-ASCII UTF-8)
  always compare exactly. Pinned at `api/lesssheet.h:779-788`.
- **Predicate `=`/`≠` = BYTE-EXACT.** No folding, no trimming
  (`api/lesssheet.h:802-805`).
- **`ls_search_request` has no case field** (`api/lesssheet.h:822-830`) — the
  matcher decides internally.

The asymmetry (forgiving text vs strict predicate) is what a user trips on, and
both behaviors are *invisible* — no control, no indication of which rule is in
force. the author: "we should have a case sensitive toggle in both frontends."

The whole case decision already funnels through **one bool** in the core —
`MatchCtx.fold` (`backend/src/base.zig:226`) — consumed by the single per-cell
verdict `matcher.cellMatches` (`backend/src/matcher.zig:401`), which is shared by
the match-scan, nav, filter counting, AND the `ls_window_match_flags` highlight
mask. So a per-request case flag flows to every match surface for free; the core
change is small and localized. The rest of the work is UX + deleting the retired
smart-case rule from the frozen surface.

---

## 2. Technology decision — the `api/lesssheet.h` change

### 2.1 A plain `bool case_sensitive` on `ls_search_request`

Append one field to the request struct:

```c
typedef struct ls_search_request {
    ls_search_kind kind;
    ls_search_op op;
    uint32_t column;
    const uint8_t *value_ptr;
    size_t value_len;
    const uint32_t *scope_ptr;
    size_t scope_len;
    bool case_sensitive; /* NEW. false (default) = ASCII case-INSENSITIVE;
                          * true = byte-exact. Governs LS_SEARCH_TEXT substring
                          * and predicate LS_SEARCH_OP_EQ/NE only. */
} ls_search_request;
```

- **`false` (the default) = ASCII case-INSENSITIVE**; **`true` = byte-exact.**
- Governs `LS_SEARCH_TEXT` substring matching and predicate `LS_SEARCH_OP_EQ`/`NE`.
  Ordering predicates (`LT`/`GT`/`LE`/`GE`) are numeric and ignore it.
- ASCII-only folding: bytes `0x41..0x5A` fold to their lowercase forms; every byte
  `>= 0x80` (all non-ASCII UTF-8) always compares exactly. Full Unicode folding
  stays out of scope (unchanged invariant).
- No enum, no SMART value, no auto-from-query detection. The single knob is the
  bool; the frontend checkbox maps to it 1:1.

`bool` is already used across the header (e.g. `ls_search_start` returns `bool`),
so no new include is required.

### 2.2 This is a clean v1 frozen-surface change (no additive gymnastics)

The additive-discipline note (`api/lesssheet.h:1345`, and the match-flags note at
`2148-2151`) is about *external* ABI stability — a client compiled against a prior
header linking unchanged. That does not apply here: all `api/` consumers statically
link the core and rebuild lock-step from the same header (single repo; the root
gate chains every component gate; no external pinned-binary consumer exists). So
`ls_search_request` is grown and the smart-case prose is rewritten directly — it is
still a planner freeze of the frozen surface (two-key CHANGE-REQUEST, anti-tamper
gate re-armed), just without any compat path.

The planner MUST re-pin the Zig mirror of the struct (`api.SearchRequest`, consumed
at `backend/src/root.zig:248,278`) and any comptime layout assertion to match the
grown C struct, and confirm no `LS_*_STATIC_ASSERT` covers `ls_search_request`
(those cover the column-config snapshots only).

### 2.3 Doc rewrites on the frozen header (part of the change — smart-case is GONE)

The change REWRITES the pinned prose that currently describes smart-case /
byte-exact predicate. Smart-case is deleted, not "reachable at value 0":

- `api/lesssheet.h:779-788` (TEXT smart-case block) → describe the plain rule:
  `case_sensitive == false` ⇒ ASCII-case-insensitive substring;
  `case_sensitive == true` ⇒ byte-exact substring. Keep the "ASCII only; bytes
  `>= 0x80` always exact; full Unicode folding out of scope" invariant verbatim.
  Remove all mention of "smart case" / query-uppercase auto-detection.
- `api/lesssheet.h:802-805` (predicate EQ/NE "NO case folding") → EQ/NE honor
  `case_sensitive`: `false` folds ASCII, `true` is byte-exact; the empty value
  still legally matches empty/padded cells; ordering ops still ignore case.
- `api/lesssheet.h:2153-2160` (match-flags "smart-case substring" mention) → "the
  active request's `case_sensitive` substring / EQ-NE rule".
- Note in both `ls_search_start` and `ls_filter_set` prose that they honor
  `case_sensitive` identically, so nav / filter counts / match-flags inherit it.

---

## 3. Technology decision — the core matcher (backend Zig)

Delete the query-uppercase-detection path; the fold is now driven purely by the
flag, identically for text and predicate `=`/`≠`.

- **`fold = !request.case_sensitive`**, for BOTH `startSearch`
  (`backend/src/search.zig:650`) and `setFilter` (`backend/src/filter.zig:300`),
  for BOTH kinds. Store into `d.search_fold` / `d.filter_fold` (already present:
  `backend/src/base.zig:226,267`).
- **DELETE `matcher.queryFolds`** (`backend/src/matcher.zig:198`) and its call
  sites (`backend/src/search.zig:666,705`, `backend/src/filter.zig:318`) — the fold
  no longer depends on the query bytes at all.
- **`matcher.cellMatches`** (`backend/src/matcher.zig:401`):
  - TEXT branch already threads `ctx.fold` into `textMatch` — mechanically
    unchanged; it now receives `!case_sensitive`.
  - PREDICATE `eq`/`ne` branch (currently `std.mem.eql`) must fold when `ctx.fold`:
    ASCII-case-insensitive equality (equal length + per-byte
    `asciiLower(a) == asciiLower(b)`, reusing the existing `asciiLower`; bytes
    `>= 0x80` compare exactly, matching `textMatch`'s invariant). `case_sensitive`
    keeps `std.mem.eql`. `ne` stays the exact complement of `eq`.
  - Ordering ops (`lt/gt/le/ge`) untouched — numeric, case-irrelevant.
- **KMP failure table** (`matcher.buildFailure`, `backend/src/matcher.zig:203`)
  already takes `fold`; pass `!case_sensitive`. No new allocation shape.
- `MatchCtx.fold` (`backend/src/base.zig:226`) doc-comment widens from "TEXT
  smart-case (all-lowercase query)" to "fold ASCII case for TEXT substring and
  predicate EQ/NE (== !case_sensitive)"; update the sibling `filter_fold`
  (`base.zig:267`) too.

No new core allocation, no new threading lane, no scan-frontier or cold-start
impact: a folded compare is the same per-byte work already used today. Perf rule
satisfied by a null-result note (no measurable delta expected; reviewer confirms
via the differential bench if warranted).

---

## 4. Technology decision — the "Match case" toggle UX (both frontends)

One shared session bool `caseSensitive` (default `false` = OFF = insensitive),
shared across Text and Where modes, marshaled 1:1 to `request.case_sensitive` at
the single request-construction choke point. macOS is the authoritative design
template; GTK expresses it natively.

### 4.1 macOS (`apps/macos`, SwiftUI) — the template
- Add a "Match case" control to the find popover next to the existing filter row
  (`apps/macos/Sources/LessSheetApp/FindControls.swift:120-132`), patterned on that
  row's `Toggle(...).toggleStyle(.switch).controlSize(.mini)` (or a native
  checkbox — implementer's call within native-UI convention). Label "Match case".
- New session field `caseSensitive: Bool = false` on `FindDraft`
  (`apps/macos/Sources/Contracts/FindControl.swift:231`), threaded through
  `SearchRequest` (`.../Contracts/FindControl.swift:42`), the composer
  `FindControl.submit` (`apps/macos/Sources/LessSheetKit/FindLogic.swift:35`), and
  the one C-struct marshaling choke point `withSearchRequest`
  (`apps/macos/Sources/LessSheetKit/CoreDocumentSession+Search.swift:70`) — which
  already feeds both `ls_search_start` (`:118`) and `ls_filter_set` (`:166`), so
  find, filter, nav, and the highlight mask all inherit `case_sensitive` from this
  one place.
- **DELETE any macOS smart-case logic.** If the frontend anywhere derives
  case-sensitivity from the query (mirroring the old core rule), remove it; the
  checkbox is the only source.
- **Live re-issue** on toggle: re-run the active find (`submitFind`,
  `apps/macos/Sources/LessSheetApp/ViewerModel+Find.swift:25`) and, if
  filter-to-matches is on (`isFiltered`), re-apply the filter (`applyFindAsFilter`,
  `apps/macos/Sources/LessSheetApp/ViewerModel+Filter.swift:70`). Because the
  freshly-composed request now differs from `findSession.display.request` when the
  case flips, `submitFind`'s "same request → advance" shortcut (`:36`) correctly
  restarts rather than steps. If a repaint gap appears, apply the durable
  REPAINT-FAMILY rule (synchronous `NativeGridController.live?.apply()` poke).
- Session-scoped: lives on `findSession.draft`, resets with a fresh window/reopen;
  not persisted to disk.

### 4.2 GTK (`apps/gtk`, GTK4/libadwaita) — native expression
- Add a `GtkCheckButton` labelled "Match case" in `build_find_popover`
  (`apps/gtk/src/main.c:2306`), in the same vertical box as the existing
  `"Filter to matches"` toggle (`main.c:2364`); `"toggled"` handler re-runs the
  query.
- New field on the find session draft `LsgFindDraft`
  (`apps/gtk/include/lsg_find.h:249`), read by `find_read_draft`
  (`apps/gtk/src/main.c:1778`), threaded through `LsgSearchRequest`
  (`include/lsg_find.h:180`) and `lsg_find_submit` (`src/lsg_find.c:142`), mapped
  1:1 to `case_sensitive` at the single ABI-marshaling choke point
  `lsg_build_abi_request` (`apps/gtk/src/lsg_document_internal.h:59`) — which feeds
  both `lsg_document_search_start`→`ls_search_start` and
  `lsg_document_filter_set`→`ls_filter_set`.
- **DELETE `lsg_find_query_case_sensitive`** (`apps/gtk/src/lsg_find.c:60`) and its
  test-only references — the smart-case mirror is gone; the core decides from
  `case_sensitive`.
- **Live re-issue**: the toggle handler calls `find_run_query`
  (`apps/gtk/src/main.c:1829`) and, if a filter is active, re-applies via
  `do_apply_filter` (`main.c:3084`). (GTK text find is already incremental via
  `search-changed`, so re-issue on toggle is consistent.)
- Session-scoped: retained on the session/widget for the window's lifetime; not
  persisted across restarts.

### 4.3 Cross-frontend reuse
Both frontends: **one** checkbox bool → **one** `case_sensitive` marshal at **one**
choke point → text find + predicate find + filter + highlight mask all inherit it.
Neither frontend implements or derives ANY case logic. macOS's placement / labeling
/ behavior is the template GTK mirrors natively. (Single-source-of-truth-for-knobs:
one session bool per frontend, one marshal, every consumer reads the one value.)

---

## 5. Frozen-surface ripple (multi-component; planner(s) amend)

Deleting smart-case + the new defaults changes CURRENTLY-PINNED behavior across the
frozen surface. The ACs in §6 REPLACE the smart-case ACs. Per component:

- **`api/` (root planner, two-key CHANGE-REQUEST):** the `case_sensitive` field, the
  smart-case doc deletions/rewrites (§2.3), the Zig-mirror layout re-pin (§2.2).
  Arms the anti-tamper gate on the new frozen shape.
- **Backend (Zig):** delete `queryFolds` + call sites; matcher/search/filter tests
  that assert smart-case (text `"USA"`→exact / `"usa"`→fold) and byte-exact
  predicate EQ/NE → re-expressed as the sensitive-vs-insensitive matrix (§6.B).
- **macOS:** delete any smart-case logic; find tests asserting smart-case and any
  frozen FindControl/SearchRequest contract → updated for the "Match case" model +
  new defaults; add the toggle-wiring ACs (§6.C).
- **GTK:** delete `lsg_find_query_case_sensitive`; `tests/test_find.c` (incl. the
  assertion at `:105-114`) and any find contract → updated for the new model +
  toggle wiring.

---

## 6. Acceptance criteria (testable; planner turns these into frozen tests)

ASCII-fold means bytes `0x41..0x5A` compare equal to their lowercase forms; every
byte `>= 0x80` compares exactly (unchanged invariant). "Insensitive" = the default
(`case_sensitive == false`); "sensitive" = `case_sensitive == true`.

### A. ABI value-pins (`api/`)
- **A1.** `ls_search_request` has a `bool case_sensitive` field (no case enum
  exists; no SMART value anywhere in the ABI).
- **A2.** `case_sensitive` governs `LS_SEARCH_TEXT` substring and
  `LS_SEARCH_OP_EQ`/`NE` only. For `LS_SEARCH_OP_LT`/`GT`/`LE`/`GE` (numeric) the
  match verdict is identical for `case_sensitive` true and false.
- **A3.** The same `case_sensitive` is honored identically by `ls_search_start` and
  `ls_filter_set`; and therefore by `ls_search_nav` and `ls_window_match_flags`
  (which reuse the active request). Same validation/rejection rules apply
  regardless of `case_sensitive`.

### B. Core matcher behavior matrix (backend)
TEXT substring (query vs cell), ASCII:
- **B1 insensitive:** query `"usa"` matches cells containing `usa`/`USA`/`Usa`; AND
  query `"USA"` ALSO matches `usa`/`USA`/`Usa` (case ignored in BOTH directions —
  the key departure from smart-case, which made `"USA"` exact).
- **B2 sensitive:** query `"usa"` matches only cells containing exact `usa`; query
  `"USA"` matches only exact `USA`.
- **B3 non-ASCII:** in both modes a byte `>= 0x80` (e.g. accented UTF-8) is never
  folded — an insensitive query does not fold non-ASCII.

PREDICATE `=`/`≠` (single column), ASCII:
- **B4 insensitive:** `EQ "isabella"` matches cells `isabella`/`Isabella`/`ISABELLA`;
  `NE "isabella"` is the exact complement.
- **B5 sensitive:** `EQ "isabella"` matches only exact `isabella`; `NE` complement.
- **B6 empty value:** `EQ ""` still matches empty and padded/ragged cells in both
  modes.
- **B7 ordering unchanged:** `LT/GT/LE/GE` verdicts identical for both `case_sensitive`
  values (numeric).

Cross-surface (same verdict everywhere):
- **B8.** For an insensitive request, the matches reported by the match
  scan/count, by `ls_search_nav`, by the filter row-set/count, and by the
  `ls_window_match_flags` mask AGREE cell-for-cell with `cellMatches` — all four
  surfaces inherit `case_sensitive` from the one verdict.

### C. Frontend toggle wiring + live re-issue (both frontends; C1-C4 macOS, C5-C8 GTK)
- **C1 / C5 present + default:** a "Match case" control exists in the find popover
  next to "filter to matches"; default state is OFF (insensitive).
- **C2 / C6 shared + mapped:** the control is a single session bool shared by Text
  and Where modes; at the one request-construction choke point OFF marshals to
  `case_sensitive = false`, ON to `case_sensitive = true`.
- **C3 / C7 default product behavior (through the frontend path):** with the toggle
  OFF, a text find for `"USA"` matches `usa` cells, and a predicate `= isabella`
  matches an `Isabella` cell — verified via the frontend's built request, not just
  the core. Turning it ON makes both byte-exact.
- **C4 / C8 live re-issue + session scope:** flipping the toggle immediately
  re-issues the active find AND, when filter-to-matches is active, re-applies the
  filter (fresh, progress-reporting rescan) — no re-submit/re-open required. State
  persists for the window session and is NOT saved across app restarts (a fresh
  window/reopen starts OFF).

### D. Regression — no smart-case remnant anywhere
- **D1.** No smart-case / query-uppercase auto-detection survives in any component:
  `matcher.queryFolds` is deleted (backend), `lsg_find_query_case_sensitive` is
  deleted (GTK), and no macOS code derives case-sensitivity from the query. The
  ONLY thing that decides folding is `case_sensitive`. (Testable as: a request with
  `case_sensitive = false` folds an uppercase query `"USA"` onto `usa` — proving
  the old "uppercase ⇒ exact" auto-rule is gone — and grep/contract checks that the
  deleted symbols no longer exist.)
- **D2.** No cold-start / scan-frontier regression: behavior-shaping of the existing
  fold bool; matching cost unchanged (null-result perf note; reviewer confirms via
  the differential bench if warranted).

---

## 7. Non-goals / out of scope
- **Unicode / locale case folding** — ASCII-only, consistent with the existing
  pinned invariant. Bytes `>= 0x80` never fold.
- **Per-mode independent toggles** (separate case control for Text vs Where) — one
  shared control by decision Q3.
- **Persisting the toggle across app restarts** — session-scoped by Q3.
- **Whitespace trimming / normalization on predicates** — unchanged; only case
  folding is added to EQ/NE.
- **Any backward-compat / legacy smart-case path** — explicitly not a goal; v1,
  lock-step rebuild, no external consumers.

## 8. Open questions
None. (Q1/Q2/Q3 + the no-backward-compat steer resolved by the author 2026-07-20. This
is a frozen-surface change: no Open Questions may remain before the planner
freezes.)
