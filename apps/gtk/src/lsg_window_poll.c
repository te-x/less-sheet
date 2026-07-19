/*
 * lsg_window_poll.c — the GTK frontend's WINDOW-POLL decision
 * (lsg_window_poll.h). The C analog of the macOS `WindowPolling`: a pure value
 * transform the ~100 ms poll loop folds to decide whether to RE-ISSUE the
 * identical desired window (so the materialized prefix grows as the scan
 * frontier advances) and whether to KEEP the loop alive. Touches no core
 * state.
 */
#include <lsg_window_poll.h>

LsgWindowPollDecision
lsg_window_poll_decide (LsgWindowPollInputs inputs)
{
  LsgWindowPollDecision d;

  /* A short window is the only slice-1 reason to re-materialize the identical
   * desired range: its rows beyond the frontier become servable as the
   * frontier advances, so re-issuing grows the retained prefix. */
  d.reissue_window = inputs.window_is_short;

  /* Keep polling while there is still work to observe: the window is short
   * (the frontier has not caught up to the request) OR indexing is not yet
   * complete (the row-count estimate is still converging). Stop only once the
   * window is full AND the index is exact. */
  d.continue_polling = inputs.window_is_short || !inputs.index_complete;

  return d;
}
