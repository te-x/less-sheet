/*
 * lsg_jump.c — jump-to-row, in two layers:
 *
 *   1. A pure state machine that NEVER touches the core: parse and validate
 *      the entered 1-based row, decide run-vs-reject, fold the core's
 *      jump-scan poll into a monotone progress display, and decide
 *      land / cancel-restore / reject.
 *
 *   2. The jump bridge — the single place this frontend calls `ls_jump_*`,
 *      reaching the core handle through the private `struct _LsgDocument`
 *      seam. Lockless, like the search bridge: the core synchronizes it.
 *
 * The FRONTIER is the core's: the frontend owns no scanner.
 */
#include "lsg_document_internal.h"
#include <lsg_jump.h>

#include <lesssheet.h>

/* ------------------------------------------------------------------------- */
/* Pure view-model */
/* ------------------------------------------------------------------------- */

LsgJumpFlow
lsg_jump_initial (void)
{
  LsgJumpFlow f = { 0 };
  f.kind = LSG_JUMP_FLOW_IDLE;
  return f;
}

gboolean
lsg_jump_parse (const char *input, guint64 *out_target)
{
  if (input == NULL || input[0] == '\0')
    return FALSE; /* empty / NULL */

  guint64 v = 0;
  for (const char *p = input; *p != '\0'; p++)
    {
      if (*p < '0' || *p > '9')
        return FALSE; /* non-ASCII-digit (sign, space, dot, …) */
      guint digit = (guint)(*p - '0');
      /* Reject overflow past G_MAXUINT64 before it happens. */
      if (v > (G_MAXUINT64 - digit) / 10)
        return FALSE;
      v = v * 10 + digit;
    }

  if (v < 1)
    return FALSE; /* "0" / "00": 1-based rows start at 1 */

  *out_target = v - 1; /* 1-based UI -> 0-based data row */
  return TRUE;
}

LsgJumpSubmit
lsg_jump_submit (const char *input, LsgRowCount rowcount, gboolean filtered,
                 guint64 pre_jump_first_row)
{
  LsgJumpSubmit out = { 0 };
  guint64 target = 0;

  /* Invalid input -> upfront reject (no scan; the viewport is untouched). */
  if (!lsg_jump_parse (input, &target))
    {
      out.outcome = LSG_JUMP_REJECTED;
      out.flow.kind = LSG_JUMP_FLOW_REJECTED;
      out.flow.has_restore = FALSE;
      return out;
    }

  /* UNFILTERED + exact count + target at/beyond count -> out-of-range known
   * upfront, reject without a scan. Suppressed while filtered: the entered
   * number is an ORIGINAL row and `rowcount` reports the filtered m (a
   * different domain) — a filtered jump never rejects, it clamps to the last
   * match. */
  if (!filtered && rowcount.exact && target >= rowcount.count)
    {
      out.outcome = LSG_JUMP_REJECTED;
      out.flow.kind = LSG_JUMP_FLOW_REJECTED;
      out.flow.has_restore = FALSE;
      return out;
    }

  /* RUN: begin scanning toward the 0-based target. */
  out.outcome = LSG_JUMP_RUN;
  out.target = target;
  out.flow.kind = LSG_JUMP_FLOW_SCANNING;
  out.flow.target = target;
  out.flow.pre_jump_first_row = pre_jump_first_row;
  out.flow.progress = 0.0;
  return out;
}

LsgJumpFlow
lsg_jump_resolve (LsgJumpFlow flow, LsgJumpStatus status, gboolean filtered)
{
  /* Only an in-flight scan folds a poll; every other flow is stable. */
  if (flow.kind != LSG_JUMP_FLOW_SCANNING)
    return flow;

  if (status.state == LSG_JUMP_SCANNING)
    {
      /* Display progress never regresses on a stale poll. */
      if (status.progress > flow.progress)
        flow.progress = status.progress;
      return flow;
    }

  if (status.state == LSG_JUMP_DONE)
    {
      guint64 r = status.landed_row;

      /* UNFILTERED short land: the scan clamped at EOF, so the target was past
       * the last data row — reject and re-anchor rather than land on the
       * clamp. Suppressed while filtered, where `r` is a FILTERED index and
       * `flow.target` an ORIGINAL row: the two are not comparable, and a
       * filtered jump lands on the last match instead. */
      if (!filtered && r < flow.target)
        {
          LsgJumpFlow rej = { 0 };
          rej.kind = LSG_JUMP_FLOW_REJECTED;
          rej.has_restore = TRUE;
          rej.restore_first_row = flow.pre_jump_first_row;
          return rej;
        }

      LsgJumpFlow landed = { 0 };
      landed.kind = LSG_JUMP_FLOW_LANDED;
      landed.landed_row = r;
      return landed;
    }

  /* LSG_JUMP_IDLE: an idle poll never resets a live scan (cancel does that).
   */
  return flow;
}

LsgJumpFlow
lsg_jump_cancel (LsgJumpFlow flow)
{
  if (flow.kind != LSG_JUMP_FLOW_SCANNING)
    return flow; /* only a scanning flow cancels */

  LsgJumpFlow c = { 0 };
  c.kind = LSG_JUMP_FLOW_CANCELLED;
  c.restore_first_row = flow.pre_jump_first_row;
  return c;
}

/* ------------------------------------------------------------------------- */
/* Jump bridge */
/* ------------------------------------------------------------------------- */

void
lsg_document_jump_start (LsgDocument *doc, guint64 target_row)
{
  if (doc == NULL || doc->doc == NULL)
    return;
  ls_jump_start (doc->doc, target_row);
}

void
lsg_document_jump_cancel (LsgDocument *doc)
{
  if (doc == NULL || doc->doc == NULL)
    return;
  ls_jump_cancel (doc->doc);
}

LsgJumpStatus
lsg_document_jump_poll (const LsgDocument *doc)
{
  LsgJumpStatus out = { LSG_JUMP_IDLE, 0.0, 0 };
  if (doc == NULL || doc->doc == NULL)
    return out;

  ls_jump_status s = ls_jump_poll (doc->doc);
  switch (s.state)
    {
    case LS_JUMP_SCANNING:
      out.state = LSG_JUMP_SCANNING;
      break;
    case LS_JUMP_DONE:
      out.state = LSG_JUMP_DONE;
      break;
    default:
      out.state = LSG_JUMP_IDLE;
      break;
    }
  out.progress = s.progress;
  out.landed_row = s.landed_row;
  return out;
}
