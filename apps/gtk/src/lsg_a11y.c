/*
 * lsg_a11y.c — the display-free ACCESSIBILITY logic for the GTK frontend (the
 * gtk-a11y slice, ARCH-gtk-a11y.md Decision 2). Pure arithmetic over plain
 * numbers and byte-exact UTF-8 string building — no widgets, no display
 * server, no GTK — so the gate verifies the behavior headlessly. src/main.c
 * routes its key events, announcements, labels and shortcuts surface through
 * here.
 *
 * See lsg_a11y.h for the pinned semantics of every function.
 */
#include "lsg_a11y.h"

#include <string.h>

/* 1. Cursor / selection reducer ------------------------------------------- */

/* Clamp one cell into [0, rows-1] x [0, cols-1]. Callers only invoke this with
 * a non-empty extent (rows > 0 && cols > 0). */
static LsgA11yCell
clamp_cell (LsgA11yCell c, LsgA11yExtent extent)
{
  if (c.row > extent.rows - 1)
    c.row = extent.rows - 1;
  if (c.col > extent.cols - 1)
    c.col = extent.cols - 1;
  return c;
}

LsgA11yCursorResult
lsg_a11y_cursor_apply (LsgA11yCursor current, LsgA11yExtent extent,
                       LsgA11yView view, LsgA11yCursorCommand command,
                       gboolean extend)
{
  LsgA11yCursorResult r = { current, FALSE, { 0, 0 } };

  /* Empty extent: every command is a no-op. */
  if (extent.rows == 0 || extent.cols == 0)
    return r;

  if (command == LSG_A11Y_CURSOR_CLEAR)
    {
      LsgA11yCursorResult clear
          = { { LSG_A11Y_SEL_NONE, { 0, 0 }, { 0, 0 } }, FALSE, { 0, 0 } };
      return clear;
    }

  if (command == LSG_A11Y_CURSOR_SELECT_ALL)
    {
      r.cursor.mode = LSG_A11Y_SEL_CELLS;
      r.cursor.anchor.row = 0;
      r.cursor.anchor.col = 0;
      r.cursor.active.row = extent.rows - 1;
      r.cursor.active.col = extent.cols - 1;
      r.should_reveal = FALSE;
      return r;
    }

  /* First directional/page/home/end press from NONE: seed at the top-left
   * visible cell, no directional step applied. */
  if (current.mode == LSG_A11Y_SEL_NONE)
    {
      LsgA11yCell seed = { view.first_row, view.first_col };
      seed = clamp_cell (seed, extent);
      r.cursor.mode = LSG_A11Y_SEL_CELLS;
      r.cursor.anchor = seed;
      r.cursor.active = seed;
      r.should_reveal = TRUE;
      r.reveal = seed;
      return r;
    }

  /* Live cursor: step the active corner from current.active. */
  guint32 page = view.page_rows ? view.page_rows : 1;
  LsgA11yCell stepped = current.active;

  switch (command)
    {
    case LSG_A11Y_CURSOR_UP:
      if (stepped.row > 0)
        stepped.row -= 1;
      break;
    case LSG_A11Y_CURSOR_DOWN:
      stepped.row += 1;
      break;
    case LSG_A11Y_CURSOR_LEFT:
      if (stepped.col > 0)
        stepped.col -= 1;
      break;
    case LSG_A11Y_CURSOR_RIGHT:
      stepped.col += 1;
      break;
    case LSG_A11Y_CURSOR_PAGE_UP:
      stepped.row = (stepped.row > page) ? stepped.row - page : 0;
      break;
    case LSG_A11Y_CURSOR_PAGE_DOWN:
      stepped.row += page;
      break;
    case LSG_A11Y_CURSOR_HOME:
      stepped.row = 0;
      break;
    case LSG_A11Y_CURSOR_END:
      stepped.row = extent.rows - 1;
      break;
    default:
      break;
    }

  stepped = clamp_cell (stepped, extent);

  r.cursor.mode = LSG_A11Y_SEL_CELLS;
  r.cursor.active = stepped;
  if (extend)
    r.cursor.anchor = clamp_cell (current.anchor, extent);
  else
    r.cursor.anchor = stepped;
  r.should_reveal = TRUE;
  r.reveal = stepped;
  return r;
}

/* 2. Announcement + description string builders --------------------------- */

char *
lsg_a11y_announce_cursor (guint64 row, const char *column, const char *value)
{
  const char *col = column ? column : "";
  const char *val = value ? value : "";

  GString *s = g_string_new (NULL);
  g_string_append_printf (s, "Row %" G_GUINT64_FORMAT ", %s: ", row, col);

  glong nchars = g_utf8_strlen (val, -1);
  if (nchars > LSG_A11Y_VALUE_CLIP_CHARS)
    {
      const char *end
          = g_utf8_offset_to_pointer (val, LSG_A11Y_VALUE_CLIP_CHARS);
      g_string_append_len (s, val, end - val);
      g_string_append (s, "\xE2\x80\xA6"); /* U+2026 … */
    }
  else
    {
      g_string_append (s, val);
    }

  return g_string_free (s, FALSE);
}

char *
lsg_a11y_announce_selection (guint64 rows, guint cols)
{
  /* U+00D7 MULTIPLICATION SIGN as the separator. */
  return g_strdup_printf (
      "%" G_GUINT64_FORMAT " rows \xC3\x97 %u columns selected", rows, cols);
}

char *
lsg_a11y_announce_find_landing (guint64 n, guint64 m, guint64 row)
{
  return g_strdup_printf ("Match %" G_GUINT64_FORMAT " of %" G_GUINT64_FORMAT
                          ", row %" G_GUINT64_FORMAT,
                          n, m, row);
}

char *
lsg_a11y_grid_description (const char *name, guint cols, guint64 rows,
                           gboolean estimated, guint64 first, guint64 last,
                           gboolean filtered)
{
  GString *s = g_string_new (name ? name : "");
  g_string_append_printf (s, ", %u columns, ", cols);
  if (estimated)
    g_string_append_c (s, '~');
  g_string_append_printf (s, "%" G_GUINT64_FORMAT " rows", rows);
  if (rows > 0)
    g_string_append_printf (
        s, ", showing rows %" G_GUINT64_FORMAT " to %" G_GUINT64_FORMAT, first,
        last);
  if (filtered)
    g_string_append (s, ", filtered");
  return g_string_free (s, FALSE);
}

/* 3. The single accelerator / shortcuts table ----------------------------- */

const LsgA11yShortcut *
lsg_a11y_shortcuts (guint *out_n)
{
  /* THE single source of truth. Each command appears exactly once; SCOPE_APP
   * entries (and only those) carry a GAction name for
   * gtk_application_set_accels_for_action. SCOPE_GRID (Copy / Select-All) live
   * on the grid's own GtkShortcutController so they never hijack a focused
   * GtkText; SCOPE_DISPLAY entries are shown in the surface but handled by the
   * find popover / grid key controller (no accelerator registered anywhere).
   */
  static const LsgA11yShortcut table[] = {
    /* --- General --------------------------------------------------------- */
    { LSG_A11Y_CMD_OPEN, LSG_A11Y_GROUP_GENERAL, LSG_A11Y_SCOPE_APP,
      "Open File", "app.open", "<Control>o", NULL },
    { LSG_A11Y_CMD_OPEN_URL, LSG_A11Y_GROUP_GENERAL, LSG_A11Y_SCOPE_APP,
      "Open URL", "app.open-url", "<Control><Shift>o", NULL },
    { LSG_A11Y_CMD_PREFERENCES, LSG_A11Y_GROUP_GENERAL, LSG_A11Y_SCOPE_APP,
      "Preferences", "app.preferences", "<Control>comma", NULL },
    { LSG_A11Y_CMD_SHORTCUTS, LSG_A11Y_GROUP_GENERAL, LSG_A11Y_SCOPE_APP,
      "Keyboard Shortcuts", "app.shortcuts", "<Control>question",
      "<Control>F1" },
    /* --- Find ------------------------------------------------------------ */
    { LSG_A11Y_CMD_FIND, LSG_A11Y_GROUP_FIND, LSG_A11Y_SCOPE_APP, "Find",
      "app.find", "<Control>f", NULL },
    { LSG_A11Y_CMD_FIND_NEXT, LSG_A11Y_GROUP_FIND, LSG_A11Y_SCOPE_DISPLAY,
      "Next match", NULL, "Return", NULL },
    { LSG_A11Y_CMD_FIND_PREV, LSG_A11Y_GROUP_FIND, LSG_A11Y_SCOPE_DISPLAY,
      "Previous match", NULL, "<Shift>Return", NULL },
    { LSG_A11Y_CMD_ESCAPE, LSG_A11Y_GROUP_FIND, LSG_A11Y_SCOPE_DISPLAY,
      "Dismiss or clear selection", NULL, "Escape", NULL },
    /* --- Navigation ------------------------------------------------------ */
    { LSG_A11Y_CMD_JUMP, LSG_A11Y_GROUP_NAVIGATION, LSG_A11Y_SCOPE_APP,
      "Jump to row", "app.jump", "<Control>g", "<Control>l" },
    { LSG_A11Y_CMD_MOVE, LSG_A11Y_GROUP_NAVIGATION, LSG_A11Y_SCOPE_DISPLAY,
      "Move cursor", NULL, "Up Down Left Right", NULL },
    { LSG_A11Y_CMD_PAGE, LSG_A11Y_GROUP_NAVIGATION, LSG_A11Y_SCOPE_DISPLAY,
      "Page up or down", NULL, "Page_Up Page_Down", NULL },
    { LSG_A11Y_CMD_HOME_END, LSG_A11Y_GROUP_NAVIGATION, LSG_A11Y_SCOPE_DISPLAY,
      "First or last row", NULL, "Home End", NULL },
    { LSG_A11Y_CMD_DIGIT_JUMP, LSG_A11Y_GROUP_NAVIGATION,
      LSG_A11Y_SCOPE_DISPLAY, "Type a number to jump to a row", NULL, "0...9",
      NULL },
    /* --- Selection ------------------------------------------------------- */
    { LSG_A11Y_CMD_EXTEND, LSG_A11Y_GROUP_SELECTION, LSG_A11Y_SCOPE_DISPLAY,
      "Extend selection", NULL,
      "<Shift>Up <Shift>Down <Shift>Left <Shift>Right", NULL },
    { LSG_A11Y_CMD_SELECT_ALL, LSG_A11Y_GROUP_SELECTION, LSG_A11Y_SCOPE_GRID,
      "Select all", NULL, "<Control>a", NULL },
    { LSG_A11Y_CMD_COPY, LSG_A11Y_GROUP_SELECTION, LSG_A11Y_SCOPE_GRID, "Copy",
      NULL, "<Control>c", NULL },
  };

  if (out_n != NULL)
    *out_n = (guint)(sizeof (table) / sizeof (table[0]));
  return table;
}

/* 4. Accessible names for the bare interactive controls ------------------- */

const char *
lsg_a11y_control_name (LsgA11yControl control)
{
  static const char *const names[] = {
    [LSG_A11Y_CONTROL_OPEN_FILE] = "Open File",
    [LSG_A11Y_CONTROL_OPEN_URL] = "Open URL",
    [LSG_A11Y_CONTROL_FIND] = "Find",
    [LSG_A11Y_CONTROL_FIND_PREV] = "Previous match",
    [LSG_A11Y_CONTROL_FIND_NEXT] = "Next match",
    [LSG_A11Y_CONTROL_SEARCH_ENTRY] = "Find text",
    [LSG_A11Y_CONTROL_JUMP] = "Jump to row",
    [LSG_A11Y_CONTROL_HEADER_TOGGLE] = "First row is a header",
    [LSG_A11Y_CONTROL_SEPARATOR] = "Field separator",
    [LSG_A11Y_CONTROL_QUOTE] = "Quote character",
    [LSG_A11Y_CONTROL_CLEAR_FILTER] = "Clear filter",
    [LSG_A11Y_CONTROL_MENU] = "Main menu",
  };

  if ((guint)control >= (guint)LSG_A11Y_CONTROL_N)
    return "";
  return names[control];
}
