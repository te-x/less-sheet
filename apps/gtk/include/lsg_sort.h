/*
 * lsg_sort.h — the GTK frontend's SORT-BY-COLUMN feature (ARCH-sort-by-column,
 * app criterion AC-s15). Two layers, mirroring the macOS split exactly (the
 * macOS frontend is the authoritative design template; only platform deltas
 * are re-decided here):
 *
 *   1. A PURE, display-free sort VIEW-MODEL — the C analog of the macOS
 *      `SortCycling` / `SortCycle` (Sources/Contracts/SortControl.swift +
 *      Sources/LessSheetKit/SortCycleLogic.swift): the three-state CYCLE
 *      (ascending -> descending -> off) and the header INDICATOR, over plain
 *      value types. It never touches the core.
 *
 *   2. The SORT BRIDGE over the real core — the C analog of the macOS
 *      `CoreDocumentSession` sort methods. These `lsg_document_sort_*`
 *      functions are the SINGLE place this frontend calls `ls_sort_set` /
 *      `ls_sort_clear` / `ls_sort_poll`; they extend the document session
 *      frozen in <lsg_document.h> (which stays frozen — the surface grows per
 *      slice) and so take an `LsgDocument *`.
 *
 * A SORT IS A THIRD VIEW KIND (api/lesssheet.h SORTED VIEWS). While one is
 * ACTIVE the CORE presents the (filtered) rows in sort order and every
 * existing accessor operates in those SORTED coordinates — so the grid,
 * scroll, window materialize, gutter, find, jump, and copy are UNCHANGED here.
 * In particular the gutter's ORIGINAL row numbers are ALREADY served by the
 * frozen slice-1 `lsg_window_source_row` (`ls_source_row`), which returns each
 * sorted row's original number; this slice adds NO new source-row accessor and
 * NO new drawing path beyond the header indicator.
 *
 * LATENCY BEATS THROUGHPUT (ARCH-sort-by-column Amendment 1), and this is the
 * one thing this header exists to make impossible to forget: the grid does NOT
 * wait for the pass. The view speaks sorted coordinates from the instant
 * lsg_document_sort_set returns and serves the CONVERGING PREFIX — the exact
 * sorted top of the region scanned so far, up to 4096 rows — which REFINES
 * LIVE as the scan advances. So the widget must (1) repaint the top of the
 * grid as the poll changes rather than painting once and waiting, (2) keep the
 * progress
 * + cancel affordance up for the WHOLE build rather than only past the ~500 ms
 * delayed-progress threshold, and (3) render the ordinary not-yet-servable
 * presentation for rows past the prefix. The indicator stays PENDING (see
 * LsgSortIndicator.pending) for the whole build: the rows ARE sorted, but the
 * top is still refining, so the header must not claim a settled order. On
 * FAILED, and on cancel, the view is back in its pre-sort file order — there
 * is nothing partial left on screen to clean up.
 *
 * COMPOSITION WITH THE EARLIER SLICES (verified, NO frozen change to them):
 *   - FILTER (slice 4). A sort composes OVER the filter: the sorted row set is
 *     exactly the filtered row set, and setting or clearing a filter makes the
 *     core RE-RUN the key pass automatically with the sort request intact. The
 *     frozen filter view-model is unchanged; the widget simply keeps polling
 *     both.
 *   - FIND (slice 2) and JUMP (slice 3). Both keep their frozen surfaces.
 * Every sort change (set, direction flip, clear, and each automatic rebuild)
 *     RESETS the core's search and returns the jump slot to idle, so the
 * widget invalidates the find view-model with the frozen
 * `lsg_find_invalidated` exactly as it already does on a filter change. Jump
 * still takes ORIGINAL row numbers, so `lsg_jump_submit` / `lsg_jump_resolve`
 * are untouched.
 *   - A11Y (a11y slice). Ctrl+Shift+S is registered through the ONE
 *     `lsg_a11y_shortcuts` table (new LSG_A11Y_GROUP_SORTING /
 *     LSG_A11Y_CMD_SORT — see <lsg_a11y.h>), so the accelerator the shortcuts
 *     dialog shows is the one that fires. Nothing here re-declares it.
 *
 * SLICE SCOPE: the cycle, the indicator, and the set/clear/poll bridge. OUT
 * (deliberately, and stated rather than implied): the header-cell DRAWING of
 * the indicator, the progress bar + Cancel chrome (the frozen delayed-progress
 * threshold gate already owns "show after ~500 ms"), and the error banner —
 * all display-dependent, and all verified by the author's GUI pass. Every
 * signature the implementer wires into main.c is frozen here, and every
 * non-drawing decision is unit-pinned under g_test.
 *
 * Contract role (frozen; the prototypes/structs ARE the signatures — compiled
 * with -Werror so any drift against a stub/caller fails compilation). Symbols
 * are namespaced `lsg_` / `Lsg` / `LSG_` so they never collide with the core's
 * frozen `ls_` / `LS_` ABI in <lesssheet.h>, which this header builds ON
 * (never copies).
 *
 * OWNERSHIP: every type here is a PLAIN VALUE (no owned heap, no free
 * functions), like the filter view-model.
 *
 * THREADING (mirrors <lesssheet.h> / <lsg_document.h>): the pure functions are
 * side-effect-free and callable from anywhere; the bridge functions are on the
 * core's poll/control lane and are called from the GTK main thread like every
 * other `lsg_document_*` call.
 */

#ifndef LSG_SORT_H
#define LSG_SORT_H

#include <glib.h>

#include "lsg_document.h"

G_BEGIN_DECLS

/* ========================================================================= */
/* 1. The pure view-model */
/* ========================================================================= */

/* Sort direction (mirrors ls_sort_direction). DESCENDING is the ascending
 * permutation read backwards, so equal values appear in REVERSE source order —
 * stated because it is user-visible, not an implementation note. */
typedef enum
{
  LSG_SORT_ASCENDING = 0,
  LSG_SORT_DESCENDING = 1,
} LsgSortDirection;

/* The sort's phase (mirrors ls_sort_state).
 *
 * LSG_SORT_PHASE_NONE is the "no sort" case the bridge reports for
 * LS_SORT_IDLE; the rows are in file order.
 *
 * LSG_SORT_PHASE_BUILDING already SERVES: the view is in sorted coordinates
 * and its top rows are the exact sorted top of what has been scanned, refining
 * live.
 *
 * LSG_SORT_PHASE_PARKED is the core's LS_SORT_PARKED: the key pass yielded the
 * single scan slot to a jump or a find, so its prefix is FROZEN at the content
 * it had reached — still served, still exact for what was scanned, simply no
 * longer refining. It is NOT a user cancellation. On the local documents this
 * frontend opens with LS_INDEX_AUTO it resumes and converges on its own, so
 * the UI treats it exactly like BUILDING.
 *
 * LSG_SORT_PHASE_FAILED means the view is back in its pre-sort file order and
 * fully servable. */
typedef enum
{
  LSG_SORT_PHASE_NONE = 0,
  LSG_SORT_PHASE_BUILDING = 1,
  LSG_SORT_PHASE_ACTIVE = 2,
  LSG_SORT_PHASE_PARKED = 3,
  LSG_SORT_PHASE_FAILED = 4,
} LsgSortPhase;

/* Why a key pass failed (mirrors ls_sort_error). The two causes stay distinct
 * because the app says different things about a full disk and an
 * out-of-memory. LSG_SORT_ERROR_NONE outside LSG_SORT_PHASE_FAILED. */
typedef enum
{
  LSG_SORT_ERROR_NONE = 0,
  LSG_SORT_ERROR_STORAGE = 1,
  LSG_SORT_ERROR_MEMORY = 2,
} LsgSortError;

/* One poll of the document's sort (mirrors ls_sort_status).
 *
 *   phase     — see LsgSortPhase; NONE means no sort is active and every other
 *               field is zeroed.
 *   error     — LSG_SORT_ERROR_NONE unless phase == LSG_SORT_PHASE_FAILED.
 *   column    — the REQUESTED sort column. Valid in EVERY phase but NONE,
 *               including BUILDING / PARKED / FAILED, so the header indicator
 *               and the retry target stay on screen while a pass runs or after
 *               it fails.
 *   direction — the REQUESTED direction; same validity as `column`.
 *   progress  — key-pass fraction in [0, 1]; monotone within one build;
 *               exactly 1.0 at ACTIVE; frozen when PARKED or FAILED; 0 when
 *               NONE. This is the RAW fraction: the ~500 ms delayed-progress
 *               GATING of the scan bar is the widget's, exactly as for jump
 * and filter. */
typedef struct
{
  LsgSortPhase phase;
  LsgSortError error;
  guint column;
  LsgSortDirection direction;
  double progress;
} LsgSortSnapshot;

/* What the app should ask the core to do next. `kind` selects the arm; for
 * LSG_SORT_INTENT_CLEAR the other two fields are zero. */
typedef enum
{
  LSG_SORT_INTENT_SET = 0,
  LSG_SORT_INTENT_CLEAR = 1,
} LsgSortIntentKind;

typedef struct
{
  LsgSortIntentKind kind;
  guint column;
  LsgSortDirection direction;
} LsgSortIntent;

/*
 * THE CYCLE — the single decision behind a header click, Ctrl+Shift+S on the
 * keyboard cursor's column, and the progress affordance's Cancel. Routing all
 * three through THIS function is what keeps them from drifting apart.
 *
 * Given the current snapshot and the column the user acted on:
 *   - no sort (phase NONE), or a DIFFERENT column than the current one
 *                                      -> SET(column, ASCENDING) (start
 * fresh);
 *   - same column, ACTIVE + ASCENDING  -> SET(column, DESCENDING);
 *   - same column, ACTIVE + DESCENDING -> CLEAR (the third state, "off");
 *   - same column, BUILDING or PARKED  -> CLEAR. Acting on a pass that has not
 *     landed means STOP — which is also exactly what Cancel means, so the two
 *     affordances cannot drift apart (ls_sort_clear is both verbs);
 *   - same column, FAILED              -> SET(column, the SAME direction) — a
 *     RETRY, not an advance. Silently moving to a direction the user never saw
 *     applied would be the wrong answer to "that didn't work", and the core
 *     explicitly re-runs the pass for an identical request on a failed sort.
 *
 * Never inspects the failure reason, the progress value, or the column count:
 * clamping `column` to the document is the caller's job. `snapshot` is passed
 * BY VALUE; a NONE-phase value means "no sort".
 */
LsgSortIntent lsg_sort_next (LsgSortSnapshot snapshot, guint column);

/*
 * The header-cell indicator state for `column`.
 *
 *   direction — meaningful only when `sorted` is TRUE.
 *   sorted    — this column is the sort column (draw the chevron); FALSE for
 *               every other column, and then the other fields are zero.
 *   pending   — the pass for THIS column is still outstanding (BUILDING or
 *               PARKED): the indicator SHOWS and the grid IS already
 *               re-ordered (it shows the exact sorted top of what has been
 *               scanned), but that top is still REFINING and rows past the
 *               prefix are not yet servable, so the header renders it in its
 *               pending styling instead of claiming a settled order.
 *   failed    — the pass for THIS column FAILED: error styling, and a click
 *               retries (see lsg_sort_next). The view is back in its pre-sort
 *               file order.
 */
typedef struct
{
  LsgSortDirection direction;
  gboolean sorted;
  gboolean pending;
  gboolean failed;
} LsgSortIndicator;

LsgSortIndicator lsg_sort_indicator (LsgSortSnapshot snapshot, guint column);

/*
 * The accessible/announced description of the current sort, for the header
 * cell's AT-SPI description and the status announcement — e.g.
 *   "sorted by Price, ascending", "sorting by Price, ascending — 42%",
 *   "sorting by Price failed", "not sorted".
 * `column_label` may be NULL or "" (then the generic "column N" form is used,
 * N being the 1-BASED column number the user sees). Returns a newly allocated
 * NUL-terminated UTF-8 string the caller frees with g_free(); never NULL.
 */
char *lsg_sort_describe (LsgSortSnapshot snapshot, const char *column_label);

/* ========================================================================= */
/* 2. The sort bridge over the core */
/* ========================================================================= */

/*
 * Set (or replace) the document's sort (ls_sort_set). Returns FALSE iff the
 * core REJECTS the request (`column` >= the document's column count); NOTHING
 * changes then. TRUE means the request was accepted — a no-op re-request, an
 * instant direction flip, or a started key pass; poll to tell them apart.
 * Never blocks.
 *
 * ON A NETWORK DOCUMENT this call is the user's explicit demand to fetch the
 * WHOLE resource, with progress and a working cancel. The widget must have
 * said so before issuing it.
 */
gboolean lsg_document_sort_set (LsgDocument *doc, guint column,
                                LsgSortDirection direction);

/*
 * Clear the sort (ls_sort_clear) — also the CANCEL verb for a running key
 * pass. No-op when no sort is active. Either way the view RETURNS TO ITS
 * PRE-SORT file order (the filtered row set if a filter is active) and is
 * fully servable again — a cancelled build's converging prefix is gone, not
 * frozen on screen. Any active find is reset and the jump slot returns to
 * idle, so the widget invalidates its find view-model exactly as it does on a
 * filter change.
 */
void lsg_document_sort_clear (LsgDocument *doc);

/*
 * Poll the sort (ls_sort_poll). Writes the snapshot to `out_snapshot` (must
 * not be NULL) and returns TRUE iff a sort is active in ANY phase — i.e. FALSE
 * exactly when the phase is LSG_SORT_PHASE_NONE, in which case the snapshot is
 * fully zeroed. Zero allocation; never fails; never blocks.
 */
gboolean lsg_document_sort_poll (const LsgDocument *doc,
                                 LsgSortSnapshot *out_snapshot);

G_END_DECLS

#endif /* LSG_SORT_H */
