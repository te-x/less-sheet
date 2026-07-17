/*
 * lsg_window_poll.h — the GTK frontend's WINDOW-POLL decision (slice 1). The C
 * analog of the macOS `WindowPolling`: a pure value transform the poll loop
 * folds each ~100 ms tick to decide whether to RE-ISSUE the identical desired
 * window (so the materialized prefix grows as the scan frontier advances) and
 * whether to KEEP the loop alive. It never touches the core.
 *
 * SLICE 1 inputs are the two that "open + display + scroll" needs: whether the
 * last materialized window came back SHORT (fewer rows than requested — rows
 * beyond the frontier are not yet servable), and whether background indexing is
 * COMPLETE. Later slices additively extend the inputs (jump-scanning,
 * search-active, filter-ongoing) as those features land — the frozen surface
 * grows per slice.
 */
#ifndef LSG_WINDOW_POLL_H
#define LSG_WINDOW_POLL_H

#include <glib.h>

G_BEGIN_DECLS

/* Inputs to one poll-tick decision. */
typedef struct {
  /* The last materialized window is SHORTER than requested (its rows have not
   * all become servable yet) — re-issuing the same request will grow it as the
   * frontier advances. */
  gboolean window_is_short;
  /* Background indexing has reached EOF (the row count is exact). */
  gboolean index_complete;
} LsgWindowPollInputs;

/* The decision for one poll tick. */
typedef struct {
  /* Re-issue the identical desired window so its retained prefix grows. */
  gboolean reissue_window;
  /* Keep the poll loop alive for another tick. */
  gboolean continue_polling;
} LsgWindowPollDecision;

/*
 * Decide one poll tick. `reissue_window` is TRUE iff `window_is_short` (a short
 * window is the only slice-1 reason to re-materialize). `continue_polling` is
 * TRUE iff the window is short OR indexing is not complete (keep polling while
 * the frontier is still advancing; stop once the window is full and the index
 * is exact).
 */
LsgWindowPollDecision lsg_window_poll_decide (LsgWindowPollInputs inputs);

G_END_DECLS

#endif /* LSG_WINDOW_POLL_H */
