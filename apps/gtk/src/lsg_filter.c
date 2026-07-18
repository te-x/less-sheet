/*
 * lsg_filter.c — RED SEED for the FILTER-TO-MATCHES module (slice 4). Every
 * prototype in <lsg_filter.h> is defined with a stub body so the module compiles
 * clean under -Werror (the CONFORMANCE gate) while the BEHAVIOR tests
 * (tests/test_filter.c) stay RED: apply/clear/resolve never leave the initial
 * (identity) state, the banner is never produced, the jump row-count hint ignores
 * the filter, and the bridge is a no-op whose set is rejected and whose poll
 * reports IDLE. The implementer replaces these bodies — the bridge reaches the
 * core `ls_doc *` via the private src/lsg_document_internal.h seam and marshals
 * the request into `ls_search_request` exactly as the find bridge does (it may
 * share that helper through the seam) — and the suite turns GREEN.
 */
#include <lsg_filter.h>

/* ------------------------------------------------------------------------- */
/* Pure view-model (stubs)                                                    */
/* ------------------------------------------------------------------------- */

LsgFilterState
lsg_filter_initial (void)
{
  return (LsgFilterState){ .active = FALSE };
}

LsgFilterState
lsg_filter_applied (LsgFilterState state, LsgRowCount document_rows,
                    LsgFilterSnapshot snapshot)
{
  (void) document_rows;
  (void) snapshot;
  return state;   /* stub: never enters filtered mode */
}

LsgFilterState
lsg_filter_cleared (LsgFilterState state)
{
  return state;   /* stub: never returns to the identity view */
}

LsgFilterState
lsg_filter_resolved (LsgFilterState state,
                     gboolean has_snapshot, LsgFilterSnapshot snapshot)
{
  (void) has_snapshot;
  (void) snapshot;
  return state;   /* stub: never folds a poll */
}

gboolean
lsg_filter_banner (LsgFilterState state, LsgFilterBanner *out_banner)
{
  (void) state;
  (void) out_banner;
  return FALSE;    /* stub: never produces a banner */
}

LsgRowCount
lsg_filter_jump_rowcount (LsgFilterState state, LsgRowCount identity_rowcount)
{
  (void) state;
  return identity_rowcount;   /* stub: ignores the filter (never hints with M) */
}

/* ------------------------------------------------------------------------- */
/* Filter bridge over the core (no-op stubs)                                  */
/* ------------------------------------------------------------------------- */

gboolean
lsg_document_filter_set (LsgDocument *doc, LsgSearchRequest request)
{
  (void) doc;
  (void) request;
  return FALSE;    /* stub: never enters filtered mode */
}

void
lsg_document_filter_clear (LsgDocument *doc)
{
  (void) doc;
}

gboolean
lsg_document_filter_poll (const LsgDocument *doc, LsgFilterSnapshot *out)
{
  (void) doc;
  (void) out;
  return FALSE;    /* stub: reports IDLE (no filter) */
}
