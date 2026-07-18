/*
 * lsg_find.c — RED SEED for the FIND module (lsg_find.h). Slice 2.
 *
 * This is a deliberately-incomplete STUB: every prototype is present so the
 * module compiles under -Werror (the CONFORMANCE gate) and every caller links,
 * but the pure view-model returns empty/unchanged values and the core bridge is
 * a no-op, so the behavior tests in tests/test_find.c are RED. The implementer
 * replaces these bodies:
 *   - the pure `lsg_find_*` transforms are a faithful C port of the macOS
 *     `FindControl` (Sources/LessSheetKit/FindLogic.swift) — pure, no core;
 *   - the `lsg_document_search_*` / `lsg_document_window_match_flags` bridge wires
 *     `ls_search_*` / `ls_window_match_flags` through the `LsgDocument` session.
 *     The core handle + window-lane lock live in `struct _LsgDocument` (private to
 *     lsg_document.c): expose them to this file by EXTENDING the non-frozen
 *     src/lsg_document_internal.h seam (an implementation detail — this seed does
 *     not need them).
 */
#include <lsg_find.h>

/* ------------------------------------------------------------------------- */
/* Shared vocabulary                                                          */
/* ------------------------------------------------------------------------- */

gboolean
lsg_search_op_is_ordering (LsgSearchOp op)
{
  (void) op;
  return FALSE; /* SEED: wrong for LT/GT/LE/GE */
}

LsgSearchNav
lsg_search_nav_from_top (void)
{
  LsgSearchNav nav = { 0, LSG_SEARCH_FORWARD };
  return nav;
}

LsgSearchNav
lsg_search_nav_from_end (void)
{
  LsgSearchNav nav = { G_MAXUINT64, LSG_SEARCH_BACKWARD };
  return nav;
}

/* ------------------------------------------------------------------------- */
/* Pure helpers                                                               */
/* ------------------------------------------------------------------------- */

gboolean
lsg_find_query_case_sensitive (const char *query)
{
  (void) query;
  return FALSE; /* SEED: never reports uppercase */
}

gboolean
lsg_numeric_is_numeric (const char *text)
{
  (void) text;
  return FALSE; /* SEED: rejects every value */
}

/* ------------------------------------------------------------------------- */
/* Pure view-model                                                            */
/* ------------------------------------------------------------------------- */

LsgFindSession
lsg_find_initial (void)
{
  LsgFindSession session = { 0 };
  session.draft.text = "";
  session.draft.value = "";
  return session;
}

LsgFindSubmit
lsg_find_submit (LsgFindSession session,
                 const guint32 *visible_columns, guint n_visible,
                 guint32 column_count)
{
  (void) session;
  (void) visible_columns;
  (void) n_visible;
  (void) column_count;
  LsgFindSubmit out = { 0 }; /* SEED: outcome LSG_FIND_RUN with an empty request */
  return out;
}

LsgFindSession
lsg_find_began (LsgFindSession session)
{
  return session; /* SEED: does not activate the display */
}

LsgFindSession
lsg_find_resolved (LsgFindSession session,
                   gboolean has_snapshot, LsgSearchSnapshot snapshot,
                   LsgSearchDir nav_direction)
{
  (void) has_snapshot;
  (void) snapshot;
  (void) nav_direction;
  return session; /* SEED: folds nothing */
}

gboolean
lsg_find_step (LsgFindSession session, LsgSearchDir direction,
               guint64 viewport_row, LsgSearchNav *out_nav)
{
  (void) session;
  (void) direction;
  (void) viewport_row;
  (void) out_nav;
  return FALSE; /* SEED: never navigates */
}

gboolean
lsg_find_wrap_nav (LsgFindSession session, LsgSearchNav *out_nav)
{
  (void) session;
  (void) out_nav;
  return FALSE; /* SEED: never wraps */
}

LsgFindSession
lsg_find_stopped (LsgFindSession session)
{
  return session; /* SEED: no STOPPED notice */
}

LsgFindSession
lsg_find_closed (LsgFindSession session)
{
  return session; /* SEED: does not clear the display */
}

LsgFindSession
lsg_find_invalidated (LsgFindSession session)
{
  return session; /* SEED: does not clear the display */
}

/* ------------------------------------------------------------------------- */
/* Core search bridge                                                         */
/* ------------------------------------------------------------------------- */

gboolean
lsg_document_search_start (LsgDocument *doc, LsgSearchRequest request)
{
  (void) doc;
  (void) request;
  return FALSE; /* SEED: starts no search */
}

void
lsg_document_search_nav (LsgDocument *doc, LsgSearchNav nav)
{
  (void) doc;
  (void) nav;
  /* SEED: no-op */
}

void
lsg_document_search_cancel (LsgDocument *doc)
{
  (void) doc;
  /* SEED: no-op */
}

gboolean
lsg_document_search_poll (const LsgDocument *doc, LsgSearchSnapshot *out)
{
  (void) doc;
  (void) out;
  return FALSE; /* SEED: always reports IDLE (no snapshot) */
}

LsgMatchFlags
lsg_document_window_match_flags (LsgDocument *doc,
                                 guint32 first_col, guint32 col_count)
{
  (void) doc;
  (void) first_col;
  (void) col_count;
  LsgMatchFlags flags = { 0 }; /* SEED: no highlights */
  return flags;
}
