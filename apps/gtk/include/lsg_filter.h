/*
 * lsg_filter.h — the GTK frontend's FILTER-TO-MATCHES feature (slice 4:
 * "filter"). Two layers, mirroring the macOS split:
 *
 *   1. A PURE, display-free filter VIEW-MODEL — the C analog of the macOS
 *      `FilterControlling` / `FilterControl`
 * (Sources/Contracts/FilterControl.swift
 *      + Sources/LessSheetKit/FilterLogic.swift) TOGETHER WITH the toggle
 *      app-state macOS keeps in `ViewerModel` (`filterSnapshot` / `isFiltered`
 * / `filterDocumentRows` / `jumpRowCountInfo`, and the apply/clear
 *      transitions). A value state machine (`lsg_filter_*` over
 * `LsgFilterState` by value): it NEVER touches the core — it captures the base
 * document row-count M at apply, folds the async filter-scan poll into the
 *      "Filtered — N of M rows" banner, and derives the two composition facts
 *      the widget needs (the `filtered` flag for jump + the jump's row-count
 *      hint). Lifting the macOS app-layer toggle state into this pure layer is
 *      what makes the hand-rolled GTK banner + toggle verifiable headlessly
 *      under g_test.
 *
 *   2. The FILTER BRIDGE over the real core — the C analog of the macOS
 *      `CoreDocumentSession` filter methods (`setFilter` / `clearFilter` /
 *      `filterStatus`). These `lsg_document_filter_*` functions are the SINGLE
 *      place this frontend calls `ls_filter_set` / `ls_filter_clear` /
 *      `ls_filter_poll`; they extend the document session frozen in
 *      <lsg_document.h> (which stays frozen — the surface grows per slice) and
 *      so take an `LsgDocument *`.
 *
 * A FILTER IS AN IN-PLACE VIEW MODE (api/lesssheet.h FILTERED VIEWS). While
 * one is active the CORE presents ONLY the matching rows, indexed 0..m-1 in
 * file order, and every existing accessor operates in those FILTERED
 * coordinates — so the grid, scroll, window materialize, and gutter are
 * UNCHANGED. In particular the gutter's ORIGINAL row numbers are ALREADY
 * served by the frozen slice-1 `lsg_window_source_row` (`ls_source_row`),
 * which returns each matching row's original (non-contiguous) number under a
 * filter; this slice adds NO new source-row accessor. `lsg_document_row_count`
 * already reports the matching count m while filtered. This module therefore
 * owns ONLY the toggle/banner view-model + the set/clear/poll bridge; it
 * changes NOTHING about how a window is drawn.
 *
 * COMPOSITION WITH THE EARLIER SLICES (verified, NO frozen change to them):
 *   - FIND (slice 2). "Apply as filter" reuses the Find popup verbatim: the
 *     widget composes the CURRENT find draft with the frozen `lsg_find_submit`
 *     and, on `LSG_FIND_RUN`, routes the SAME `LsgSearchRequest` to
 *     `lsg_document_filter_set` instead of `lsg_document_search_start` (there
 * is no separate filter-composition entry point — the grammar/validation are
 *     identical). Applying (or clearing) a filter RESETS the active find
 * app-side with the frozen `lsg_find_invalidated` (the core resets its search
 * too — the coordinate space changed). Find-within-a-filter is then just Find:
 * the core evaluates it over the filtered rows and the frozen find view-model
 * is unchanged. Whether the toggle may turn ON is
 * `lsg_find_submit(...).outcome
 *     != LSG_FIND_IGNORED` (an empty draft is not filterable — the macOS
 *     `canApplyFilter`).
 *   - JUMP (slice 3). While a filter is active the frozen `lsg_jump_submit` /
 *     `lsg_jump_resolve` are driven with their `filtered` flag TRUE (=
 *     `LsgFilterState.active`), which suppresses the out-of-range reject (a
 *     filtered jump clamps to the last match instead — see <lsg_jump.h>), and
 *     with the jump row-count hint from `lsg_filter_jump_rowcount` (the base
 *     document count M, since the jump box takes ORIGINAL row numbers). The
 * jump contract already speaks in original-row terms, so the filter composes
 *     WITHOUT any change to the frozen jump surface.
 *
 * SLICE 4 SCOPE (filter): the filter toggle state (on/off), the filtered
 * row-count / "Filtered — N of M rows" banner view-model, the apply / clear /
 * poll-fold transitions, and the find/jump composition facts — plus the
 * set/clear/poll bridge over the core. OUT (later slices, NOT frozen here):
 * streaming copy, Settings/column-config, dialect override, the deferred
 * "Where" predicate widget. The filter TOGGLE button + the `AdwBanner` DRAWING
 * are display-dependent (the author's GUI pass) — but every signature the
 * implementer wires into main.c is frozen here, and every non-drawing decision
 * (capture, fold, banner state, empty/no-match, the compose facts) is
 * unit-pinned under g_test. The delayed-progress GATING of the banner's scan
 * bar (surface only past the shared ~500 ms threshold) is the widget's,
 * exactly like jump — the banner exposes the RAW scan fraction here.
 *
 * Contract role (frozen; the prototypes/structs ARE the signatures — compiled
 * with -Werror so any drift against a stub/caller fails compilation). Symbols
 * are namespaced `lsg_` / `Lsg` / `LSG_` so they never collide with the core's
 * frozen `ls_` / `LS_` ABI in <lesssheet.h>, which this header builds ON
 * (never copies). The shared search vocabulary (`LsgSearchRequest`,
 * `LsgRowCount`) is REUSED from <lsg_find.h> / <lsg_document.h> — never
 * re-declared.
 *
 * OWNERSHIP: the view-model is a PLAIN VALUE type (`LsgFilterState` /
 * `LsgFilterSnapshot` / `LsgFilterBanner` — no owned heap, no free functions).
 * The `LsgSearchRequest` handed to `lsg_document_filter_set` is a transient
 * borrowed value (produced by `lsg_find_submit`, consumed immediately by the
 * bridge), exactly as for `lsg_document_search_start`.
 *
 * THREADING (mirrors <lesssheet.h> / <lsg_document.h>): the pure
 * `lsg_filter_*` transforms are pure (any thread; they touch no shared state).
 * The bridge `lsg_document_filter_set` / `_clear` / `_poll` sit on the core's
 * POLL/CONTROL lane (internally synchronized; safe from any thread, but not
 * concurrently with `lsg_document_close` — the frontend stops polling before
 * close), exactly like the search bridge; none takes the window-lane lock.
 */
#ifndef LSG_FILTER_H
#define LSG_FILTER_H

#include <glib.h>
#include <lsg_document.h>
#include <lsg_find.h>

G_BEGIN_DECLS

/* ------------------------------------------------------------------------- */
/* The core filter-slot snapshot (mirrors ls_filter_status + macOS */
/* FilterSnapshot / FilterScanPhase) */
/* ------------------------------------------------------------------------- */

/*
 * The filter-scan PHASE the banner renders (the C analog of the macOS
 * `FilterScanPhase`; the ABI's `ls_filter_state` minus IDLE — the bridge
 * reports IDLE as "no snapshot", i.e. no filter active / the identity view;
 * see `lsg_document_filter_poll`). Re-based to 0 exactly like
 * `LsgSearchPhase`; the bridge maps the `LS_FILTER_*` values with an explicit
 * switch (this enum is NOT value-pinned to the ABI — `LsgFilterState` is what
 * carries it).
 */
typedef enum
{
  LSG_FILTER_PHASE_SCANNING = 0, /* the filter-scan is advancing */
  LSG_FILTER_PHASE_DONE = 1, /* every data row scanned: `total` (m) is final */
  LSG_FILTER_PHASE_CANCELLED
  = 2, /* stopped before EOF (a jump/find took the scan
        * slot): counts/progress frozen, but the filter
        * MODE persists (the view is still filtered)    */
} LsgFilterPhase;

/*
 * One poll of the active filter (the C analog of the macOS `FilterSnapshot`,
 * flattening `ls_filter_status`). The bridge reports the ABI's IDLE as "no
 * snapshot" (see `lsg_document_filter_poll`), so `phase` never holds an IDLE.
 * A PLAIN VALUE. progress    — [0.0, 1.0]; filter-scan work fraction;
 * meaningful for SCANNING / CANCELLED; exactly 1.0 at DONE; monotone within
 * one filter. total       — matching rows counted so far (m); exact for the
 * counted region; monotone within one filter. While a filter is active this
 * equals `lsg_document_row_count().count`. total_exact — TRUE iff the
 * filter-scan completed (phase DONE): `total` is the final match count and
 * stops growing.
 */
typedef struct
{
  LsgFilterPhase phase;
  gdouble progress;
  guint64 total;
  gboolean total_exact;
} LsgFilterSnapshot;

/* ------------------------------------------------------------------------- */
/* The pure filter view-model (mirrors FilterControl + the macOS toggle state)
 */
/* ------------------------------------------------------------------------- */

/*
 * The whole filter feature's session state — a PLAIN VALUE (no owned heap).
 * The C analog of the macOS `ViewerModel`'s `filterSnapshot` (flattened) +
 * `filterDocumentRows`, with `active` as the flattened `isFiltered`
 * (`filterSnapshot != nil`).
 *   active         — the toggle: TRUE iff a filter is the active view
 * (filtered MODE). FALSE = the identity view (`document_rows` / `snapshot` are
 * then meaningless — zero). document_rows  — the captured BASE (unfiltered)
 * document row-count M: the identity view's count at the moment filtering
 * began, held FIXED while filtered (the session's own `lsg_document_row_count`
 *                    reports the filtered m from then on). Meaningful iff
 * `active`. It is the banner's M and the jump box's row-count hint. snapshot
 * — the last folded filter poll (the banner's N/progress/phase). Meaningful
 * iff `active`.
 */
typedef struct
{
  gboolean active;
  LsgRowCount document_rows;
  LsgFilterSnapshot snapshot;
} LsgFilterState;

/*
 * The "Filtered — N of M rows" banner view-model (the C analog of the macOS
 * `FilterBanner`). A PLAIN VALUE produced by `lsg_filter_banner`; the widget
 * renders the copy + the (delayed-gated) scan bar from it.
 *   matching             — N: matching rows counted so far (m); converging
 * with `progress` until `matching_is_final`. document_rows        — M: the
 * total UNFILTERED document row count (the captured base count).
 *   document_rows_estimated — render M with a "~" while the base index is
 * still converging (the captured M was not exact). matching_is_final    — N is
 * the final match count (the filter-scan completed). has_progress         —
 * gates `progress`: the scan-% + bar surface (subject to the widget's
 * delayed-progress gate) exactly while TRUE; FALSE once the scan is DONE (or
 * paused-CANCELLED — see `lsg_filter_banner`). progress             — the
 * filter-scan fraction in [0.0, 1.0]; valid only when `has_progress`.
 *   is_empty_result      — DERIVED: the scan finished with zero matches
 *                          (`matching_is_final && matching == 0`) — the grid
 * shows "no matching rows".
 */
typedef struct
{
  guint64 matching;
  guint64 document_rows;
  gboolean document_rows_estimated;
  gboolean matching_is_final;
  gboolean has_progress;
  gdouble progress;
  gboolean is_empty_result;
} LsgFilterBanner;

/* The empty initial state: the IDENTITY view (`active` FALSE; `document_rows`
 * and `snapshot` zero). The widget resets to this on a dialect re-open / new
 * document identity (a filter dies with the old core handle — see
 * `lsg_document_filter_poll`). */
LsgFilterState lsg_filter_initial (void);

/*
 * "Apply as filter" succeeded in the core (`lsg_document_filter_set` returned
 * TRUE): enter (or re-enter) FILTERED MODE. The C analog of the macOS
 * `ViewerModel.applyFindAsFilter` state changes.
 *   - `document_rows` is the IDENTITY-view row-count knowledge the caller read
 *     BEFORE calling `lsg_document_filter_set` (it becomes the banner's /
 * jump's M). On a FIRST apply (`state.active` FALSE) it is captured. On a
 * RE-APPLY
 *     (`state.active` already TRUE — replacing the active filter) it is
 * IGNORED and the ORIGINALLY captured M is retained: while already filtered
 * the base document count is no longer knowable through the session, so the
 * earlier capture is kept (mirrors macOS `isFiltered ? filterDocumentRows :
 * rowCountInfo`).
 *   - `snapshot` is the fresh filter poll the caller read AFTER the successful
 *     set (guaranteed non-idle — SCANNING, or already DONE for a tiny/empty
 *     document), so the banner is correct immediately (no synthetic "0…"
 * flash). Returns the state with `active` TRUE. The caller ALSO resets the
 * active find
 * (`lsg_find_invalidated`) and jump (`lsg_jump_initial`), clears the
 * selection, and lands the grid on filtered row 0.
 */
LsgFilterState lsg_filter_applied (LsgFilterState state,
                                   LsgRowCount document_rows,
                                   LsgFilterSnapshot snapshot);

/*
 * "Clear filter" (the banner's ✕ / the Find popup's Clear) succeeded in the
 * core
 * (`lsg_document_filter_clear`): back to the IDENTITY view — `active` FALSE, M
 * and snapshot reset (the returned state equals `lsg_filter_initial`).
 * Returned UNCHANGED (a no-op) when no filter is active. The C analog of the
 * macOS `ViewerModel.clearFilter` state change. The caller ALSO captured the
 * top visible row's ORIGINAL number BEFORE clearing (set a 1-row window at the
 * top visible row, read `lsg_window_source_row(window, 0)` — the frozen
 * slice-1 calls), resets find/jump/selection, and re-anchors the identity view
 * on that captured source row (not row 0 — ARCH criterion 13).
 */
LsgFilterState lsg_filter_cleared (LsgFilterState state);

/*
 * Fold one filter poll into the state (the C analog of the macOS
 * `applyPoll`'s `filterSnapshot = filter`). Returned UNCHANGED when `state` is
 * NOT `active` (the identity view has no filter to fold), OR when
 * `has_snapshot` is FALSE (the bridge reported IDLE — a nil poll): a filter
 * MODE persists in the core until an explicit clear / re-open, so a stale idle
 * poll never silently drops filtered mode. Otherwise `snapshot` is replaced by
 * the polled one (`active` stays TRUE, `document_rows` unchanged); the core
 * guarantees `total` monotone and `total_exact` latched, so a plain replace is
 * correct.
 */
LsgFilterState lsg_filter_resolved (LsgFilterState state,
                                    gboolean has_snapshot,
                                    LsgFilterSnapshot snapshot);

/*
 * The "Filtered — N of M rows" banner for the current state, or FALSE (no
 * banner — the identity view) when `state` is not `active`, leaving
 * `*out_banner` untouched. The C analog of the macOS
 * `FilterControlling.banner`. When TRUE, writes `*out_banner`, mapping the
 * folded snapshot's phase:
 *   - SCANNING(p)  -> matching = total, has_progress TRUE (progress = p),
 *                     matching_is_final FALSE;
 *   - DONE         -> matching = total, has_progress FALSE, matching_is_final
 *                     TRUE;
 *   - CANCELLED(p) -> matching = total, has_progress TRUE (progress = p),
 *                     matching_is_final FALSE (the scan paused on scan-slot
 *                     contention; the filter MODE persists, so the banner
 * keeps showing its frozen progress, not final). In every case document_rows =
 * state.document_rows.count, document_rows_estimated =
 * !state.document_rows.exact, and is_empty_result = (matching_is_final &&
 * matching == 0).
 */
gboolean lsg_filter_banner (LsgFilterState state, LsgFilterBanner *out_banner);

/*
 * The row-count knowledge the JUMP submit hints with (`lsg_jump_submit`'s
 * `rowcount`) — the C analog of the macOS `jumpRowCountInfo`. While filtered
 * the jump box interprets ORIGINAL (unfiltered) row numbers, so it must hint
 * with the captured base document count M (`state.document_rows`), NOT the
 * filtered m; the identity `identity_rowcount` otherwise. The caller passes
 * `state.active` as the `filtered` flag to `lsg_jump_submit` /
 * `lsg_jump_resolve` alongside this.
 */
LsgRowCount lsg_filter_jump_rowcount (LsgFilterState state,
                                      LsgRowCount identity_rowcount);

/* ------------------------------------------------------------------------- */
/* The filter bridge over the core — the single place ls_filter_* are called;
 */
/* extends the <lsg_document.h> session. */
/* ------------------------------------------------------------------------- */

/*
 * Set (or replace) the document's active FILTER from `request` (mirrors
 * `ls_filter_set`), entering FILTERED MODE: every row accessor, jump, and
 * search then operates in FILTERED coordinates (row i = the i-th matching data
 * row in file order). `request` is the SAME `LsgSearchRequest` value Find
 * composes (the grammar/validation are identical); the bridge marshals it into
 * an `ls_search_request` exactly as `lsg_document_search_start` does. Returns
 * FALSE iff the core REJECTS the request — an empty TEXT query; a non-NULL
 * scope with a 0 length or an out-of-range index; a PREDICATE column out of
 * range; an ORDERING operator with a non-numeric value — in which case NOTHING
 * changes (the current view, any active search, and a running jump are all
 * untouched; `lsg_find_submit` validates first, the core enforces). On success
 * REPLACES any previous filter entirely (counts reset; the filter-scan
 * restarts from row 0), takes the core's single scan slot, and RESETS any
 * active search to idle. Never blocks (the filter-scan is asynchronous — poll
 * with `lsg_document_filter_poll`). Poll/control lane.
 */
gboolean lsg_document_filter_set (LsgDocument *doc, LsgSearchRequest request);

/*
 * Clear the active filter, restoring the IDENTITY view (mirrors
 * `ls_filter_clear`; no-op when no filter is active). After this every
 * accessor addresses physical data rows again and `lsg_document_filter_poll`
 * reports IDLE (returns FALSE). Resets any active search to idle. Re-anchoring
 * the viewport near the row you were viewing is the caller's affair (capture
 * `lsg_window_source_row` of the top visible row BEFORE clearing — see
 * `lsg_filter_cleared`). Never blocks. Poll/control lane.
 */
void lsg_document_filter_clear (LsgDocument *doc);

/*
 * Current filter snapshot (mirrors `ls_filter_poll`). Returns FALSE and leaves
 * `*out` UNTOUCHED when the filter state is IDLE — no filter active (the
 * identity view), which a fresh session and a dialect re-open (whose new
 * handle carries no filter) both report: this is the "no snapshot" that
 * `lsg_filter_resolved` folds as a nil poll and that `lsg_filter_initial`
 * represents. Otherwise writes `*out` (phase SCANNING / DONE / CANCELLED) and
 * returns TRUE. Poll/control lane; never blocks; never fails.
 */
gboolean lsg_document_filter_poll (const LsgDocument *doc,
                                   LsgFilterSnapshot *out);

G_END_DECLS

#endif /* LSG_FILTER_H */
