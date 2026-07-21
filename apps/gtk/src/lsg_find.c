/*
 * lsg_find.c — the GTK frontend's FIND feature (lsg_find.h). Slice 2. Two
 * layers, mirroring the macOS split:
 *
 *   1. The PURE find view-model — a faithful C port of the macOS `FindControl`
 *      (Sources/LessSheetKit/FindLogic.swift): a plain-value state machine
 * that NEVER touches the core. It composes a request from the draft, folds
 *      search polls into the display (growing→final count, landings), and
 *      decides wrap / no-matches / stopped notices and next/prev anchors.
 *      Swift optionals are flattened to `has_*` gates.
 *
 *   2. The SEARCH BRIDGE — a C port of the `CoreDocumentSession` search
 * methods
 *      (`startSearch` / `navigateSearch` / `cancelSearch` / `searchStatus` /
 *      `windowMatchFlags`): the single place this frontend calls `ls_search_*`
 * / `ls_window_match_flags`. It reaches the core handle + window-lane lock
 *      through the non-frozen `struct _LsgDocument` seam. Search start/nav/
 *      cancel/poll are poll/control-lane (lockless — the core is internally
 *      synchronized); window-match-flags is window-lane (takes `window_lock`)
 *      and copies the borrowed mask out immediately (the copy-out discipline).
 *
 * The frontend owns NO matcher: every per-cell verdict comes from the core.
 */
#include "lsg_document_internal.h"
#include <lsg_find.h>

#include <lesssheet.h>
#include <string.h>

/* ------------------------------------------------------------------------- */
/* Shared vocabulary */
/* ------------------------------------------------------------------------- */

gboolean
lsg_search_op_is_ordering (LsgSearchOp op)
{
  return op == LSG_SEARCH_OP_LT || op == LSG_SEARCH_OP_GT
         || op == LSG_SEARCH_OP_LE || op == LSG_SEARCH_OP_GE;
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
/* Pure helpers */
/* ------------------------------------------------------------------------- */

/* The pinned numeric grammar (verbatim the ABI HEADER RULE / macOS
 * NumericGrammar): sign? ( digits ('.' digits?)? | '.' digits ) (e sign?
 * digits)? over ASCII, after trimming ASCII whitespace (0x09..0x0D, 0x20). */
gboolean
lsg_numeric_is_numeric (const char *text)
{
  if (text == NULL)
    return FALSE;

  const char *p = text;
  const char *e = text + strlen (text);
  while (p < e && (*p == ' ' || (*p >= 0x09 && *p <= 0x0D)))
    p++;
  while (e > p && (*(e - 1) == ' ' || (*(e - 1) >= 0x09 && *(e - 1) <= 0x0D)))
    e--;
  if (p == e)
    return FALSE;

  if (*p == '+' || *p == '-')
    p++;

  gboolean int_digits = FALSE, frac_digits = FALSE;
  while (p < e && *p >= '0' && *p <= '9')
    {
      p++;
      int_digits = TRUE;
    }
  if (p < e && *p == '.')
    {
      p++;
      while (p < e && *p >= '0' && *p <= '9')
        {
          p++;
          frac_digits = TRUE;
        }
    }
  if (!int_digits && !frac_digits)
    return FALSE; /* "." / "+." / "" */

  if (p < e && (*p == 'e' || *p == 'E'))
    {
      p++;
      if (p < e && (*p == '+' || *p == '-'))
        p++;
      const char *es = p;
      while (p < e && *p >= '0' && *p <= '9')
        p++;
      if (p == es)
        return FALSE; /* exponent needs a digit ("1e", "1.5e") */
    }

  return p == e; /* no trailing garbage */
}

/* ------------------------------------------------------------------------- */
/* Pure view-model (port of FindControl) */
/* ------------------------------------------------------------------------- */

LsgFindSession
lsg_find_initial (void)
{
  LsgFindSession session = { 0 };
  session.draft.mode = LSG_FIND_TEXT;
  session.draft.text = "";
  session.draft.value = "";
  session.draft.column = 0;
  session.draft.op = LSG_SEARCH_OP_EQ;
  /* display is all-zero: inactive, no current, total 0, not final, no
   * progress, no notice. */
  return session;
}

LsgFindSubmit
lsg_find_submit (LsgFindSession session, const guint32 *visible_columns,
                 guint n_visible, guint32 column_count)
{
  LsgFindSubmit out = { 0 };
  LsgFindDraft draft = session.draft;

  if (draft.mode == LSG_FIND_TEXT)
    {
      /* The empty query means "no search" — ignored, never an error. */
      if (draft.text == NULL || draft.text[0] == '\0')
        {
          out.outcome = LSG_FIND_IGNORED;
          return out;
        }
      out.outcome = LSG_FIND_RUN;
      out.request.kind = LSG_FIND_TEXT;
      out.request.value = draft.text;
      /* The "Match case" checkbox marshals 1:1 into the request: one
       * session bool shared by both modes, NEVER derived from the query
       * (smart case is retired). */
      out.request.case_sensitive = draft.case_sensitive;
      /* scope NULL iff every column is visible; else the visible set is fixed
       * into the request (borrowed; the core treats it as a set). */
      if (n_visible == column_count)
        {
          out.request.scope = NULL;
          out.request.scope_len = 0;
        }
      else
        {
          out.request.scope = visible_columns;
          out.request.scope_len = n_visible;
        }
      return out;
    }

  /* PREDICATE. A column outside the document rejects (blink + shake) before
   * any core call; a hidden column is a legal target. */
  if (draft.column >= column_count)
    {
      out.outcome = LSG_FIND_REJECTED;
      return out;
    }
  /* Ordering operators need a numeric value (the empty value fails too); = /
   * != accept ANY value (the empty one matches empty cells). */
  if (lsg_search_op_is_ordering (draft.op)
      && !lsg_numeric_is_numeric (draft.value))
    {
      out.outcome = LSG_FIND_REJECTED;
      return out;
    }
  out.outcome = LSG_FIND_RUN;
  out.request.kind = LSG_FIND_PREDICATE;
  out.request.column = draft.column;
  out.request.op = draft.op;
  out.request.value = (draft.value != NULL) ? draft.value : "";
  /* Same session bool as TEXT — governs EQ/NE folding; ordering ops ignore it.
   */
  out.request.case_sensitive = draft.case_sensitive;
  return out;
}

LsgFindSession
lsg_find_began (LsgFindSession session)
{
  /* The draft is unchanged; the display becomes active with a fresh count. */
  LsgFindDisplay d = { 0 };
  d.active = TRUE;
  d.has_progress = TRUE;
  d.progress = 0.0;
  session.display = d;
  return session;
}

LsgFindSession
lsg_find_resolved (LsgFindSession session, gboolean has_snapshot,
                   LsgSearchSnapshot snapshot, LsgSearchDir nav_direction)
{
  /* A nil (idle) poll, or a session with no active search, never resurrects or
   * resets a display. */
  if (!has_snapshot || !session.display.active)
    return session;

  LsgFindDisplay old = session.display;
  LsgFindDisplay d = old;

  /* Count: MAX-fold (never regress on a stale poll); total_final latches. */
  d.total = MAX (old.total, snapshot.total);
  d.total_final = old.total_final || snapshot.total_exact;

  /* Progress: MAX-fold while scanning; the % display ends on done/cancelled.
   */
  if (snapshot.phase == LSG_SEARCH_PHASE_SCANNING)
    {
      d.has_progress = TRUE;
      d.progress
          = MAX (old.has_progress ? old.progress : 0.0, snapshot.progress);
    }
  else
    {
      d.has_progress = FALSE;
      d.progress = 0.0;
    }

  /* Landing: a FOUND nav sets current + its exact position; kept on non-found
   * polls (the old landing holds until the next lands). */
  if (snapshot.nav == LSG_SEARCH_NAV_FOUND)
    {
      d.has_current = TRUE;
      d.current = snapshot.found;
      d.position = snapshot.position;
    }

  /* Notice derives PURELY from this snapshot (so a wrap notice self-clears
   * when the wrap navigation lands as a FOUND poll). A CANCELLED phase from a
   * POLL is NEVER "Stopped": on a network (http_range) document the core lands
   * the first match AND RE-PARKS the scan at CANCELLED in the SAME poll by
   * design (nfd_ac6), so mapping CANCELLED -> STOPPED here would mask the real
   * "N of M" count. The STOPPED notice belongs ONLY to an explicit user Stop
   * (`lsg_find_stopped`); the net-park outcome is pinned by
   * /find/resolved-net-park-landing. */
  d.notice = LSG_FIND_NOTICE_NONE;
  if (snapshot.nav == LSG_SEARCH_NAV_EXHAUSTED)
    {
      if (snapshot.total == 0 && snapshot.total_exact)
        {
          /* Zero matches anywhere (scan complete): "No matches", landing
           * clear. */
          d.notice = LSG_FIND_NOTICE_NO_MATCHES;
          d.has_current = FALSE;
          d.position = 0;
        }
      else
        {
          /* Exhausted a direction with matches known (or still scanning):
           * wrap, keeping the current landing until the wrap lands. */
          d.notice = (nav_direction == LSG_SEARCH_FORWARD)
                         ? LSG_FIND_NOTICE_WRAPPED_TO_START
                         : LSG_FIND_NOTICE_WRAPPED_TO_END;
        }
    }

  session.display = d;
  return session;
}

gboolean
lsg_find_step (LsgFindSession session, LsgSearchDir direction,
               guint64 viewport_row, LsgSearchNav *out_nav)
{
  if (!session.display.active)
    return FALSE;

  if (!session.display.has_current)
    {
      /* No landing yet: navigate relative to what the user sees. */
      out_nav->anchor = viewport_row;
      out_nav->direction = direction;
      return TRUE;
    }

  if (direction == LSG_SEARCH_FORWARD)
    {
      /* next = first match at-or-after current.row + 1 (saturating). */
      guint64 r = session.display.current.row;
      out_nav->anchor = (r == G_MAXUINT64) ? G_MAXUINT64 : r + 1;
      out_nav->direction = LSG_SEARCH_FORWARD;
    }
  else
    {
      /* previous = last match STRICTLY before current.row (no decrement;
       * previous-from-row-0 exhausts core-side into the wrap). */
      out_nav->anchor = session.display.current.row;
      out_nav->direction = LSG_SEARCH_BACKWARD;
    }
  return TRUE;
}

gboolean
lsg_find_wrap_nav (LsgFindSession session, LsgSearchNav *out_nav)
{
  switch (session.display.notice)
    {
    case LSG_FIND_NOTICE_WRAPPED_TO_START:
      *out_nav = lsg_search_nav_from_top ();
      return TRUE;
    case LSG_FIND_NOTICE_WRAPPED_TO_END:
      *out_nav = lsg_search_nav_from_end ();
      return TRUE;
    default:
      return FALSE;
    }
}

LsgFindSession
lsg_find_stopped (LsgFindSession session)
{
  /* Keep everything known so far; end the progress UI; state "Stopped". */
  if (!session.display.active)
    return session;
  session.display.has_progress = FALSE;
  session.display.progress = 0.0;
  session.display.notice = LSG_FIND_NOTICE_STOPPED;
  return session;
}

LsgFindSession
lsg_find_closed (LsgFindSession session)
{
  /* Esc: highlights off, counts gone — the DRAFT is retained (re-run is one
   * Enter). */
  LsgFindDisplay empty = { 0 };
  session.display = empty;
  return session;
}

LsgFindSession
lsg_find_invalidated (LsgFindSession session)
{
  /* Dialect re-open / new document identity clears results exactly like Esc.
   */
  return lsg_find_closed (session);
}

/* ------------------------------------------------------------------------- */
/* Search bridge (port of CoreDocumentSession search methods) */
/* ------------------------------------------------------------------------- */

gboolean
lsg_document_search_start (LsgDocument *doc, LsgSearchRequest request)
{
  if (doc == NULL || doc->doc == NULL)
    return FALSE;
  /* The shared marshaler (lsg_document_internal.h) — the SAME one the filter
   * bridge uses, so they can never drift. */
  ls_search_request req = lsg_build_abi_request (request);
  return ls_search_start (doc->doc, &req) ? TRUE : FALSE;
}

void
lsg_document_search_nav (LsgDocument *doc, LsgSearchNav nav)
{
  if (doc == NULL || doc->doc == NULL)
    return;
  /* Plain non-blocking nav (LsgSearchDir is pinned to ls_search_dir). The
   * result is observed by polling — synchronously on the caller's next poll
   * unfiltered, or over the ~100 ms tick loop (find_poll_fold) when the core
   * has a transient under-a-filter nav lag. NEVER blocks the UI thread. */
  ls_search_nav (doc->doc, nav.anchor, (ls_search_dir)nav.direction);
}

void
lsg_document_search_cancel (LsgDocument *doc)
{
  if (doc == NULL || doc->doc == NULL)
    return;
  ls_search_cancel (doc->doc);
}

gboolean
lsg_document_search_poll (const LsgDocument *doc, LsgSearchSnapshot *out)
{
  if (doc == NULL || doc->doc == NULL || out == NULL)
    return FALSE;

  ls_search_status s = ls_search_poll (doc->doc);

  LsgSearchPhase phase;
  switch (s.state)
    {
    case LS_SEARCH_SCANNING:
      phase = LSG_SEARCH_PHASE_SCANNING;
      break;
    case LS_SEARCH_DONE:
      phase = LSG_SEARCH_PHASE_DONE;
      break;
    case LS_SEARCH_CANCELLED:
      phase = LSG_SEARCH_PHASE_CANCELLED;
      break;
    default:
      return FALSE; /* LS_SEARCH_IDLE -> no snapshot */
    }

  LsgSearchNavState nav;
  switch (s.nav)
    {
    case LS_SEARCH_NAV_SEARCHING:
      nav = LSG_SEARCH_NAV_SEARCHING;
      break;
    case LS_SEARCH_NAV_FOUND:
      nav = LSG_SEARCH_NAV_FOUND;
      break;
    case LS_SEARCH_NAV_EXHAUSTED:
      nav = LSG_SEARCH_NAV_EXHAUSTED;
      break;
    default:
      nav = LSG_SEARCH_NAV_NONE;
      break;
    }

  out->phase = phase;
  out->nav = nav;
  out->progress = s.progress;
  out->found.row = s.found_row;
  out->found.column = s.found_col;
  out->position = s.position;
  out->total = s.total;
  out->total_exact = s.total_exact;
  return TRUE;
}

LsgMatchFlags
lsg_document_window_match_flags (LsgDocument *doc, guint32 first_col,
                                 guint32 col_count)
{
  LsgMatchFlags out = { NULL, 0, 0 };
  if (doc == NULL || doc->doc == NULL || col_count == 0)
    return out;

  /* Window lane: serialize with set_window / cell reads, then copy the
   * borrowed mask out immediately (never held past the next set_window /
   * close). */
  g_mutex_lock (doc->window_lock);
  ls_str flags = ls_window_match_flags (doc->doc, first_col, col_count);
  if (flags.len > 0 && flags.ptr != NULL)
    {
      out.cols = col_count;
      out.rows = (guint32)(flags.len / col_count);
      out.flags = g_malloc (flags.len);
      memcpy (out.flags, flags.ptr, flags.len);
    }
  g_mutex_unlock (doc->window_lock);
  return out;
}
