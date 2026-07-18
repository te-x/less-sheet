/*
 * lsg_filter.c — the GTK frontend's FILTER-TO-MATCHES feature (lsg_filter.h).
 * Slice 4. Two layers, mirroring the macOS split:
 *
 *   1. The PURE filter view-model — a C port of the macOS `FilterControl`
 *      (FilterLogic.swift) TOGETHER WITH the toggle app-state macOS keeps in
 *      `ViewerModel` (`filterSnapshot` / `isFiltered` / `filterDocumentRows` /
 *      `jumpRowCountInfo`, and the apply/clear transitions). A plain-value state
 *      machine that NEVER touches the core: it captures the base document
 *      row-count M at apply (a RE-APPLY keeps the ORIGINAL M), folds the async
 *      filter-scan poll into the "Filtered — N of M rows" banner, and derives the
 *      two composition facts the widget needs (the jump row-count hint + the
 *      `filtered` flag).
 *
 *   2. The FILTER BRIDGE — a C port of the `CoreDocumentSession` filter methods
 *      (`setFilter` / `clearFilter` / `filterStatus`): the single place this
 *      frontend calls `ls_filter_*`. It reaches the core handle through the
 *      non-frozen `struct _LsgDocument` seam and marshals the shared
 *      `LsgSearchRequest` into an `ls_search_request` exactly as the find bridge
 *      does. Poll/control-lane — lockless (the core is internally synchronized).
 *
 * A FILTER IS AN IN-PLACE VIEW MODE: while active the core presents ONLY the
 * matching rows in filtered coordinates, and every frozen slice-1 accessor
 * (window, cell, source-row gutter, row-count) already operates in them — so
 * this module changes NOTHING about how a window is drawn.
 */
#include <lsg_filter.h>
#include "lsg_document_internal.h"

#include <lesssheet.h>
#include <string.h>

/* ------------------------------------------------------------------------- */
/* Pure view-model (port of FilterControl + the macOS toggle state)           */
/* ------------------------------------------------------------------------- */

LsgFilterState
lsg_filter_initial (void)
{
  LsgFilterState s = { 0 };
  s.active = FALSE;
  return s;
}

LsgFilterState
lsg_filter_applied (LsgFilterState state, LsgRowCount document_rows,
                    LsgFilterSnapshot snapshot)
{
  /* First apply: capture the base M. Re-apply (already filtered): the passed
   * count is the filtered m (base no longer knowable through the session) — keep
   * the ORIGINAL M (mirrors macOS `isFiltered ? filterDocumentRows : rowCountInfo`). */
  if (!state.active)
    state.document_rows = document_rows;
  state.active = TRUE;
  state.snapshot = snapshot;              /* the fresh post-set poll */
  return state;
}

LsgFilterState
lsg_filter_cleared (LsgFilterState state)
{
  if (!state.active)
    return state;                         /* no-op: already the identity view */
  return lsg_filter_initial ();
}

LsgFilterState
lsg_filter_resolved (LsgFilterState state,
                     gboolean has_snapshot, LsgFilterSnapshot snapshot)
{
  if (!state.active)
    return state;                         /* identity view: no filter to fold */
  if (!has_snapshot)
    return state;                         /* nil poll: filtered MODE persists */
  /* The core guarantees total monotone + total_exact latched, so a plain
   * replace is correct (document_rows unchanged). */
  state.snapshot = snapshot;
  return state;
}

gboolean
lsg_filter_banner (LsgFilterState state, LsgFilterBanner *out_banner)
{
  if (!state.active || out_banner == NULL)
    return FALSE;                         /* no banner in the identity view */

  LsgFilterBanner b = { 0 };
  b.matching = state.snapshot.total;
  b.document_rows = state.document_rows.count;
  b.document_rows_estimated = !state.document_rows.exact;

  switch (state.snapshot.phase)
    {
    case LSG_FILTER_PHASE_SCANNING:
      b.matching_is_final = FALSE;
      b.has_progress = TRUE;
      b.progress = state.snapshot.progress;
      break;
    case LSG_FILTER_PHASE_DONE:
      b.matching_is_final = TRUE;
      b.has_progress = FALSE;
      b.progress = 0.0;
      break;
    case LSG_FILTER_PHASE_CANCELLED:
      /* Paused on scan-slot contention; the filter MODE persists, so keep the
       * frozen progress and stay non-final. */
      b.matching_is_final = FALSE;
      b.has_progress = TRUE;
      b.progress = state.snapshot.progress;
      break;
    }

  b.is_empty_result = (b.matching_is_final && b.matching == 0);
  *out_banner = b;
  return TRUE;
}

LsgRowCount
lsg_filter_jump_rowcount (LsgFilterState state, LsgRowCount identity_rowcount)
{
  /* While filtered the jump box takes ORIGINAL row numbers, so it hints with the
   * captured base document count M, not the filtered m. */
  return state.active ? state.document_rows : identity_rowcount;
}

/* ------------------------------------------------------------------------- */
/* Filter bridge (port of CoreDocumentSession filter methods)                 */
/* ------------------------------------------------------------------------- */

gboolean
lsg_document_filter_set (LsgDocument *doc, LsgSearchRequest request)
{
  if (doc == NULL || doc->doc == NULL)
    return FALSE;
  /* The shared marshaler (lsg_document_internal.h) — identical to the find
   * bridge's, so the grammar/validation shape can never drift between them. */
  ls_search_request req = lsg_build_abi_request (request);
  return ls_filter_set (doc->doc, &req) ? TRUE : FALSE;
}

void
lsg_document_filter_clear (LsgDocument *doc)
{
  if (doc == NULL || doc->doc == NULL)
    return;
  ls_filter_clear (doc->doc);
}

gboolean
lsg_document_filter_poll (const LsgDocument *doc, LsgFilterSnapshot *out)
{
  if (doc == NULL || doc->doc == NULL || out == NULL)
    return FALSE;

  ls_filter_status s = ls_filter_poll (doc->doc);

  LsgFilterPhase phase;
  switch (s.state)
    {
    case LS_FILTER_SCANNING:  phase = LSG_FILTER_PHASE_SCANNING;  break;
    case LS_FILTER_DONE:      phase = LSG_FILTER_PHASE_DONE;      break;
    case LS_FILTER_CANCELLED: phase = LSG_FILTER_PHASE_CANCELLED; break;
    default:                  return FALSE;   /* LS_FILTER_IDLE -> no snapshot */
    }

  out->phase = phase;
  out->progress = s.progress;
  out->total = s.total;
  out->total_exact = s.total_exact;
  return TRUE;
}
