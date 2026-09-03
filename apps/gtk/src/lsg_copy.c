/*
 * lsg_copy.c — streaming TSV copy, in two layers:
 *
 *   1. A pure state machine that NEVER touches the core, threads, or I/O: it
 *      folds each core copy STEP into progress and an outcome — MORE
 *      accumulation, the frontend byte-budget cut, the core's cell-cap, the
 *      STALLED -> advance -> resume orchestration with its no-progress guard,
 *      and an explicit user cancel.
 *
 *   2. The copy bridge — the single place this frontend calls `ls_copy_*`.
 *      Every one of those calls is serialized against `ls_close` through the
 *      session's `control_lock` (the CLOSE-GUARD) and re-checks the core
 *      handle under it. Leaf before root — a job must not outlive its document
 *      — is the caller's rule to keep.
 */
#include "lsg_document_internal.h"
#include <lsg_copy.h>

#include <lesssheet.h>

/* ------------------------------------------------------------------------- */
/* Pure view-model */
/* ------------------------------------------------------------------------- */

LsgCopyFlow
lsg_copy_begin (LsgCopyRect rect, guint64 budget_bytes)
{
  LsgCopyFlow f = { 0 };
  f.kind = LSG_COPY_FLOW_STREAMING;
  f.row_count
      = rect.row_count; /* progress denominator (0 for an empty rect) */
  f.budget_bytes = budget_bytes; /* 0 = no frontend byte cap */
  return f;
}

LsgCopyFlow
lsg_copy_fold (LsgCopyFlow flow, LsgCopyStep step)
{
  /* Only an in-flight flow folds a step; a terminal DONE is stable (a stale
   * step never resurrects it). */
  if (flow.kind == LSG_COPY_FLOW_DONE)
    return flow;

  /* Accumulate: rows_done MAX-fold (never regresses on a stale/lower step);
   * bytes_done += the bytes framed this pull. */
  if (step.rows_done > flow.rows_done)
    flow.rows_done = step.rows_done;
  flow.bytes_done += step.written;

  switch (step.kind)
    {
    case LSG_COPY_STEP_MORE:
      /* A positive byte budget reached -> stop with a bounded blob; otherwise
       * keep streaming. */
      if (flow.budget_bytes > 0 && flow.bytes_done >= flow.budget_bytes)
        {
          flow.kind = LSG_COPY_FLOW_DONE;
          flow.outcome = LSG_COPY_OUTCOME_BUDGET;
        }
      else
        {
          flow.kind = LSG_COPY_FLOW_STREAMING;
        }
      break;

    case LSG_COPY_STEP_DONE:
      flow.kind = LSG_COPY_FLOW_DONE;
      flow.outcome = step.budget_capped ? LSG_COPY_OUTCOME_CELL_CAP
                                        : LSG_COPY_OUTCOME_COMPLETE;
      break;

    case LSG_COPY_STEP_STALLED:
      /* The SAME row as the last stall -> the previous frontier advance made
       * NO progress over it (the filtered mis-target: the core's stalled_row
       * is a FILTERED view row, but the jump targets an ORIGINAL data row), so
       * stop cleanly at the frontier instead of re-jumping it forever.
       * Otherwise ask the worker to advance the frontier to `stalled_row`. */
      if (flow.has_last_stalled && step.stalled_row == flow.last_stalled_row)
        {
          flow.kind = LSG_COPY_FLOW_DONE;
          flow.outcome = LSG_COPY_OUTCOME_FRONTIER;
        }
      else
        {
          flow.kind = LSG_COPY_FLOW_STALLED;
          flow.stalled_row = step.stalled_row;
          flow.last_stalled_row = step.stalled_row;
          flow.has_last_stalled = TRUE;
        }
      break;
    }

  return flow;
}

LsgCopyFlow
lsg_copy_cancel (LsgCopyFlow flow)
{
  if (flow.kind == LSG_COPY_FLOW_DONE)
    return flow; /* terminal is stable */
  flow.kind = LSG_COPY_FLOW_DONE;
  flow.outcome = LSG_COPY_OUTCOME_CANCELLED; /* partial progress preserved */
  return flow;
}

gdouble
lsg_copy_progress_fraction (LsgCopyFlow flow)
{
  if (flow.row_count == 0)
    return 1.0; /* empty rect: nothing to do -> complete */
  gdouble frac = (gdouble)flow.rows_done / (gdouble)flow.row_count;
  if (frac < 0.0)
    frac = 0.0;
  if (frac > 1.0)
    frac = 1.0;
  return frac;
}

/* ------------------------------------------------------------------------- */
/* Copy bridge over the core */
/* ------------------------------------------------------------------------- */

/* One job wraps its `ls_copy_job` and remembers its document so every
 * `ls_copy_*` call can take that session's control_lock (the CLOSE-GUARD). */
struct _LsgCopyJob
{
  LsgDocument *doc;
  ls_copy_job *job;
};

LsgCopyJob *
lsg_document_copy_open (LsgDocument *doc, LsgCopyRect rect)
{
  if (doc == NULL || doc->doc == NULL)
    return NULL;

  ls_copy_rect r;
  r.first_row = rect.first_row;
  r.row_count = rect.row_count;
  r.first_col = rect.first_col;
  r.col_count = rect.col_count;

  /* Serialize with lsg_document_close through the control lane lock, and
   * confirm the core handle is still open under it. */
  g_mutex_lock (doc->control_lock);
  ls_copy_job *cj = (doc->doc != NULL) ? ls_copy_open (doc->doc, &r) : NULL;
  g_mutex_unlock (doc->control_lock);
  if (cj == NULL)
    return NULL;

  LsgCopyJob *j = g_new0 (LsgCopyJob, 1);
  j->doc = doc;
  j->job = cj;
  return j;
}

LsgCopyStep
lsg_document_copy_next (LsgCopyJob *job, guint8 *buf, gsize buf_len)
{
  /* A closed/absent job yields a benign DONE with 0 bytes (the worker stops).
   */
  LsgCopyStep out = { 0 };
  out.kind = LSG_COPY_STEP_DONE;
  if (job == NULL || job->job == NULL)
    return out;

  g_mutex_lock (job->doc->control_lock);
  if (job->doc->doc != NULL) /* the document is still open */
    {
      ls_copy_progress p = ls_copy_next (job->job, buf, buf_len);
      switch (p.step)
        {
        case LS_COPY_STEP_MORE:
          out.kind = LSG_COPY_STEP_MORE;
          break;
        case LS_COPY_STEP_DONE:
          out.kind = LSG_COPY_STEP_DONE;
          break;
        case LS_COPY_STEP_STALLED:
          out.kind = LSG_COPY_STEP_STALLED;
          break;
        default:
          out.kind = LSG_COPY_STEP_DONE;
          break;
        }
      out.written = p.written;
      out.rows_done = p.rows_done;
      out.stalled_row = p.stalled_row;
      out.budget_capped = p.budget_capped;
    }
  g_mutex_unlock (job->doc->control_lock);
  return out;
}

void
lsg_document_copy_close (LsgCopyJob *job)
{
  if (job == NULL)
    return;
  if (job->job != NULL && job->doc != NULL)
    {
      /* Serialize the release against a concurrent lsg_document_close; leaf
       * before root means the document is still alive here. */
      g_mutex_lock (job->doc->control_lock);
      ls_copy_close (job->job);
      g_mutex_unlock (job->doc->control_lock);
    }
  g_free (job);
}
