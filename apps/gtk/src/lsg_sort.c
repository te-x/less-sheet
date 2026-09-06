/*
 * lsg_sort.c — SEED (planner-authored, implementer-owned file).
 *
 * The shape of the sort feature with none of its behavior, so the frozen
 * tests/test_sort.c COMPILES and fails on BEHAVIOR rather than on a missing
 * symbol (the same seeding pattern the earlier slices used).
 *
 * `lsg_sort_next` always answers CLEAR, `lsg_sort_indicator` always answers
 * "not sorted", `lsg_sort_describe` always answers "not sorted", and the
 * bridge does nothing / reports no sort — so every row of the pinned cycle
 * truth table, every indicator case, every description, and every bridge
 * assertion is RED until the real logic (specified in include/lsg_sort.h) is
 * written.
 */

#include <lsg_sort.h>

#include "lsg_document_internal.h"

LsgSortIntent
lsg_sort_next (LsgSortSnapshot snapshot, guint column)
{
  (void)snapshot;
  (void)column;
  LsgSortIntent intent = { LSG_SORT_INTENT_CLEAR, 0, LSG_SORT_ASCENDING };
  return intent;
}

LsgSortIndicator
lsg_sort_indicator (LsgSortSnapshot snapshot, guint column)
{
  (void)snapshot;
  (void)column;
  LsgSortIndicator ind = { LSG_SORT_ASCENDING, FALSE, FALSE, FALSE };
  return ind;
}

char *
lsg_sort_describe (LsgSortSnapshot snapshot, const char *column_label)
{
  (void)snapshot;
  (void)column_label;
  return g_strdup ("not sorted");
}

gboolean
lsg_document_sort_set (LsgDocument *doc, guint column,
                       LsgSortDirection direction)
{
  (void)column;
  (void)direction;
  if (doc == NULL || doc->doc == NULL)
    return FALSE;
  return FALSE;
}

void
lsg_document_sort_clear (LsgDocument *doc)
{
  (void)doc;
}

gboolean
lsg_document_sort_poll (const LsgDocument *doc, LsgSortSnapshot *out_snapshot)
{
  if (doc == NULL || doc->doc == NULL || out_snapshot == NULL)
    return FALSE;
  LsgSortSnapshot empty = { LSG_SORT_PHASE_NONE, LSG_SORT_ERROR_NONE, 0,
                            LSG_SORT_ASCENDING, 0.0 };
  *out_snapshot = empty;
  return FALSE;
}
