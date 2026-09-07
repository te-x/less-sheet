/*
 * lsg_sort.c — sort-by-column, in two layers (see include/lsg_sort.h for the
 * pinned semantics of every function):
 *
 *   1. A pure view-model that NEVER touches the core: the three-state cycle
 *      (ascending -> descending -> off, with "stop" on an unlanded pass and
 *      "retry" on a failed one), the header indicator, and the accessible
 *      description. The cycle is the ONE decision behind a header click,
 *      Ctrl+Shift+S on the cursor's column, and the progress affordance's
 *      Cancel, so those three can never drift apart.
 *
 *   2. The sort bridge — the single place this frontend calls `ls_sort_set` /
 *      `ls_sort_clear` / `ls_sort_poll`. Lockless: the core synchronizes it,
 *      exactly like the filter bridge.
 *
 * A SORT IS A THIRD VIEW KIND: while one is active the core presents the
 * (filtered) rows in sort order and every existing accessor already speaks
 * those coordinates — so nothing about how a window is drawn changes here, and
 * the gutter keeps showing original source rows through the slice-1
 * `lsg_window_source_row`.
 */
#include "lsg_document_internal.h"
#include <lsg_sort.h>

#include <lesssheet.h>

/* ------------------------------------------------------------------------- */
/* Pure view-model */
/* ------------------------------------------------------------------------- */

LsgSortIntent
lsg_sort_next (LsgSortSnapshot snapshot, guint column)
{
  LsgSortIntent set = { LSG_SORT_INTENT_SET, column, LSG_SORT_ASCENDING };
  LsgSortIntent clear = { LSG_SORT_INTENT_CLEAR, 0, LSG_SORT_ASCENDING };

  /* Nothing sorted, or the user acted on a DIFFERENT column: start fresh
   * ascending, whatever the current phase and direction are. */
  if (snapshot.phase == LSG_SORT_PHASE_NONE || snapshot.column != column)
    return set;

  switch (snapshot.phase)
    {
    case LSG_SORT_PHASE_ACTIVE:
      /* The landed cycle: ascending -> descending -> off. */
      if (snapshot.direction == LSG_SORT_ASCENDING)
        {
          set.direction = LSG_SORT_DESCENDING;
          return set;
        }
      return clear;

    case LSG_SORT_PHASE_BUILDING:
    case LSG_SORT_PHASE_PARKED:
      /* Acting on a pass that has not landed means STOP — the same intent
       * Cancel issues, so the two affordances cannot drift apart. */
      return clear;

    case LSG_SORT_PHASE_FAILED:
      /* RETRY the same request rather than advancing: silently moving to a
       * direction the user never saw applied is the wrong answer to "that
       * didn't work", and the core re-runs the pass for an identical
       * request. */
      set.direction = snapshot.direction;
      return set;

    case LSG_SORT_PHASE_NONE:
    default:
      return set;
    }
}

/*
 * The header context menu (Amendment 3). Three entries in a fixed order,
 * carrying DIRECT intents — the same LsgSortIntent the cycle produces, so both
 * trigger paths funnel into one apply step and cannot interpret a request
 * differently. A menu shows state and names outcomes; it does not cycle.
 */
guint
lsg_sort_menu (LsgSortSnapshot snapshot, guint column,
               LsgSortMenuEntry *out_entries)
{
  if (out_entries == NULL)
    return 0;

  /* A sort is set on the DOCUMENT (any column, any phase but NONE) ... */
  const gboolean any_sort = (snapshot.phase != LSG_SORT_PHASE_NONE);
  /* ... and on THIS column. */
  const gboolean this_column = any_sort && snapshot.column == column;

  LsgSortIntent asc = { LSG_SORT_INTENT_SET, column, LSG_SORT_ASCENDING };
  LsgSortIntent desc = { LSG_SORT_INTENT_SET, column, LSG_SORT_DESCENDING };
  LsgSortIntent clear = { LSG_SORT_INTENT_CLEAR, 0, LSG_SORT_ASCENDING };

  out_entries[0].title = LSG_SORT_MENU_TITLE_ASC;
  out_entries[0].intent = asc;
  /* The check follows the REQUEST, not the phase — building, parked and failed
   * show it too, exactly as the indicator draws its chevron in those phases,
   * so the menu and the header can never disagree about what was asked for. */
  out_entries[0].checked
      = this_column && snapshot.direction == LSG_SORT_ASCENDING;
  out_entries[0].enabled = TRUE;

  out_entries[1].title = LSG_SORT_MENU_TITLE_DESC;
  out_entries[1].intent = desc;
  out_entries[1].checked
      = this_column && snapshot.direction == LSG_SORT_DESCENDING;
  out_entries[1].enabled = TRUE;

  out_entries[2].title = LSG_SORT_MENU_TITLE_CLEAR;
  out_entries[2].intent = clear;
  out_entries[2].checked = FALSE; /* never check-marked */
  /* Clearing is a DOCUMENT-level act: selectable from every header, so a user
   * who opens the wrong one can still undo the sort. */
  out_entries[2].enabled = any_sort;

  return (guint)LSG_SORT_MENU_ENTRIES;
}

LsgSortIndicator
lsg_sort_indicator (LsgSortSnapshot snapshot, guint column)
{
  LsgSortIndicator ind = { LSG_SORT_ASCENDING, FALSE, FALSE, FALSE };
  if (snapshot.phase == LSG_SORT_PHASE_NONE || snapshot.column != column)
    return ind;

  ind.sorted = TRUE;
  ind.direction = snapshot.direction;
  /* PENDING is not "unsorted": the grid already shows the exact sorted top of
   * what was scanned; the top is still refining, so the header must not claim
   * a settled order. */
  ind.pending = (snapshot.phase == LSG_SORT_PHASE_BUILDING
                 || snapshot.phase == LSG_SORT_PHASE_PARKED);
  ind.failed = (snapshot.phase == LSG_SORT_PHASE_FAILED);
  return ind;
}

char *
lsg_sort_describe (LsgSortSnapshot snapshot, const char *column_label)
{
  if (snapshot.phase == LSG_SORT_PHASE_NONE)
    return g_strdup ("not sorted");

  /* A labelless column falls back to the 1-BASED number the user sees. */
  char *label = (column_label != NULL && column_label[0] != '\0')
                    ? g_strdup (column_label)
                    : g_strdup_printf ("column %u", snapshot.column + 1u);
  const char *dir = (snapshot.direction == LSG_SORT_DESCENDING) ? "descending"
                                                                : "ascending";
  char *out;

  switch (snapshot.phase)
    {
    case LSG_SORT_PHASE_BUILDING:
    case LSG_SORT_PHASE_PARKED:
      out = g_strdup_printf ("sorting by %s, %s — %d%%", label, dir,
                             (int)(snapshot.progress * 100.0));
      break;
    case LSG_SORT_PHASE_FAILED:
      out = g_strdup_printf ("sorting by %s failed", label);
      break;
    case LSG_SORT_PHASE_ACTIVE:
    default:
      out = g_strdup_printf ("sorted by %s, %s", label, dir);
      break;
    }

  g_free (label);
  return out;
}

/* ------------------------------------------------------------------------- */
/* Sort bridge */
/* ------------------------------------------------------------------------- */

gboolean
lsg_document_sort_set (LsgDocument *doc, guint column,
                       LsgSortDirection direction)
{
  if (doc == NULL || doc->doc == NULL)
    return FALSE;
  ls_sort_direction dir = (direction == LSG_SORT_DESCENDING)
                              ? LS_SORT_DESCENDING
                              : LS_SORT_ASCENDING;
  return ls_sort_set (doc->doc, (uint32_t)column, dir) ? TRUE : FALSE;
}

void
lsg_document_sort_clear (LsgDocument *doc)
{
  if (doc == NULL || doc->doc == NULL)
    return;
  ls_sort_clear (doc->doc);
}

gboolean
lsg_document_sort_poll (const LsgDocument *doc, LsgSortSnapshot *out_snapshot)
{
  if (out_snapshot == NULL)
    return FALSE;

  LsgSortSnapshot out = { LSG_SORT_PHASE_NONE, LSG_SORT_ERROR_NONE, 0,
                          LSG_SORT_ASCENDING, 0.0 };
  if (doc == NULL || doc->doc == NULL)
    {
      *out_snapshot = out;
      return FALSE;
    }

  ls_sort_status s = ls_sort_poll (doc->doc);
  switch (s.state)
    {
    case LS_SORT_BUILDING:
      out.phase = LSG_SORT_PHASE_BUILDING;
      break;
    case LS_SORT_ACTIVE:
      out.phase = LSG_SORT_PHASE_ACTIVE;
      break;
    case LS_SORT_PARKED:
      out.phase = LSG_SORT_PHASE_PARKED;
      break;
    case LS_SORT_FAILED:
      out.phase = LSG_SORT_PHASE_FAILED;
      break;
    default: /* LS_SORT_IDLE -> no sort; the snapshot stays fully zeroed */
      *out_snapshot = out;
      return FALSE;
    }

  switch (s.error)
    {
    case LS_SORT_ERROR_STORAGE:
      out.error = LSG_SORT_ERROR_STORAGE;
      break;
    case LS_SORT_ERROR_MEMORY:
      out.error = LSG_SORT_ERROR_MEMORY;
      break;
    default:
      out.error = LSG_SORT_ERROR_NONE;
      break;
    }

  out.column = (guint)s.column;
  out.direction = (s.direction == LS_SORT_DESCENDING) ? LSG_SORT_DESCENDING
                                                      : LSG_SORT_ASCENDING;
  out.progress = s.progress;
  *out_snapshot = out;
  return TRUE;
}
