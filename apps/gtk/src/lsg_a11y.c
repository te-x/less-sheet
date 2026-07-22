/*
 * lsg_a11y.c — RED SEED for the display-free accessibility logic (lsg_a11y.h),
 * the gtk-a11y slice.
 *
 * This is the planner's freeze seed: it COMPILES clean against the frozen
 * header (so CONFORMANCE passes) but deliberately returns empty / zeroed
 * results, so every behavior assertion in tests/test_a11y.c FAILS (the
 * expected armed-RED freeze state). The implementer replaces each body with
 * the real pinned behavior documented in lsg_a11y.h — the cursor reducer
 * geometry, the byte-exact string builders, the single accelerator table, and
 * the FR4 accessible-name table — turning the suite GREEN without touching the
 * header or the tests.
 */
#include "lsg_a11y.h"

/* 1. Cursor / selection reducer ------------------------------------------- */

LsgA11yCursorResult
lsg_a11y_cursor_apply (LsgA11yCursor current, LsgA11yExtent extent,
                       LsgA11yView view, LsgA11yCursorCommand command,
                       gboolean extend)
{
  (void)current;
  (void)extent;
  (void)view;
  (void)command;
  (void)extend;
  LsgA11yCursorResult r
      = { { LSG_A11Y_SEL_NONE, { 0, 0 }, { 0, 0 } }, FALSE, { 0, 0 } };
  return r;
}

/* 2. Announcement + description string builders --------------------------- */

char *
lsg_a11y_announce_cursor (guint64 row, const char *column, const char *value)
{
  (void)row;
  (void)column;
  (void)value;
  return g_strdup ("");
}

char *
lsg_a11y_announce_selection (guint64 rows, guint cols)
{
  (void)rows;
  (void)cols;
  return g_strdup ("");
}

char *
lsg_a11y_announce_find_landing (guint64 n, guint64 m, guint64 row)
{
  (void)n;
  (void)m;
  (void)row;
  return g_strdup ("");
}

char *
lsg_a11y_grid_description (const char *name, guint cols, guint64 rows,
                           gboolean estimated, guint64 first, guint64 last,
                           gboolean filtered)
{
  (void)name;
  (void)cols;
  (void)rows;
  (void)estimated;
  (void)first;
  (void)last;
  (void)filtered;
  return g_strdup ("");
}

/* 3. The single accelerator / shortcuts table ----------------------------- */

const LsgA11yShortcut *
lsg_a11y_shortcuts (guint *out_n)
{
  if (out_n != NULL)
    *out_n = 0;
  return NULL;
}

/* 4. Accessible names for the bare interactive controls ------------------- */

const char *
lsg_a11y_control_name (LsgA11yControl control)
{
  (void)control;
  return "";
}
