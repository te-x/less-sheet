/*
 * lsg_a11y.h — the GTK frontend's display-free ACCESSIBILITY logic (the
 * gtk-a11y slice, ARCH-gtk-a11y.md Decision 2). This is the pure,
 * unit-testable heart the display/AT glue in src/main.c routes through, so the
 * gate verifies the behavior HEADLESSLY (no display, no AT-SPI bus, no Orca) —
 * mirroring the frontend's layered discipline and the macOS
 * `Contracts/Selection.swift` + `SelectCopyLogic` split.
 *
 * Everything here is ARITHMETIC over plain numbers and byte-exact STRING
 * building over borrowed UTF-8 — no widgets, no display server, no GTK. It
 * owns four concerns:
 *   1. the keyboard CURSOR/SELECTION reducer (seed / move / extend / page /
 *      home-end / horizontal / select-all / clear, all clamped to the view
 *      extent) — the active corner of the ONE shared selection rectangle;
 *   2. the live-announcement STRING builders (cursor move, extend/select-all,
 *      find landing) and the grid DESCRIPTION builder;
 *   3. the single ACCELERATOR table (the one source consumed by BOTH the accel
 *      registration and the native shortcuts surface — no hand-typed drift);
 *   4. the ACCESSIBLE-NAME table for the bare interactive controls (FR4) and
 *      the grid's fixed accessible name.
 *
 * The rendering that stays display/AT-dependent (key-event routing, the Cairo
 * accent outline, `gtk_accessible_announce`, the widget role/label wiring, the
 * AdwShortcutsDialog) lives in src/main.c and is verified by the container
 * smoke render + the author's human GNOME/Orca pass (ARCH-gtk-a11y H-A1..H-A5) —
 * NOT by this module. This header is the contract those call sites honor.
 */
#ifndef LSG_A11Y_H
#define LSG_A11Y_H

#include <glib.h>

G_BEGIN_DECLS

/* ========================================================================= */
/* 1. Keyboard cursor / selection reducer (ARCH-gtk-a11y FR1/FR2, G-A1) */
/* ========================================================================= */

/*
 * The selection mode the reducer works in. Keyboard interaction only ever
 * yields NONE (nothing / cleared) or CELLS (a cell rectangle): a whole-row /
 * whole-column mouse selection collapses to an equivalent CELLS rectangle the
 * instant the keyboard touches it (the corner geometry is identical), so the
 * reducer needs no ROWS/COLS mode. src/main.c maps its own `sel_mode`
 * (SEL_NONE / SEL_CELLS / SEL_ROWS / SEL_COLS) onto this at the boundary:
 * SEL_NONE => NONE, anything else => CELLS.
 */
typedef enum
{
  LSG_A11Y_SEL_NONE = 0,  /* no cursor / no selection */
  LSG_A11Y_SEL_CELLS = 1, /* a cell rectangle (what the keyboard produces) */
} LsgA11ySelMode;

/*
 * One cell address, mirroring the core's / App's addressing: a 64-bit
 * view-relative ROW index (a FILTERED index while a filter is active, exactly
 * like every other row index the frontend holds) and a 0-based COLUMN index.
 * `row`/`col` match App's `sel_*_row` (guint64) / `sel_*_col` (guint).
 */
typedef struct
{
  guint64 row;
  guint col;
} LsgA11yCell;

/*
 * A live cursor/selection: the fixed `anchor` corner (App `sel_a_*`) and the
 * moving `active` corner — the keyboard CURSOR (App `sel_b_*`). The drawn /
 * copied rectangle is their inclusive bounding box, so extend simply moves
 * `active` while `anchor` stays put, and select-all places the two corners at
 * the extent's edges. There is no separate kind: whole-row / whole-column
 * emphasis is derived by the frontend from the rect vs. the extent.
 */
typedef struct
{
  LsgA11ySelMode mode;
  LsgA11yCell anchor;
  LsgA11yCell active;
} LsgA11yCursor;

/*
 * The current view's selectable EXTENT — the clamp domain for every command:
 * `rows` (the CURRENT displayed row count — the filtered count while filtered,
 * the current estimate while indexing; this is the "capped" select-all extent,
 * never a forced full scan) and `cols` (the column count). Valid indices are
 * `0 .. rows-1` and `0 .. cols-1`. The extent is EMPTY when `rows == 0` or
 * `cols == 0` (an empty document, or a filter matching nothing): every command
 * is then a no-op.
 */
typedef struct
{
  guint64 rows;
  guint cols;
} LsgA11yExtent;

/*
 * The visible-window descriptor the reducer needs for SEEDING and PAGING (it
 * does not itself scroll — src/main.c owns `vadj`/`hadj`):
 *   - `first_row` / `first_col`: the top-left currently-visible data cell,
 *     where a first press from LSG_A11Y_SEL_NONE seeds the cursor (clamped);
 *   - `page_rows`: rows to step for Page Up/Down (`page_size / row_h`); a
 * value of 0 is treated as 1 so a page always advances at least one row.
 */
typedef struct
{
  guint64 first_row;
  guint first_col;
  guint32 page_rows;
} LsgA11yView;

/*
 * The keyboard commands the grid routes into the reducer. The plain arrows and
 * Page/Home/End also take the `extend` flag (Shift held) in
 * `lsg_a11y_cursor_apply`. SELECT_ALL and CLEAR ignore `extend`.
 */
typedef enum
{
  LSG_A11Y_CURSOR_UP = 0,
  LSG_A11Y_CURSOR_DOWN,
  LSG_A11Y_CURSOR_LEFT,
  LSG_A11Y_CURSOR_RIGHT,
  LSG_A11Y_CURSOR_PAGE_UP,
  LSG_A11Y_CURSOR_PAGE_DOWN,
  LSG_A11Y_CURSOR_HOME, /* first row of the current view */
  LSG_A11Y_CURSOR_END,  /* last row of the current view */
  LSG_A11Y_CURSOR_SELECT_ALL,
  LSG_A11Y_CURSOR_CLEAR,
} LsgA11yCursorCommand;

/*
 * The reducer's result: the new cursor state plus the auto-scroll hint. The
 * frontend applies the state to `sel_*`, then — iff `should_reveal` — scrolls
 * the MINIMUM needed to bring `reveal` fully into view (no move if already
 * visible). `reveal` equals the new `active` corner. SELECT_ALL and CLEAR set
 * `should_reveal` FALSE (they must not scroll the viewport).
 */
typedef struct
{
  LsgA11yCursor cursor;
  gboolean should_reveal;
  LsgA11yCell reveal;
} LsgA11yCursorResult;

/*
 * Apply one keyboard command to the cursor. PURE and O(1) in the extent (no
 * clamping loop, no materialization — SELECT_ALL on the largest document is
 * free). Every returned corner is clamped into `[0, rows-1] x [0, cols-1]`.
 *
 * Pinned semantics (ARCH-gtk-a11y FR1/FR2 + G-A1):
 *   - EMPTY extent (`rows == 0 || cols == 0`): NO-OP — returns `current`
 *     unchanged with `should_reveal` FALSE (every command, including
 *     SELECT_ALL/CLEAR).
 *   - CLEAR: returns a NONE cursor (corners zeroed), `should_reveal` FALSE.
 *   - SELECT_ALL: the whole extent — `anchor = {0,0}`,
 *     `active = {rows-1, cols-1}`, mode CELLS, `should_reveal` FALSE.
 *   - SEED (any directional / page / home / end command while
 *     `current.mode == LSG_A11Y_SEL_NONE`): the FIRST press establishes the
 *     cursor at the top-left visible cell — `anchor = active =
 *     clamp(first_row, first_col)`, mode CELLS, `should_reveal` TRUE. No
 *     directional step is applied on this first press (the `extend` flag is
 *     immaterial: anchor == active == seed).
 *   - From a live cursor (mode CELLS), the ACTIVE corner steps from
 *     `current.active`:
 *       UP/DOWN     +/- 1 row (clamped at 0 / rows-1);
 *       LEFT/RIGHT  +/- 1 column (clamped at 0 / cols-1);
 *       PAGE_UP/DN  +/- max(page_rows,1) rows (clamped);
 *       HOME/END    row -> 0 / rows-1 (column unchanged).
 *     PLAIN (`extend` FALSE): COLLAPSE — `anchor = active = stepped`.
 *     EXTEND (`extend` TRUE): `anchor` kept (re-clamped), `active = stepped`.
 *     `should_reveal` TRUE, `reveal = active`.
 */
LsgA11yCursorResult lsg_a11y_cursor_apply (LsgA11yCursor current,
                                           LsgA11yExtent extent,
                                           LsgA11yView view,
                                           LsgA11yCursorCommand command,
                                           gboolean extend);

/* ========================================================================= */
/* 2. Live-announcement + grid-description string builders (G-A2 / G-A3) */
/* ========================================================================= */

/*
 * The cursor-move announcement clips the CELL VALUE to this many UTF-8
 * CHARACTERS (not bytes), appending a single "…" when the value is longer, so
 * a multi-KB cell never floods the screen reader. The "Row R, Name: " prefix
 * is always kept whole.
 */
#define LSG_A11Y_VALUE_CLIP_CHARS 80

/*
 * The grid's fixed accessible NAME (format-neutral, FR3). The frontend sets
 * `app->area`'s GTK_ACCESSIBLE_PROPERTY_LABEL to this.
 */
#define LSG_A11Y_GRID_NAME "Data grid"

/*
 * Cursor-move announcement (LOW priority): `"Row <row>, <column>: <value>"`.
 * `row` is the gutter row number the grid draws (1-based; the SOURCE row
 * number under a filter). `column` is the header label (`has_header`) else the
 * generic column name. `value` is the DISPLAYED (formatted) cell text, clipped
 * per LSG_A11Y_VALUE_CLIP_CHARS. A NULL `column` / `value` is treated as "".
 * Returns a newly-allocated UTF-8 string (free with g_free).
 */
char *lsg_a11y_announce_cursor (guint64 row, const char *column,
                                const char *value);

/*
 * Extend / select-all announcement (MEDIUM priority):
 * `"<rows> rows × <cols> columns selected"` (the separator is U+00D7). `rows`
 * / `cols` are the selection rectangle's dimensions. Returns a newly-allocated
 * UTF-8 string (free with g_free).
 */
char *lsg_a11y_announce_selection (guint64 rows, guint cols);

/*
 * Find-navigation-landing announcement (MEDIUM priority):
 * `"Match <n> of <m>, row <row>"`, where `n`/`m` are the same 1-based rank /
 * total the find status shows and `row` is the landing's gutter row number.
 * Returns a newly-allocated UTF-8 string (free with g_free).
 */
char *lsg_a11y_announce_find_landing (guint64 n, guint64 m, guint64 row);

/*
 * The grid's dynamic accessible DESCRIPTION (set as a property, never
 * announced). Rebuilt whenever the relevant state changes:
 *   rows > 0:  "<name>, <cols> columns, [~]<rows> rows,
 *               showing rows <first> to <last>[, filtered]"
 *   rows == 0: "<name>, <cols> columns, 0 rows[, filtered]"
 * `estimated` prefixes the row count with "~" (the count is still an
 * estimate). `first` / `last` are the gutter row numbers of the first / last
 * visible data rows (ignored when `rows == 0`). `filtered` appends ",
 * filtered". A NULL `name` is treated as "". Returns a newly-allocated UTF-8
 * string (free with g_free).
 */
char *lsg_a11y_grid_description (const char *name, guint cols, guint64 rows,
                                 gboolean estimated, guint64 first,
                                 guint64 last, gboolean filtered);

/* ========================================================================= */
/* 3. The single accelerator / shortcuts table (FR5, G-A4 / G-A7) */
/* ========================================================================= */

/* Sensible grouping for the native shortcuts surface. */
typedef enum
{
  LSG_A11Y_GROUP_GENERAL = 0,
  LSG_A11Y_GROUP_FIND,
  LSG_A11Y_GROUP_NAVIGATION,
  LSG_A11Y_GROUP_SELECTION,
} LsgA11yShortcutGroup;

/*
 * How a shortcut is wired — this is what keeps Copy / Select-All from stealing
 * a focused text entry's own Ctrl+C / Ctrl+A (FR2, G-A7):
 *   - APP:     a global application accelerator — the frontend registers it
 * via `gtk_application_set_accels_for_action(action_name, {accel[, accel2]})`.
 * EXACTLY the entries with a non-NULL `action_name`.
 *   - GRID:    grid-focus-scoped — installed on the grid's own
 *              `GtkShortcutController` (local/managed scope) / gated on grid
 *              focus, so it NEVER fires while a `GtkText` is focused.
 * Registered as an app accel by NO code path.
 *   - DISPLAY: shown in the surface only; the behavior is handled elsewhere
 *              (the find popover for Next/Prev, the grid key controller for
 * the cursor moves / digit-jump / Esc). Not an accelerator anywhere.
 */
typedef enum
{
  LSG_A11Y_SCOPE_APP = 0,
  LSG_A11Y_SCOPE_GRID,
  LSG_A11Y_SCOPE_DISPLAY,
} LsgA11yShortcutScope;

/*
 * The distinct shortcut commands. Each appears EXACTLY ONCE in the table
 * (`lsg_a11y_shortcuts` returns LSG_A11Y_CMD_N entries), so the enum doubles
 * as the completeness check.
 */
typedef enum
{
  LSG_A11Y_CMD_OPEN = 0,
  LSG_A11Y_CMD_OPEN_URL,
  LSG_A11Y_CMD_PREFERENCES,
  LSG_A11Y_CMD_SHORTCUTS,
  LSG_A11Y_CMD_FIND,
  LSG_A11Y_CMD_FIND_NEXT,
  LSG_A11Y_CMD_FIND_PREV,
  LSG_A11Y_CMD_ESCAPE,
  LSG_A11Y_CMD_JUMP,
  LSG_A11Y_CMD_MOVE,       /* Up / Down / Left / Right cursor (+ horizontal) */
  LSG_A11Y_CMD_PAGE,       /* Page Up / Page Down */
  LSG_A11Y_CMD_HOME_END,   /* Home / End */
  LSG_A11Y_CMD_DIGIT_JUMP, /* type 0-9 to jump to a row */
  LSG_A11Y_CMD_EXTEND,     /* Shift + arrows extend the selection */
  LSG_A11Y_CMD_SELECT_ALL,
  LSG_A11Y_CMD_COPY,
  LSG_A11Y_CMD_N, /* count sentinel — NOT a command */
} LsgA11yCommand;

/*
 * One shortcut. `title` is the human label for the surface. `action_name` is
 * the detailed `GAction` name for SCOPE_APP entries (fed to
 * `gtk_application_set_accels_for_action`) and NULL otherwise. `accel` /
 * `accel2` are GTK accelerator strings (e.g. "<Control>o", "<Shift>Return") or
 * display tokens the surface renders (e.g. "0...9", "Up Down Left Right");
 * `accel2` is NULL when there is only one.
 */
typedef struct
{
  LsgA11yCommand command;
  LsgA11yShortcutGroup group;
  LsgA11yShortcutScope scope;
  const char *title;
  const char *action_name;
  const char *accel;
  const char *accel2;
} LsgA11yShortcut;

/*
 * The SINGLE source of truth for the app's keyboard shortcuts, consumed by
 * BOTH the accelerator registration (SCOPE_APP entries) AND the native
 * shortcuts surface (every entry -> one AdwShortcutsItem under its group) — so
 * the displayed accelerator always equals the one that actually fires, with no
 * hand-typed list anywhere else (FR5). Returns a pointer to the static table;
 * `*out_n` is set to the entry count (== LSG_A11Y_CMD_N). `out_n` must not be
 * NULL.
 */
const LsgA11yShortcut *lsg_a11y_shortcuts (guint *out_n);

/* ========================================================================= */
/* 4. Accessible names for the bare interactive controls (FR4, G-A5) */
/* ========================================================================= */

/*
 * The interactive controls that carry only a tooltip today and need an
 * explicit accessible name. The frontend sets each one's
 * GTK_ACCESSIBLE_PROPERTY_LABEL from `lsg_a11y_control_name` (single source,
 * no drift from the tooltip text).
 */
typedef enum
{
  LSG_A11Y_CONTROL_OPEN_FILE = 0,
  LSG_A11Y_CONTROL_OPEN_URL,
  LSG_A11Y_CONTROL_FIND,
  LSG_A11Y_CONTROL_FIND_PREV,
  LSG_A11Y_CONTROL_FIND_NEXT,
  LSG_A11Y_CONTROL_SEARCH_ENTRY,
  LSG_A11Y_CONTROL_JUMP,
  LSG_A11Y_CONTROL_HEADER_TOGGLE,
  LSG_A11Y_CONTROL_SEPARATOR,
  LSG_A11Y_CONTROL_QUOTE,
  LSG_A11Y_CONTROL_CLEAR_FILTER,
  LSG_A11Y_CONTROL_MENU,
  LSG_A11Y_CONTROL_N, /* count sentinel — NOT a control */
} LsgA11yControl;

/*
 * The accessible name for `control` (the FR4 table). Returns a static,
 * non-empty UTF-8 string; "" for an out-of-range id.
 */
const char *lsg_a11y_control_name (LsgA11yControl control);

G_END_DECLS

#endif /* LSG_A11Y_H */
