/*
 * lsg_jump.c — RED SEED for the JUMP module (slice 3). Every prototype in
 * <lsg_jump.h> is defined with a stub body so the module compiles clean under
 * -Werror (the CONFORMANCE gate) while the BEHAVIOR tests (tests/test_jump.c)
 * stay RED: the parse always fails, submit/resolve/cancel never leave the initial
 * state, and the bridge is a no-op whose poll reports IDLE. The implementer
 * replaces these bodies (the bridge reaches the core `ls_doc *` via the private
 * src/lsg_document_internal.h seam, exactly like the find bridge) and the suite
 * turns GREEN.
 */
#include <lsg_jump.h>

/* ------------------------------------------------------------------------- */
/* Pure view-model (stubs)                                                    */
/* ------------------------------------------------------------------------- */

LsgJumpFlow
lsg_jump_initial (void)
{
  return (LsgJumpFlow){ .kind = LSG_JUMP_FLOW_IDLE };
}

gboolean
lsg_jump_parse (const char *input, guint64 *out_target)
{
  (void) input;
  (void) out_target;
  return FALSE;
}

LsgJumpSubmit
lsg_jump_submit (const char *input, LsgRowCount rowcount,
                 gboolean filtered, guint64 pre_jump_first_row)
{
  (void) input;
  (void) rowcount;
  (void) filtered;
  (void) pre_jump_first_row;
  return (LsgJumpSubmit){ .outcome = LSG_JUMP_REJECTED,
                          .flow = { .kind = LSG_JUMP_FLOW_REJECTED } };
}

LsgJumpFlow
lsg_jump_resolve (LsgJumpFlow flow, LsgJumpStatus status, gboolean filtered)
{
  (void) status;
  (void) filtered;
  return flow;
}

LsgJumpFlow
lsg_jump_cancel (LsgJumpFlow flow)
{
  return flow;
}

/* ------------------------------------------------------------------------- */
/* Jump bridge over the core (no-op stubs)                                    */
/* ------------------------------------------------------------------------- */

void
lsg_document_jump_start (LsgDocument *doc, guint64 target_row)
{
  (void) doc;
  (void) target_row;
}

void
lsg_document_jump_cancel (LsgDocument *doc)
{
  (void) doc;
}

LsgJumpStatus
lsg_document_jump_poll (const LsgDocument *doc)
{
  (void) doc;
  return (LsgJumpStatus){ .state = LSG_JUMP_IDLE };
}
