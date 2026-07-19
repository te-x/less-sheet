/*
 * lsg_copy.c — RED SEED for the STREAMING TSV COPY feature (lsg_copy.h). Slice 5.
 *
 * This is a PLANNER SEED: it compiles and links against the frozen header so the
 * suite is RED on BEHAVIOR (not on compile/import). Every body is a deliberate
 * stub — the pure view-model never leaves its initial/zero state, and the bridge
 * opens no job — so the frozen g_tests in tests/test_copy.c FAIL for the right
 * reason. The implementer replaces these with the real drive/outcome fold (a C
 * port of the macOS `streamCopy` loop + `CopyOutcome`) and the real `ls_copy_*`
 * bridge (a C port of `CoreDocumentSession.openCopy` / `copyStreamNext` /
 * `copyStreamClose` + `CoreCopyStream`), guarded by the document session's
 * `control_lock` close-guard (see lsg_copy.h's LIFETIME & CLOSE-GUARD block).
 *
 * Two layers, mirroring the established GTK slice split (find / jump / filter):
 *   1. the PURE copy view-model (over LsgCopyFlow by value; no core, no threads);
 *   2. the COPY BRIDGE over the real core (through the non-frozen _LsgDocument
 *      seam), the single place ls_copy_open / ls_copy_next / ls_copy_close run.
 */
#include <lsg_copy.h>
#include "lsg_document_internal.h"

#include <lesssheet.h>

/* ------------------------------------------------------------------------- */
/* Pure view-model — RED stubs (never fold; the tests drive the real algebra) */
/* ------------------------------------------------------------------------- */

LsgCopyFlow
lsg_copy_begin (LsgCopyRect rect, guint64 budget_bytes)
{
  (void) rect;
  (void) budget_bytes;
  LsgCopyFlow f = { 0 };
  return f;                 /* RED: not STREAMING; no row_count / budget captured */
}

LsgCopyFlow
lsg_copy_fold (LsgCopyFlow flow, LsgCopyStep step)
{
  (void) step;
  return flow;              /* RED: never accumulates, advances, or stops */
}

LsgCopyFlow
lsg_copy_cancel (LsgCopyFlow flow)
{
  return flow;              /* RED: never reaches DONE/CANCELLED */
}

gdouble
lsg_copy_progress_fraction (LsgCopyFlow flow)
{
  (void) flow;
  return 0.0;               /* RED: never reflects rows_done / row_count */
}

/* ------------------------------------------------------------------------- */
/* Copy bridge — RED stubs (opens no job; the real impl wraps ls_copy_*)      */
/* ------------------------------------------------------------------------- */

/*
 * The real job wraps the core handle + its ls_copy_job and reaches the session's
 * control_lock through the _LsgDocument seam (defined here for the implementer;
 * the seed never allocates one — open returns NULL).
 */
struct _LsgCopyJob {
  LsgDocument *doc;
  ls_copy_job *job;
};

LsgCopyJob *
lsg_document_copy_open (LsgDocument *doc, LsgCopyRect rect)
{
  (void) doc;
  (void) rect;
  return NULL;              /* RED: no job vended, so the bridge tests fail fast */
}

LsgCopyStep
lsg_document_copy_next (LsgCopyJob *job, guint8 *buf, gsize buf_len)
{
  (void) job;
  (void) buf;
  (void) buf_len;
  LsgCopyStep s = { 0 };
  s.kind = LSG_COPY_STEP_DONE;   /* RED: terminates with zero bytes framed */
  return s;
}

void
lsg_document_copy_close (LsgCopyJob *job)
{
  (void) job;                    /* RED: no-op (nothing was opened) */
}
