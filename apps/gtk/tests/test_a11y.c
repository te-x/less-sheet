/*
 * test_a11y.c — RED behavior tests for the display-free accessibility logic
 * (lsg_a11y.h), the gtk-a11y slice. Display-free (glib only): the keyboard
 * cursor/selection reducer, the live-announcement + grid-description string
 * builders, the single accelerator table, and the accessible-name table.
 *
 * Maps the GATE acceptance criteria of ARCH-gtk-a11y.md (test path in
 * parentheses):
 *   G-A1  cursor/selection reducer       (a11y/cursor)
 *   G-A2  announcement builders          (a11y/announce)
 *   G-A3  grid description builder        (a11y/description)
 *   G-A4  single-source accel table      (a11y/shortcuts)
 *   G-A7  Copy/Select-All grid-scoped    (a11y/shortcuts/scope)
 *   G-A5  bare-control names + grid name (a11y/names) — the pure, single-
 *         sourced core; the in-widget role / label wiring is the container
 *         smoke render + the author's Orca pass, not this gate.
 */
#include <glib.h>
#include <string.h>

#include <lsg_a11y.h>

/* ========================================================================= */
/* G-A1 — cursor / selection reducer                                         */
/* ========================================================================= */

static LsgA11yCursor
mkcur (LsgA11ySelMode mode, guint64 ar, guint ac, guint64 br, guint bc)
{
  LsgA11yCursor c = { mode, { ar, ac }, { br, bc } };
  return c;
}

static void
assert_cell (LsgA11yCell got, guint64 row, guint col)
{
  g_assert_cmpuint (got.row, ==, row);
  g_assert_cmpuint (got.col, ==, col);
}

/* Seed: the first arrow from SEL_NONE lands at the top-left visible cell (no
 * directional step), mode CELLS, and asks to be revealed. */
static void
test_cursor_seed (void)
{
  LsgA11yExtent ext = { 1000, 5 };
  LsgA11yView view = { 10, 2, 20 };
  LsgA11yCursor none = mkcur (LSG_A11Y_SEL_NONE, 0, 0, 0, 0);

  LsgA11yCursorResult r
      = lsg_a11y_cursor_apply (none, ext, view, LSG_A11Y_CURSOR_DOWN, FALSE);
  g_assert_cmpint (r.cursor.mode, ==, LSG_A11Y_SEL_CELLS);
  assert_cell (r.cursor.anchor, 10, 2);
  assert_cell (r.cursor.active, 10, 2);
  g_assert_true (r.should_reveal);
  assert_cell (r.reveal, 10, 2);

  /* A first Shift+arrow from NONE also just seeds (nothing to extend yet). */
  LsgA11yCursorResult s
      = lsg_a11y_cursor_apply (none, ext, view, LSG_A11Y_CURSOR_RIGHT, TRUE);
  assert_cell (s.cursor.anchor, 10, 2);
  assert_cell (s.cursor.active, 10, 2);

  /* The seed is clamped to the extent when the visible origin is out of range.
   */
  LsgA11yView far = { 5000, 99, 20 };
  LsgA11yCursorResult c
      = lsg_a11y_cursor_apply (none, ext, far, LSG_A11Y_CURSOR_DOWN, FALSE);
  assert_cell (c.cursor.active, 999, 4);
}

/* Plain arrows COLLAPSE to a 1x1 cell and step the active corner; steps past
 * an edge stay on the edge. */
static void
test_cursor_move_collapse (void)
{
  LsgA11yExtent ext = { 1000, 5 };
  LsgA11yView view = { 0, 0, 20 };
  LsgA11yCursor cur = mkcur (LSG_A11Y_SEL_CELLS, 10, 2, 10, 2);

  LsgA11yCursorResult d
      = lsg_a11y_cursor_apply (cur, ext, view, LSG_A11Y_CURSOR_DOWN, FALSE);
  assert_cell (d.cursor.anchor, 11, 2); /* collapsed: anchor follows active */
  assert_cell (d.cursor.active, 11, 2);
  g_assert_true (d.should_reveal);
  assert_cell (d.reveal, 11, 2);

  LsgA11yCursorResult right
      = lsg_a11y_cursor_apply (cur, ext, view, LSG_A11Y_CURSOR_RIGHT, FALSE);
  assert_cell (right.cursor.active, 10, 3);

  /* Up at the top row / Left at column 0 clamp (stay on the edge). */
  LsgA11yCursor top = mkcur (LSG_A11Y_SEL_CELLS, 0, 0, 0, 0);
  LsgA11yCursorResult up
      = lsg_a11y_cursor_apply (top, ext, view, LSG_A11Y_CURSOR_UP, FALSE);
  assert_cell (up.cursor.active, 0, 0);
  LsgA11yCursorResult left
      = lsg_a11y_cursor_apply (top, ext, view, LSG_A11Y_CURSOR_LEFT, FALSE);
  assert_cell (left.cursor.active, 0, 0);

  /* Right at the last column clamps. */
  LsgA11yCursor edge = mkcur (LSG_A11Y_SEL_CELLS, 10, 4, 10, 4);
  LsgA11yCursorResult redge
      = lsg_a11y_cursor_apply (edge, ext, view, LSG_A11Y_CURSOR_RIGHT, FALSE);
  assert_cell (redge.cursor.active, 10, 4);
}

/* Shift+arrows keep the anchor fixed and step only the active corner. */
static void
test_cursor_extend (void)
{
  LsgA11yExtent ext = { 1000, 5 };
  LsgA11yView view = { 0, 0, 20 };
  LsgA11yCursor cur = mkcur (LSG_A11Y_SEL_CELLS, 10, 2, 10, 2);

  LsgA11yCursorResult d
      = lsg_a11y_cursor_apply (cur, ext, view, LSG_A11Y_CURSOR_DOWN, TRUE);
  assert_cell (d.cursor.anchor, 10, 2); /* anchor fixed */
  assert_cell (d.cursor.active, 11, 2);

  LsgA11yCursorResult r
      = lsg_a11y_cursor_apply (cur, ext, view, LSG_A11Y_CURSOR_RIGHT, TRUE);
  assert_cell (r.cursor.anchor, 10, 2);
  assert_cell (r.cursor.active, 10, 3);
}

/* Page Up/Down step by page rows (saturating at the edges). */
static void
test_cursor_page (void)
{
  LsgA11yExtent ext = { 1000, 5 };
  LsgA11yView view = { 0, 0, 20 };
  LsgA11yCursor cur = mkcur (LSG_A11Y_SEL_CELLS, 10, 2, 10, 2);

  LsgA11yCursorResult down = lsg_a11y_cursor_apply (
      cur, ext, view, LSG_A11Y_CURSOR_PAGE_DOWN, FALSE);
  assert_cell (down.cursor.active, 30, 2);

  LsgA11yCursorResult up
      = lsg_a11y_cursor_apply (cur, ext, view, LSG_A11Y_CURSOR_PAGE_UP, FALSE);
  assert_cell (up.cursor.active, 0, 2); /* 10 - 20 saturates at 0 */
}

/* Home/End go to the first/last row of the view (column unchanged); Shift
 * extends to that end (anchor fixed). */
static void
test_cursor_home_end (void)
{
  LsgA11yExtent ext = { 1000, 5 };
  LsgA11yView view = { 0, 0, 20 };
  LsgA11yCursor cur = mkcur (LSG_A11Y_SEL_CELLS, 10, 2, 10, 2);

  LsgA11yCursorResult home
      = lsg_a11y_cursor_apply (cur, ext, view, LSG_A11Y_CURSOR_HOME, FALSE);
  assert_cell (home.cursor.active, 0, 2);

  LsgA11yCursorResult end
      = lsg_a11y_cursor_apply (cur, ext, view, LSG_A11Y_CURSOR_END, FALSE);
  assert_cell (end.cursor.active, 999, 2);

  LsgA11yCursorResult end_ext
      = lsg_a11y_cursor_apply (cur, ext, view, LSG_A11Y_CURSOR_END, TRUE);
  assert_cell (end_ext.cursor.anchor, 10, 2); /* anchor fixed */
  assert_cell (end_ext.cursor.active, 999, 2);
}

/* Select-all spans the whole (given/capped) extent in O(1) and does NOT
 * scroll.
 */
static void
test_cursor_select_all (void)
{
  LsgA11yExtent ext = { 1000, 5 };
  LsgA11yView view = { 0, 0, 20 };
  LsgA11yCursor cur = mkcur (LSG_A11Y_SEL_CELLS, 10, 2, 10, 2);

  LsgA11yCursorResult r = lsg_a11y_cursor_apply (
      cur, ext, view, LSG_A11Y_CURSOR_SELECT_ALL, FALSE);
  g_assert_cmpint (r.cursor.mode, ==, LSG_A11Y_SEL_CELLS);
  assert_cell (r.cursor.anchor, 0, 0);
  assert_cell (r.cursor.active, 999, 4);
  g_assert_false (r.should_reveal);
}

/* Clear returns a NONE cursor and does not scroll. */
static void
test_cursor_clear (void)
{
  LsgA11yExtent ext = { 1000, 5 };
  LsgA11yView view = { 0, 0, 20 };
  LsgA11yCursor cur = mkcur (LSG_A11Y_SEL_CELLS, 10, 2, 12, 4);

  LsgA11yCursorResult r
      = lsg_a11y_cursor_apply (cur, ext, view, LSG_A11Y_CURSOR_CLEAR, FALSE);
  g_assert_cmpint (r.cursor.mode, ==, LSG_A11Y_SEL_NONE);
  g_assert_false (r.should_reveal);
}

/* Every result is clamped into a SHRUNK extent (e.g. a filter reduced the
 * view) — no out-of-range corner survives. */
static void
test_cursor_clamp_shrunk (void)
{
  LsgA11yExtent ext = { 100, 2 }; /* smaller than the cursor below */
  LsgA11yView view = { 0, 0, 20 };
  LsgA11yCursor cur = mkcur (LSG_A11Y_SEL_CELLS, 500, 3, 500, 3);

  LsgA11yCursorResult r
      = lsg_a11y_cursor_apply (cur, ext, view, LSG_A11Y_CURSOR_DOWN, FALSE);
  assert_cell (r.cursor.active, 99, 1); /* row+col clamped to the extent */
  assert_cell (r.cursor.anchor, 99, 1);
}

/* An empty (0-row or 0-column) view makes every command a no-op. */
static void
test_cursor_empty_noop (void)
{
  LsgA11yView view = { 0, 0, 20 };
  LsgA11yCursor none = mkcur (LSG_A11Y_SEL_NONE, 0, 0, 0, 0);

  LsgA11yExtent no_rows = { 0, 5 };
  LsgA11yCursorResult a = lsg_a11y_cursor_apply (none, no_rows, view,
                                                 LSG_A11Y_CURSOR_DOWN, FALSE);
  g_assert_cmpint (a.cursor.mode, ==, LSG_A11Y_SEL_NONE);
  g_assert_false (a.should_reveal);

  /* Select-all over nothing is also a no-op. */
  LsgA11yCursorResult b = lsg_a11y_cursor_apply (
      none, no_rows, view, LSG_A11Y_CURSOR_SELECT_ALL, FALSE);
  g_assert_cmpint (b.cursor.mode, ==, LSG_A11Y_SEL_NONE);
  g_assert_false (b.should_reveal);

  LsgA11yExtent no_cols = { 1000, 0 };
  LsgA11yCursorResult c = lsg_a11y_cursor_apply (none, no_cols, view,
                                                 LSG_A11Y_CURSOR_RIGHT, FALSE);
  g_assert_cmpint (c.cursor.mode, ==, LSG_A11Y_SEL_NONE);
  g_assert_false (c.should_reveal);
}

/* ========================================================================= */
/* G-A2 — announcement string builders                                       */
/* ========================================================================= */

static void
test_announce_cursor (void)
{
  char *s = lsg_a11y_announce_cursor (42, "Name", "Alice");
  g_assert_cmpstr (s, ==, "Row 42, Name: Alice");
  g_free (s);

  /* A multibyte value under the clip is passed through intact ("é" is 1 char /
   * 2 bytes). */
  char *m = lsg_a11y_announce_cursor (7, "Ville", "caf\xC3\xA9");
  g_assert_cmpstr (m, ==, "Row 7, Ville: caf\xC3\xA9");
  g_free (m);

  /* NULL column / value are treated as "". */
  char *n = lsg_a11y_announce_cursor (5, NULL, NULL);
  g_assert_cmpstr (n, ==, "Row 5, : ");
  g_free (n);
}

static void
test_announce_cursor_clip (void)
{
  /* A value of exactly LSG_A11Y_VALUE_CLIP_CHARS chars is NOT clipped. */
  GString *v = g_string_new (NULL);
  for (int i = 0; i < LSG_A11Y_VALUE_CLIP_CHARS; i++)
    g_string_append_c (v, 'a');
  char *exact = lsg_a11y_announce_cursor (1, "C", v->str);
  GString *exp = g_string_new ("Row 1, C: ");
  g_string_append (exp, v->str);
  g_assert_cmpstr (exact, ==, exp->str);
  g_free (exact);

  /* One char over the limit clips to CLIP chars + a single ellipsis. */
  g_string_append_c (v, 'a'); /* now CLIP+1 chars */
  char *clipped = lsg_a11y_announce_cursor (1, "C", v->str);
  g_string_truncate (exp, 0);
  g_string_append (exp, "Row 1, C: ");
  for (int i = 0; i < LSG_A11Y_VALUE_CLIP_CHARS; i++)
    g_string_append_c (exp, 'a');
  g_string_append (exp, "\xE2\x80\xA6"); /* U+2026 … */
  g_assert_cmpstr (clipped, ==, exp->str);
  g_free (clipped);

  g_string_free (v, TRUE);
  g_string_free (exp, TRUE);
}

static void
test_announce_selection (void)
{
  char *s = lsg_a11y_announce_selection (3, 2);
  g_assert_cmpstr (s, ==, "3 rows \xC3\x97 2 columns selected"); /* U+00D7 x */
  g_free (s);

  char *one = lsg_a11y_announce_selection (1, 1);
  g_assert_cmpstr (one, ==, "1 rows \xC3\x97 1 columns selected");
  g_free (one);
}

static void
test_announce_find_landing (void)
{
  char *s = lsg_a11y_announce_find_landing (2, 7, 15);
  g_assert_cmpstr (s, ==, "Match 2 of 7, row 15");
  g_free (s);
}

/* ========================================================================= */
/* G-A3 — grid description builder                                           */
/* ========================================================================= */

static void
test_description (void)
{
  /* Identity view, exact count. */
  char *a
      = lsg_a11y_grid_description ("data.csv", 3, 1000, FALSE, 1, 20, FALSE);
  g_assert_cmpstr (a, ==,
                   "data.csv, 3 columns, 1000 rows, showing rows 1 to 20");
  g_free (a);

  /* Estimated count -> "~" prefix. */
  char *e
      = lsg_a11y_grid_description ("data.csv", 3, 1000, TRUE, 1, 20, FALSE);
  g_assert_cmpstr (e, ==,
                   "data.csv, 3 columns, ~1000 rows, showing rows 1 to 20");
  g_free (e);

  /* Filtered -> ", filtered" suffix. */
  char *f
      = lsg_a11y_grid_description ("data.csv", 3, 1000, FALSE, 5, 24, TRUE);
  g_assert_cmpstr (
      f, ==,
      "data.csv, 3 columns, 1000 rows, showing rows 5 to 24, filtered");
  g_free (f);

  /* Empty view -> "0 rows", no "showing rows". */
  char *z = lsg_a11y_grid_description ("empty.csv", 3, 0, FALSE, 0, 0, FALSE);
  g_assert_cmpstr (z, ==, "empty.csv, 3 columns, 0 rows");
  g_free (z);

  /* Empty + filtered (a filter matching nothing). */
  char *zf = lsg_a11y_grid_description ("data.csv", 3, 0, FALSE, 0, 0, TRUE);
  g_assert_cmpstr (zf, ==, "data.csv, 3 columns, 0 rows, filtered");
  g_free (zf);

  /* NULL name is treated as "". */
  char *n = lsg_a11y_grid_description (NULL, 2, 5, FALSE, 1, 5, FALSE);
  g_assert_cmpstr (n, ==, ", 2 columns, 5 rows, showing rows 1 to 5");
  g_free (n);
}

/* ========================================================================= */
/* G-A4 / G-A7 — the single accelerator / shortcuts table                    */
/* ========================================================================= */

static const LsgA11yShortcut *
find_cmd (const LsgA11yShortcut *t, guint n, LsgA11yCommand c)
{
  if (t == NULL)
    return NULL;
  for (guint i = 0; i < n; i++)
    if (t[i].command == c)
      return &t[i];
  return NULL;
}

/* Each command appears EXACTLY once and the table holds exactly the full set.
 */
static void
test_shortcuts_complete (void)
{
  guint n = 0;
  const LsgA11yShortcut *t = lsg_a11y_shortcuts (&n);
  g_assert_nonnull (t);
  g_assert_cmpuint (n, ==, (guint)LSG_A11Y_CMD_N);

  for (guint c = 0; c < (guint)LSG_A11Y_CMD_N; c++)
    {
      guint seen = 0;
      for (guint i = 0; i < n; i++)
        if ((guint)t[i].command == c)
          seen++;
      g_assert_cmpuint (seen, ==, 1);
    }
}

/* The load-bearing accelerators are present with the exact accel + action-name
 * + group the surface and the registration both consume (including the ones
 * the old stub was missing / wrong). */
static void
test_shortcuts_bindings (void)
{
  guint n = 0;
  const LsgA11yShortcut *t = lsg_a11y_shortcuts (&n);

  const LsgA11yShortcut *open = find_cmd (t, n, LSG_A11Y_CMD_OPEN);
  g_assert_nonnull (open);
  g_assert_cmpint (open->scope, ==, LSG_A11Y_SCOPE_APP);
  g_assert_cmpstr (open->action_name, ==, "app.open");
  g_assert_cmpstr (open->accel, ==, "<Control>o");

  const LsgA11yShortcut *url = find_cmd (t, n, LSG_A11Y_CMD_OPEN_URL);
  g_assert_nonnull (url);
  g_assert_cmpstr (url->accel, ==, "<Control><Shift>o");

  const LsgA11yShortcut *find = find_cmd (t, n, LSG_A11Y_CMD_FIND);
  g_assert_nonnull (find);
  g_assert_cmpstr (find->action_name, ==, "app.find");
  g_assert_cmpstr (find->accel, ==, "<Control>f");

  /* Jump carries BOTH Ctrl+G and Ctrl+L. */
  const LsgA11yShortcut *jump = find_cmd (t, n, LSG_A11Y_CMD_JUMP);
  g_assert_nonnull (jump);
  g_assert_cmpstr (jump->accel, ==, "<Control>g");
  g_assert_cmpstr (jump->accel2, ==, "<Control>l");

  /* Preferences is now REALLY bound (Ctrl+comma), not a dead display entry. */
  const LsgA11yShortcut *prefs = find_cmd (t, n, LSG_A11Y_CMD_PREFERENCES);
  g_assert_nonnull (prefs);
  g_assert_cmpint (prefs->scope, ==, LSG_A11Y_SCOPE_APP);
  g_assert_cmpstr (prefs->action_name, ==, "app.preferences");
  g_assert_cmpstr (prefs->accel, ==, "<Control>comma");

  /* Shortcuts action carries both Ctrl+? and Ctrl+F1. */
  const LsgA11yShortcut *sc = find_cmd (t, n, LSG_A11Y_CMD_SHORTCUTS);
  g_assert_nonnull (sc);
  g_assert_cmpstr (sc->action_name, ==, "app.shortcuts");
  g_assert_cmpstr (sc->accel, ==, "<Control>question");
  g_assert_cmpstr (sc->accel2, ==, "<Control>F1");

  /* Find Next / Prev are present (the old stub omitted them). */
  const LsgA11yShortcut *next = find_cmd (t, n, LSG_A11Y_CMD_FIND_NEXT);
  g_assert_nonnull (next);
  g_assert_cmpstr (next->accel, ==, "Return");
  const LsgA11yShortcut *prev = find_cmd (t, n, LSG_A11Y_CMD_FIND_PREV);
  g_assert_nonnull (prev);
  g_assert_cmpstr (prev->accel, ==, "<Shift>Return");
}

/* G-A7: Copy and Select-All are GRID-scoped (never registered as global app
 * accelerators), and the APP scope is exactly the set carrying a GAction name.
 */
static void
test_shortcuts_scope (void)
{
  guint n = 0;
  const LsgA11yShortcut *t = lsg_a11y_shortcuts (&n);

  const LsgA11yShortcut *copy = find_cmd (t, n, LSG_A11Y_CMD_COPY);
  g_assert_nonnull (copy);
  g_assert_cmpint (copy->scope, ==, LSG_A11Y_SCOPE_GRID);
  g_assert_cmpstr (copy->accel, ==, "<Control>c");

  const LsgA11yShortcut *sa = find_cmd (t, n, LSG_A11Y_CMD_SELECT_ALL);
  g_assert_nonnull (sa);
  g_assert_cmpint (sa->scope, ==, LSG_A11Y_SCOPE_GRID);
  g_assert_cmpstr (sa->accel, ==, "<Control>a");

  /* action_name is non-NULL IFF the entry is a global app accelerator: nothing
   * grid-scoped or display-only leaks in as an unconditional app accel. */
  for (guint i = 0; i < n; i++)
    {
      if (t[i].scope == LSG_A11Y_SCOPE_APP)
        {
          g_assert_nonnull (t[i].action_name);
          g_assert_nonnull (t[i].accel);
        }
      else
        g_assert_null (t[i].action_name);
    }

  /* Every entry has a non-empty title and a primary accel. */
  for (guint i = 0; i < n; i++)
    {
      g_assert_nonnull (t[i].title);
      g_assert_cmpuint (strlen (t[i].title), >, 0);
      g_assert_nonnull (t[i].accel);
      g_assert_cmpuint (strlen (t[i].accel), >, 0);
    }
}

/* ========================================================================= */
/* G-A5 — accessible names (the pure, single-sourced core)                   */
/* ========================================================================= */

static void
test_control_names (void)
{
  /* The FR4 table — exact names, single-sourced (the frontend sets each
   * control's accessible label from here; the tooltip drift is gone). */
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_OPEN_FILE), ==,
                   "Open File");
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_OPEN_URL), ==,
                   "Open URL");
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_FIND), ==, "Find");
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_FIND_PREV), ==,
                   "Previous match");
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_FIND_NEXT), ==,
                   "Next match");
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_SEARCH_ENTRY), ==,
                   "Find text");
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_JUMP), ==,
                   "Jump to row");
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_HEADER_TOGGLE), ==,
                   "First row is a header");
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_SEPARATOR), ==,
                   "Field separator");
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_QUOTE), ==,
                   "Quote character");
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_CLEAR_FILTER), ==,
                   "Clear filter");
  g_assert_cmpstr (lsg_a11y_control_name (LSG_A11Y_CONTROL_MENU), ==,
                   "Main menu");

  /* Every control id yields a non-empty name (no bare control left behind). */
  for (guint c = 0; c < (guint)LSG_A11Y_CONTROL_N; c++)
    g_assert_cmpuint (strlen (lsg_a11y_control_name ((LsgA11yControl)c)), >,
                      0);
}

static void
test_grid_name (void)
{
  /* The grid's fixed accessible name is the format-neutral "Data grid". */
  g_assert_cmpstr (LSG_A11Y_GRID_NAME, ==, "Data grid");
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/a11y/cursor/seed", test_cursor_seed);
  g_test_add_func ("/a11y/cursor/move-collapse", test_cursor_move_collapse);
  g_test_add_func ("/a11y/cursor/extend", test_cursor_extend);
  g_test_add_func ("/a11y/cursor/page", test_cursor_page);
  g_test_add_func ("/a11y/cursor/home-end", test_cursor_home_end);
  g_test_add_func ("/a11y/cursor/select-all", test_cursor_select_all);
  g_test_add_func ("/a11y/cursor/clear", test_cursor_clear);
  g_test_add_func ("/a11y/cursor/clamp-shrunk", test_cursor_clamp_shrunk);
  g_test_add_func ("/a11y/cursor/empty-noop", test_cursor_empty_noop);

  g_test_add_func ("/a11y/announce/cursor", test_announce_cursor);
  g_test_add_func ("/a11y/announce/cursor-clip", test_announce_cursor_clip);
  g_test_add_func ("/a11y/announce/selection", test_announce_selection);
  g_test_add_func ("/a11y/announce/find-landing", test_announce_find_landing);

  g_test_add_func ("/a11y/description/build", test_description);

  g_test_add_func ("/a11y/shortcuts/complete", test_shortcuts_complete);
  g_test_add_func ("/a11y/shortcuts/bindings", test_shortcuts_bindings);
  g_test_add_func ("/a11y/shortcuts/scope", test_shortcuts_scope);

  g_test_add_func ("/a11y/names/controls", test_control_names);
  g_test_add_func ("/a11y/names/grid", test_grid_name);

  return g_test_run ();
}
