/*
 * test_window_poll.c — RED behavior tests for the window-poll decision
 * (lsg_window_poll.h). Display-free (glib only). Maps the slice-1 "scroll
 * smoothly while the index converges" rule: re-issue the desired window while
 * it is short, and keep polling while the window is short OR indexing is not
 * yet complete.
 */
#include <glib.h>
#include <lsg_window_poll.h>

static void
test_short_window_incomplete (void)
{
  /* A short window during indexing: re-issue (to grow it) AND keep polling. */
  LsgWindowPollInputs in = { TRUE, FALSE };
  LsgWindowPollDecision d = lsg_window_poll_decide (in);
  g_assert_true (d.reissue_window);
  g_assert_true (d.continue_polling);
}

static void
test_full_window_complete (void)
{
  /* Full window and the index is exact: nothing to do, stop polling. */
  LsgWindowPollInputs in = { FALSE, TRUE };
  LsgWindowPollDecision d = lsg_window_poll_decide (in);
  g_assert_false (d.reissue_window);
  g_assert_false (d.continue_polling);
}

static void
test_full_window_incomplete (void)
{
  /* Full window but the frontier is still advancing: no re-issue, keep polling
   * (the row-count estimate is still converging). */
  LsgWindowPollInputs in = { FALSE, FALSE };
  LsgWindowPollDecision d = lsg_window_poll_decide (in);
  g_assert_false (d.reissue_window);
  g_assert_true (d.continue_polling);
}

static void
test_short_window_complete (void)
{
  /* A short window even though the index is complete (e.g. a request past EOF):
   * re-issue and keep polling until it settles. */
  LsgWindowPollInputs in = { TRUE, TRUE };
  LsgWindowPollDecision d = lsg_window_poll_decide (in);
  g_assert_true (d.reissue_window);
  g_assert_true (d.continue_polling);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/window-poll/short-incomplete", test_short_window_incomplete);
  g_test_add_func ("/window-poll/full-complete", test_full_window_complete);
  g_test_add_func ("/window-poll/full-incomplete", test_full_window_incomplete);
  g_test_add_func ("/window-poll/short-complete", test_short_window_complete);
  return g_test_run ();
}
