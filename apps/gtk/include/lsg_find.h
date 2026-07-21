/*
 * lsg_find.h — the GTK frontend's FIND feature (slice 2: "find"). Two layers,
 * mirroring the macOS split:
 *
 *   1. A PURE, display-free find VIEW-MODEL — the C analog of the macOS
 *      `FindControlling` / `FindControl` (Sources/Contracts/FindControl.swift
 * + Sources/LessSheetKit/FindLogic.swift). A value state machine (`lsg_find_*`
 *      over `LsgFindSession` by value): it NEVER touches the core — it
 * composes a request from the draft, folds search polls into the display, and
 * decides wrap / no-matches / stopped notices and next/prev navigation
 * anchors.
 *
 *   2. The SEARCH BRIDGE over the real core — the C analog of the macOS
 *      `CoreDocumentSession` search methods (`startSearch` / `navigateSearch`
 * / `searchStatus` / `cancelSearch` / `windowMatchFlags`). These
 * `lsg_document_*` functions are the SINGLE place this frontend calls
 * `ls_search_*` / `ls_window_match_flags`; they extend the document session
 * frozen in <lsg_document.h> (which stays frozen — the surface grows per
 * slice) and so take an `LsgDocument *`.
 *
 * The frontend owns NO matcher: every per-cell find/predicate verdict —
 * substring matching (ASCII case folding per the request's "Match case" flag),
 * exact-decimal ordering — comes from the core (`ls_search_*` counts +
 * navigation, `ls_window_match_flags` for highlights). This module only
 * composes requests, folds the async count/nav snapshots into a display, and
 * copies the borrowed highlight mask out.
 *
 * SLICE 2 SCOPE (find): text + predicate search, the "Match case" flag, the
 * live match-count state machine, find-next / find-prev navigation, wrap
 * notices, and the visible-window match-flag highlight mask. OUT (later
 * slices, NOT frozen here): jump-to-row, filter-to-matches (`ls_filter_*`),
 * streaming copy, Settings/column-config, dialect override. The find POPOVER
 * widget and the grid's highlight DRAWING are display-dependent (the author's GUI
 * pass) — but every signature the implementer wires into main.c is frozen
 * here, and every non-drawing decision (compose, count, nav, wrap, the
 * highlight MASK values) is unit-pinned under `g_test`.
 *
 * Contract role (frozen; the prototypes/structs ARE the signatures — compiled
 * with -Werror so any drift against a stub/caller fails compilation). Symbols
 * are namespaced `lsg_` / `Lsg` / `LSG_` so they never collide with the core's
 * frozen `ls_` / `LS_` ABI in <lesssheet.h>, which this header builds ON
 * (never copies).
 *
 * OWNERSHIP: the view-model is a PLAIN VALUE type. `LsgFindDraft` holds
 * BORROWED, caller-owned `const char *` text/value (the popover's entry
 * buffers, or string literals in tests) — the pure transforms only READ them
 * and copy pointers shallowly, so `LsgFindSession` never owns heap and needs
 * no free function. `LsgSearchRequest` is likewise a transient borrowed value
 * (produced by `lsg_find_submit`, consumed immediately by
 * `lsg_document_search_start`). The one OWNED result is `LsgMatchFlags.flags`
 * (free with g_free).
 *
 * THREADING (mirrors <lesssheet.h> / <lsg_document.h>): the pure `lsg_find_*`
 * transforms are pure (any thread; they touch no shared state). The bridge
 * `lsg_document_search_start` / `_nav` / `_cancel` / `_poll` sit on the core's
 * POLL/CONTROL lane (internally synchronized; safe from any thread, but not
 * concurrently with `lsg_document_close` — the frontend stops polling before
 * close). `lsg_document_window_match_flags` is WINDOW LANE — caller-serialized
 * with `lsg_document_set_window` and the other window-lane calls, exactly like
 * a cell read.
 */
#ifndef LSG_FIND_H
#define LSG_FIND_H

#include <glib.h>
#include <lsg_document.h>

G_BEGIN_DECLS

/* ------------------------------------------------------------------------- */
/* Shared search vocabulary (mirrors the ABI's ls_search_* + macOS Contracts)
 */
/* ------------------------------------------------------------------------- */

/* The two find modes (the popover's segmented switch; the UI renders
 * LSG_FIND_PREDICATE as "Where"). Values pinned to the ABI's ls_search_kind.
 */
typedef enum
{
  LSG_FIND_TEXT = 0, /* substring text match over a scope (ASCII case folding
                        per the "Match case" flag) */
  LSG_FIND_PREDICATE
  = 1, /* single-column typed predicate (operator + value)   */
} LsgFindMode;

/*
 * Predicate operators. Values are PINNED to the ABI's `ls_search_op`
 * (LS_SEARCH_OP_*), so the bridge maps them 1:1. EQ/NE compare the cell bytes
 * to the value with ASCII case folding per the request's `case_sensitive`
 * flag (case-INSENSITIVE by default; byte-exact when "Match case" is on; NO
 * trimming in either mode). LT/GT/LE/GE compare NUMERICALLY under the pinned
 * numeric grammar and IGNORE case (a non-numeric cell never matches an
 * ordering op; a non-numeric value is rejected before any core call).
 */
typedef enum
{
  LSG_SEARCH_OP_EQ = 0, /* =  */
  LSG_SEARCH_OP_NE = 1, /* != */
  LSG_SEARCH_OP_LT = 2, /* <  */
  LSG_SEARCH_OP_GT = 3, /* >  */
  LSG_SEARCH_OP_LE = 4, /* <= */
  LSG_SEARCH_OP_GE = 5, /* >= */
} LsgSearchOp;

/* Whether `op` is an ORDERING operator (< > <= >=), whose value MUST parse
 * under the numeric grammar. EQ/NE accept any value (the empty one matches
 * empty cells). */
gboolean lsg_search_op_is_ordering (LsgSearchOp op);

/* Navigation direction. Values pinned to the ABI's `ls_search_dir`. See
 * `LsgSearchNav` for the pinned anchor semantics. */
typedef enum
{
  LSG_SEARCH_FORWARD = 0,
  LSG_SEARCH_BACKWARD = 1,
} LsgSearchDir;

/*
 * The match-scan PHASE the popover renders (the C analog of the macOS
 * `SearchScanPhase`; the ABI's `ls_search_state` minus IDLE — the bridge
 * reports IDLE as "no snapshot", see `lsg_document_search_poll`).
 */
typedef enum
{
  LSG_SEARCH_PHASE_SCANNING = 0, /* the match-scan (and/or a nav) is running */
  LSG_SEARCH_PHASE_DONE = 1, /* every data row scanned: `total` is final    */
  LSG_SEARCH_PHASE_CANCELLED
  = 2, /* stopped before EOF: counts/found kept frozen */
} LsgSearchPhase;

/* The navigation-slot state. Values pinned to the ABI's `ls_search_nav_state`.
 */
typedef enum
{
  LSG_SEARCH_NAV_NONE = 0, /* no navigation since this search started      */
  LSG_SEARCH_NAV_SEARCHING
  = 1,                      /* a navigation is pending (served by the scan) */
  LSG_SEARCH_NAV_FOUND = 2, /* found a match: `found` / `position` valid    */
  LSG_SEARCH_NAV_EXHAUSTED
  = 3, /* no match in this direction (the frontend wraps) */
} LsgSearchNavState;

/* One matched cell landing (mirrors the ABI's found_row/found_col): the
 * matching data row and the match column — the LOWEST in-scope matching column
 * for TEXT, the predicate column for PREDICATE. */
typedef struct
{
  guint64 row;
  guint32 column;
} LsgSearchMatch;

/*
 * A navigation command (mirrors `ls_search_nav`'s PINNED anchor semantics):
 *   FORWARD  — the FIRST matching row with row >= anchor;
 *   BACKWARD — the LAST matching row with row < anchor (STRICTLY).
 * So every navigation is a plain anchor: first-in-file = {0, FORWARD};
 * next-after-R = {R + 1, FORWARD}; previous-before-R = {R, BACKWARD};
 * last-in-file = {G_MAXUINT64, BACKWARD} (no data row can be G_MAXUINT64).
 * "Previous" from the first match is therefore a core-uniform EXHAUSTED, which
 * the view-model turns into a wrap.
 */
typedef struct
{
  guint64 anchor;
  LsgSearchDir direction;
} LsgSearchNav;

/* First match in the file: {0, LSG_SEARCH_FORWARD}. */
LsgSearchNav lsg_search_nav_from_top (void);
/* Last match in the file: {G_MAXUINT64, LSG_SEARCH_BACKWARD}. */
LsgSearchNav lsg_search_nav_from_end (void);

/*
 * A composed search request — what the bridge hands the core (mirrors
 * `ls_search_request`; the C analog of the macOS `SearchRequest`). BORROWED
 * value: `value` points at NUL-terminated UTF-8 owned by the caller (the
 * draft), and `scope` (when non-NULL) at a caller-owned array of `scope_len`
 * column indices. Valid ONLY while those buffers live — produced by
 * `lsg_find_submit` and consumed immediately by `lsg_document_search_start`
 * (never stored with live pointers in session state). `kind` selects which
 * fields are meaningful.
 */
typedef struct
{
  LsgFindMode kind;
  /* The query bytes: for TEXT the substring query (non-empty); for PREDICATE
   * the comparison value (may be ""). NUL-terminated UTF-8. Mirrors the ABI's
   * shared value_ptr/value_len. */
  const char *value;
  /* TEXT only: the in-scope 0-based columns, or NULL for ALL columns. The core
   * treats this as a SET (order and duplicates are immaterial). Fixed for the
   * search's lifetime. PREDICATE: unused (NULL / 0). */
  const guint32 *scope;
  guint scope_len;
  /* PREDICATE only: the target column and operator. TEXT: unused. */
  guint32 column;
  LsgSearchOp op;
  /* The "Match case" flag, copied verbatim from the draft (see LsgFindDraft).
   * FALSE (default) = ASCII case-INSENSITIVE (bytes 0x41..0x5A fold to their
   * lowercase forms; every byte >= 0x80 always compares exactly); TRUE =
   * byte-exact. Governs TEXT substring matching and predicate EQ/NE ONLY;
   * ordering ops (LT/GT/LE/GE) are numeric and ignore it. Marshaled 1:1 to
   * `ls_search_request.case_sensitive` at the single ABI choke point, so find,
   * filter, navigation, and the highlight mask all inherit it. */
  gboolean case_sensitive;
} LsgSearchRequest;

/*
 * One poll of the active search (the C analog of the macOS `SearchSnapshot`,
 * flattening `ls_search_status`). The bridge reports the ABI's IDLE as "no
 * snapshot" (see `lsg_document_search_poll`), so `phase` never holds an IDLE.
 *   progress    — [0.0, 1.0]; meaningful for SCANNING / CANCELLED; exactly 1.0
 *                 at DONE; monotone within one search.
 *   found       — the landing; valid only when `nav == LSG_SEARCH_NAV_FOUND`.
 *   position    — 1-based rank (n) of `found` among ALL matching rows in file
 *                 order; valid only when FOUND, and then exact (total >=
 * position). total       — matching rows counted so far (m); exact for the
 * counted region; monotone within one search. total_exact — TRUE iff the
 * match-scan completed (phase DONE): `total` is the final count and stops
 * growing.
 */
typedef struct
{
  LsgSearchPhase phase;
  LsgSearchNavState nav;
  gdouble progress;
  LsgSearchMatch found;
  guint64 position;
  guint64 total;
  gboolean total_exact;
} LsgSearchSnapshot;

/* ------------------------------------------------------------------------- */
/* The pure find view-model (mirrors FindControl; a PLAIN VALUE state machine)
 */
/* ------------------------------------------------------------------------- */

/* One-shot popover notices (sentence-case UI copy: "Wrapped to start",
 * "Wrapped to end", "No matches", "Stopped"). NONE = no notice. */
typedef enum
{
  LSG_FIND_NOTICE_NONE = 0,
  LSG_FIND_NOTICE_WRAPPED_TO_START = 1,
  LSG_FIND_NOTICE_WRAPPED_TO_END = 2,
  LSG_FIND_NOTICE_NO_MATCHES = 3,
  LSG_FIND_NOTICE_STOPPED = 4,
} LsgFindNotice;

/*
 * What the user is editing in the popover (mirrors `FindDraft`). SESSION
 * state: it survives Esc (popover close) and dialect re-opens (query-retained
 * semantics — re-running is one Enter), realized by the frontend keeping the
 * entry text; it NEVER starts a search by itself (only `lsg_find_submit` —
 * Enter — does).
 *
 * `text` and `value` are BORROWED, caller-owned, NUL-terminated UTF-8 (never
 * NULL; an empty field is ""): the popover's `GtkEntry` buffers (or string
 * literals in tests). The pure transforms only READ them.
 */
typedef struct
{
  LsgFindMode mode;
  const char *text;  /* TEXT query field  */
  guint32 column;    /* WHERE column picker (0-based) */
  LsgSearchOp op;    /* WHERE operator    */
  const char *value; /* WHERE value field */
  /* The "Match case" checkbox. FALSE (default) = ASCII case-INSENSITIVE;
   * TRUE = byte-exact. ONE session bool SHARED by both TEXT and WHERE modes
   * (there is no per-mode case control), and it is NOT derived from the query
   * — smart case is retired; the checkbox is the ONLY thing that decides
   * folding. Session-scoped: retained across popover close / dialect re-open
   * like the rest of the draft (`lsg_find_closed` / `lsg_find_invalidated`
   * keep it), and reset to FALSE by a fresh session (`lsg_find_initial`); it
   * is not persisted across app restarts. `lsg_find_submit` copies it verbatim
   * into the composed request for both modes. */
  gboolean case_sensitive;
} LsgFindDraft;

/*
 * The active search as the popover + grid render it (mirrors `FindDisplay`).
 * A PLAIN VALUE struct; Swift's optionals are flattened to `has_*` gates.
 */
typedef struct
{
  /* Whether a search is active (mirrors the macOS `request != nil`): the
   * popover shows counts and the grid paints highlights (from the core's match
   * flags) exactly while TRUE. The pure logic only needs this presence bit —
   * the request CONTENTS live transiently in `LsgSearchRequest`; the CORE owns
   * the active request and the per-cell verdicts. FALSE = no active search. */
  gboolean active;
  /* The current landing. `has_current` gates `current` / `position`. */
  gboolean has_current;
  LsgSearchMatch current;
  guint64 position; /* 1-based rank of `current` among all matches */
  /* Matches known so far (m): "match n of m…" while growing, "match n of m"
   * once `total_final`. */
  guint64 total;
  gboolean total_final;
  /* Scan progress. `has_progress` gates `progress` in [0.0, 1.0] — the % label
   * and the cancel affordance show exactly while TRUE. */
  gboolean has_progress;
  gdouble progress;
  LsgFindNotice notice;
} LsgFindDisplay;

/* The find feature's whole session state: the editable draft + the active
 * search's display. A PLAIN VALUE type (no owned heap). */
typedef struct
{
  LsgFindDraft draft;
  LsgFindDisplay display;
} LsgFindSession;

/* The outcome kind of submitting the draft (Enter). */
typedef enum
{
  LSG_FIND_RUN = 0, /* start `request` in the core, then navigate from_top */
  LSG_FIND_REJECTED = 1, /* invalid input: red blink + shake; NO core call */
  LSG_FIND_IGNORED = 2,  /* empty text query: no search, no error  */
} LsgFindOutcome;

/* The result of `lsg_find_submit`. `request` is meaningful only when
 * `outcome == LSG_FIND_RUN` (and borrows the submitted draft / visible-columns
 * buffers — hand it straight to `lsg_document_search_start`). */
typedef struct
{
  LsgFindOutcome outcome;
  LsgSearchRequest request;
} LsgFindSubmit;

/*
 * The pinned NUMERIC GRAMMAR (verbatim the ABI HEADER RULE / macOS
 * `NumericGrammar`): strip ASCII whitespace (0x09..0x0D, 0x20) from both ends;
 * the remainder must be non-empty and fully match
 *   sign? ( digits ('.' digits?)? | '.' digits ) (('e'|'E') sign? digits)?
 * with ASCII digits and '.' only. The WHERE popover's ordering-value
 * validation uses it (the core enforces identically at `ls_search_start`).
 * `text` is NUL-terminated UTF-8 (NULL treated as empty → FALSE).
 */
gboolean lsg_numeric_is_numeric (const char *text);

/* The empty initial session: empty draft (TEXT mode, "" query/value, column 0,
 * op EQ, "Match case" OFF) and empty display (inactive; no current, total 0,
 * not final, no progress, no notice). */
LsgFindSession lsg_find_initial (void);

/*
 * Enter: validate + compose the draft into a request.
 *   TEXT — an empty query → LSG_FIND_IGNORED (no search, no error); otherwise
 *     LSG_FIND_RUN with `request.value` = the query and `request.scope` = NULL
 *     when EVERY column is visible (`n_visible == column_count`), else the
 *     `visible_columns` set (borrowed; the core treats it as a set). The scope
 * is thereby fixed at submit — hidden-column changes re-scope from the next
 * run. PREDICATE — a `draft.column >= column_count` → LSG_FIND_REJECTED; an
 * ORDERING operator whose `draft.value` fails the numeric grammar (the empty
 * value included) → LSG_FIND_REJECTED (blink + shake, before any core call);
 *     otherwise LSG_FIND_RUN with `request` = {column, op, value} (EQ/NE
 * accept ANY value, the empty one included — it matches empty cells). A hidden
 * column is a legal predicate target. `visible_columns` lists the `n_visible`
 * visible column indices; it is ignored when `n_visible == column_count` (all
 * columns).
 *
 * In BOTH modes the composed `request.case_sensitive` is copied verbatim from
 * `session.draft.case_sensitive` (the "Match case" checkbox) — the flag is
 * never derived from the query. The returned `request` BORROWS `session.draft`
 * and `visible_columns` — consume it before they change.
 */
LsgFindSubmit lsg_find_submit (LsgFindSession session,
                               const guint32 *visible_columns, guint n_visible,
                               guint32 column_count);

/*
 * A submitted request has been started in the core: the draft is unchanged;
 * the display becomes active with a fresh count state (no current, total 0,
 * not final, progress 0, no notice). The caller also issues
 * `lsg_document_search_nav(doc, lsg_search_nav_from_top())`.
 */
LsgFindSession lsg_find_began (LsgFindSession session);

/*
 * Fold one search poll into the display. When `has_snapshot` is FALSE (the
 * bridge reported IDLE — a nil poll) OR the session has no active search, the
 * session is returned UNCHANGED (a stale/idle poll never resurrects or resets
 * a display). Otherwise:
 *   - total' = MAX(displayed, snapshot.total); `total_final` latches once true
 *     (the growing → final count machine; the display never regresses);
 *   - progress' = MAX-fold while `phase == SCANNING`, cleared (no progress) on
 *     DONE / CANCELLED;
 *   - a `nav == FOUND` sets `current` + `position` (kept on non-found polls —
 * the old landing holds until the next lands);
 *   - the NOTICE derives purely from THIS snapshot: `nav == EXHAUSTED` with
 * the snapshot's `total == 0` AND `total_exact` → NO_MATCHES (current/position
 *     cleared); any OTHER `EXHAUSTED` → WRAPPED_TO_START when `nav_direction`
 * is FORWARD, WRAPPED_TO_END when BACKWARD (current/position kept — the wrap
 * has not landed yet); else `phase == CANCELLED` → STOPPED; else NONE (so a
 * wrap notice self-clears when the wrap navigation lands as a FOUND poll).
 * `nav_direction` is the direction of the outstanding navigation (the initial
 * from_top is FORWARD).
 */
LsgFindSession lsg_find_resolved (LsgFindSession session,
                                  gboolean has_snapshot,
                                  LsgSearchSnapshot snapshot,
                                  LsgSearchDir nav_direction);

/*
 * Find-next / find-prev (the keyboard step). Returns FALSE (leaving `*out_nav`
 * untouched) when no search is active. Otherwise writes `*out_nav` and returns
 * TRUE: with NO current landing, anchor `viewport_row` in the given direction
 * (navigate relative to what the user sees); with a current match, FORWARD →
 * anchor current.row + 1 (saturating at G_MAXUINT64), BACKWARD → anchor
 * current.row (the pinned strictly-before rule needs no decrement, and
 * previous-from-row-0 exhausts core-side into the wrap).
 */
gboolean lsg_find_step (LsgFindSession session, LsgSearchDir direction,
                        guint64 viewport_row, LsgSearchNav *out_nav);

/*
 * The follow-up navigation for a wrap notice: writes from_top for
 * WRAPPED_TO_START, from_end for WRAPPED_TO_END, and returns TRUE; returns
 * FALSE (leaving `*out_nav` untouched) for any other notice. The caller issues
 * it and keeps polling; the wrap notice then self-clears when the navigation
 * lands.
 */
gboolean lsg_find_wrap_nav (LsgFindSession session, LsgSearchNav *out_nav);

/*
 * The scan-cancel affordance (the caller also calls
 * `lsg_document_search_cancel`): keep everything known so far (counts,
 * landing), end the progress UI (no progress), and set the STOPPED notice.
 * Returned unchanged when no search is active.
 */
LsgFindSession lsg_find_stopped (LsgFindSession session);

/*
 * Esc (popover close): the display is cleared to the initial (empty) display —
 * highlights off, counts gone (the caller also cancels the core search) —
 * while the DRAFT is RETAINED so re-running is one Enter.
 */
LsgFindSession lsg_find_closed (LsgFindSession session);

/*
 * Dialect re-open / new document identity: exactly like `lsg_find_closed` —
 * the results clear (search state died with the old core handle) and the draft
 * is retained.
 */
LsgFindSession lsg_find_invalidated (LsgFindSession session);

/* ------------------------------------------------------------------------- */
/* The search bridge over the core — the single place ls_search_* / */
/* ls_window_match_flags are called; extends the <lsg_document.h> session. */
/* ------------------------------------------------------------------------- */

/*
 * Start `request` in the core (mirrors `ls_search_start`), REPLACING any
 * previous search (counts reset; navigation cleared) and taking the core's
 * single scan slot (a scanning jump is cancelled). Returns FALSE iff the core
 * REJECTS the request — an empty TEXT query; a non-NULL scope with a 0 length
 * or an out-of-range index; a PREDICATE column out of range; an ORDERING
 * operator with a non-numeric value — in which case NOTHING changes
 * (`lsg_find_submit` validates first; the core enforces). Performs NO
 * navigation (issue `lsg_document_search_nav(doc, lsg_search_nav_from_top())`
 * for "first match"). Never blocks (the match-scan is asynchronous — poll with
 * `lsg_document_search_poll`). Poll/control lane.
 */
gboolean lsg_document_search_start (LsgDocument *doc,
                                    LsgSearchRequest request);

/*
 * Request the nearest match per `nav` (mirrors `ls_search_nav`; anchor
 * semantics pinned at `LsgSearchNav`). Completes synchronously when the
 * counted region already determines the answer (always, once the scan is
 * DONE); otherwise the scan serves it (resuming a cancelled one if needed).
 * Replaces any pending navigation. No-op when no search is active. Never
 * blocks. Poll/control lane.
 */
void lsg_document_search_nav (LsgDocument *doc, LsgSearchNav nav);

/*
 * Stop the match-scan (mirrors `ls_search_cancel`): counts, landings, and
 * progress freeze at their last values (kept, exact for the counted region); a
 * pending navigation resolves to NONE. No-op when idle or already done. Never
 * blocks. Poll/control lane.
 */
void lsg_document_search_cancel (LsgDocument *doc);

/*
 * Current search snapshot (mirrors `ls_search_poll`). Returns FALSE and leaves
 * `*out` UNTOUCHED when the search state is IDLE — no search since open, which
 * a fresh session (including after a dialect re-open, whose new handle carries
 * no search state) reports: this is the "no snapshot" that `lsg_find_resolved`
 * folds as a nil poll. Otherwise writes `*out` and returns TRUE. Poll/control
 * lane; never blocks; never fails.
 */
gboolean lsg_document_search_poll (const LsgDocument *doc,
                                   LsgSearchSnapshot *out);

/*
 * Per-cell FIND MATCH FLAGS over the CURRENT window for the active search
 * (mirrors `ls_window_match_flags`) — the ONLY match verdict this frontend
 * uses (it owns no matcher). For the window last materialized by
 * `lsg_document_set_window` and the request last started, evaluate the visible
 * column range [first_col, first_col + col_count) and return an OWNED,
 * ROW-MAJOR mask of one flag byte per cell (1 = the cell matches the active
 * request, 0 = it does not), copied out of the core's window-tied borrow
 * immediately (the copy-out discipline of <lsg_document.h>).
 *
 * The result's `rows` is the window's materialized row count, `cols` is
 * `col_count`, and `flags` is `rows * cols` bytes: the flag for window row `r`
 * (0-based within the window) and column `first_col + c` is at
 * `flags[r * cols + c]`. Returns {NULL, 0, 0} when there is NO active search,
 * NO materialized window, `col_count == 0`, or the column range is out of
 * range (the core's empty result — no highlights). Free `flags` with g_free
 * (NULL-safe; nothing to free on the empty result).
 *
 * The verdict is the active request's, over the cells AS MATERIALIZED in the
 * window (the same display-capped bytes a cell read serves): TEXT substring
 * (ASCII case folding per the active request's `case_sensitive` flag) over
 * IN-SCOPE columns (an out-of-scope column is always 0); PREDICATE eq/ne per
 * `case_sensitive` + exact-decimal ordering on the target column only. A
 * FILTER changes only WHICH data rows the window holds, never the per-cell
 * verdict. WINDOW LANE — caller-serialized with `lsg_document_set_window`
 * (issue set_window, then this, for the same range); safe concurrently with
 * the core's background scanning.
 */
typedef struct
{
  guint8 *flags; /* OWNED (g_free); row-major `rows * cols` bytes; NULL when
                    empty */
  guint32 rows;  /* the window's materialized row count (0 when empty) */
  guint32 cols;  /* == the requested col_count (0 when empty) */
} LsgMatchFlags;

LsgMatchFlags lsg_document_window_match_flags (LsgDocument *doc,
                                               guint32 first_col,
                                               guint32 col_count);

G_END_DECLS

#endif /* LSG_FIND_H */
