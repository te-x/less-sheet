/*
 * lsg_window_poll.c — should the ~100 ms poll loop re-issue the window, and
 * should it keep running? A pure value transform; touches no core state.
 */
#include <lsg_window_poll.h>

LsgWindowPollDecision
lsg_window_poll_decide (LsgWindowPollInputs inputs)
{
  LsgWindowPollDecision d;

  /* A short window means rows beyond the scan frontier were not servable yet;
   * re-issuing the identical range grows the retained prefix as the frontier
   * advances. */
  d.reissue_window = inputs.window_is_short;

  /* Stop only once the window is full AND the index is exact — until then
   * there is either a prefix to grow or an estimate still converging. */
  d.continue_polling = inputs.window_is_short || !inputs.index_complete;

  return d;
}
