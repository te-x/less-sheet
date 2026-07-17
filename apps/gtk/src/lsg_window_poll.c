/*
 * lsg_window_poll.c — RED SEED for the window-poll decision
 * (lsg_window_poll.h). Compiles clean under -Werror (conformance GREEN) but
 * always decides "do nothing" (behavior RED): tests/test_window_poll.c fails
 * here and turns GREEN as the real re-issue / keep-polling rule is implemented.
 */
#include <lsg_window_poll.h>

LsgWindowPollDecision
lsg_window_poll_decide (LsgWindowPollInputs inputs)
{
  (void) inputs;
  LsgWindowPollDecision d = { FALSE, FALSE }; /* SEED: decides nothing */
  return d;
}
