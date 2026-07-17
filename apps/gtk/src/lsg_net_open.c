/*
 * lsg_net_open.c — RED SEED for the network-open reducer + drive
 * (lsg_net_open.h). Compiles clean under -Werror (conformance GREEN) but maps
 * everything wrong and opens nothing (behavior RED): tests/test_net_open.c
 * fails here and turns GREEN as the reducer + the ls_open_url_* drive land.
 */
#include <lsg_net_open.h>

struct _LsgNetOpen {
  int unused;
};

static LsgNetProgress
seed_progress (void)
{
  LsgNetProgress p = { LSG_NET_PENDING, FALSE, 0.0, 0, 0, LSG_NET_OK, 0 };
  return p;
}

LsgNetState
lsg_net_state_from_abi (gint32 abi_state)
{
  (void) abi_state;
  return LSG_NET_PENDING; /* SEED: ignores the code */
}

gboolean
lsg_net_state_is_terminal (LsgNetState state)
{
  (void) state;
  return FALSE; /* SEED */
}

LsgNetError
lsg_net_error_from_abi (gint32 abi_error)
{
  (void) abi_error;
  return LSG_NET_OK; /* SEED */
}

LsgNetProgress
lsg_net_progress_from_status (const ls_net_open_status *status)
{
  (void) status;
  return seed_progress (); /* SEED */
}

LsgNetOpen *
lsg_net_open_start (const char *url, const ls_open_options *options)
{
  (void) url;
  (void) options;
  return NULL; /* SEED: nothing starts */
}

LsgNetProgress
lsg_net_open_poll (LsgNetOpen *job)
{
  (void) job;
  return seed_progress ();
}

void
lsg_net_open_cancel (LsgNetOpen *job)
{
  (void) job;
}

LsgDocument *
lsg_net_open_adopt_document (LsgNetOpen *job)
{
  (void) job;
  return NULL;
}

void
lsg_net_open_release (LsgNetOpen *job)
{
  g_free (job);
}
