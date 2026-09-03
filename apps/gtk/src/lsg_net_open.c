/*
 * lsg_net_open.c — the network-open drive + its progress reducer. Wraps the
 * core's async open-job idiom (`ls_open_url_start` -> `ls_net_open_poll` ->
 * `ls_net_open_release`) and folds each raw snapshot into an owned,
 * core-free `LsgNetProgress`. On DONE the produced `ls_doc` is adopted into a
 * normal `LsgDocument`.
 */
#include "lsg_document_internal.h"
#include <lsg_net_open.h>

#include <string.h>

struct _LsgNetOpen
{
  ls_net_open_job *job;
  gboolean adopted; /* the produced ls_doc was handed to an LsgDocument */
};

/* ------------------------------------------------------------------------- */
/* Pure mappers */
/* ------------------------------------------------------------------------- */

LsgNetState
lsg_net_state_from_abi (gint32 abi_state)
{
  switch (abi_state)
    {
    case LS_NET_OPEN_PENDING:
      return LSG_NET_PENDING;
    case LS_NET_OPEN_FETCHING:
      return LSG_NET_FETCHING;
    case LS_NET_OPEN_DONE:
      return LSG_NET_DONE;
    case LS_NET_OPEN_FAILED:
      return LSG_NET_FAILED;
    case LS_NET_OPEN_CANCELLED:
      return LSG_NET_CANCELLED;
    default:
      return LSG_NET_FAILED; /* never a bogus in-flight state */
    }
}

gboolean
lsg_net_state_is_terminal (LsgNetState state)
{
  return state == LSG_NET_DONE || state == LSG_NET_FAILED
         || state == LSG_NET_CANCELLED;
}

LsgNetError
lsg_net_error_from_abi (gint32 abi_error)
{
  switch (abi_error)
    {
    case LS_NET_OK:
      return LSG_NET_OK;
    case LS_NET_ERROR_INVALID_ARGUMENT:
      return LSG_NET_ERROR_INVALID_ARGUMENT;
    case LS_NET_ERROR_UNREACHABLE:
      return LSG_NET_ERROR_UNREACHABLE;
    case LS_NET_ERROR_TIMEOUT:
      return LSG_NET_ERROR_TIMEOUT;
    case LS_NET_ERROR_HTTP_STATUS:
      return LSG_NET_ERROR_HTTP_STATUS;
    case LS_NET_ERROR_TOO_MANY_REDIRECTS:
      return LSG_NET_ERROR_TOO_MANY_REDIRECTS;
    case LS_NET_ERROR_IO:
      return LSG_NET_ERROR_IO;
    case LS_NET_ERROR_CANCELLED:
      return LSG_NET_ERROR_CANCELLED;
    default:
      return LSG_NET_OK; /* unknown/absent */
    }
}

LsgNetProgress
lsg_net_progress_from_status (const ls_net_open_status *status)
{
  LsgNetProgress p = { LSG_NET_PENDING, FALSE, 0.0, 0, 0, LSG_NET_OK, 0 };
  if (status == NULL)
    {
      p.state = LSG_NET_FAILED;
      return p;
    }

  p.state = lsg_net_state_from_abi (status->state);
  if (status->progress < 0.0) /* LS_NET_PROGRESS_UNKNOWN -> indeterminate */
    {
      p.has_fraction = FALSE;
      p.fraction = 0.0;
    }
  else
    {
      p.has_fraction = TRUE;
      p.fraction = status->progress;
    }
  p.bytes_fetched = status->bytes_fetched;
  p.bytes_total = status->bytes_total;
  p.error = lsg_net_error_from_abi (status->error);
  p.http_status = status->http_status;
  return p;
}

/* ------------------------------------------------------------------------- */
/* Drive */
/* ------------------------------------------------------------------------- */

LsgNetOpen *
lsg_net_open_start (const char *url, const ls_open_options *options)
{
  LsgNetOpen *j = g_new0 (LsgNetOpen, 1);
  size_t url_len = (url != NULL) ? strlen (url) : 0;
  j->job = ls_open_url_start (url, url_len, options);
  if (j->job == NULL) /* only when the core could not allocate the handle */
    {
      g_free (j);
      return NULL;
    }
  return j;
}

LsgNetProgress
lsg_net_open_poll (LsgNetOpen *job)
{
  if (job == NULL || job->job == NULL)
    {
      LsgNetProgress p = { LSG_NET_FAILED, FALSE, 0.0, 0, 0, LSG_NET_OK, 0 };
      return p;
    }
  ls_net_open_status s = ls_net_open_poll (job->job);
  return lsg_net_progress_from_status (&s);
}

void
lsg_net_open_cancel (LsgNetOpen *job)
{
  if (job != NULL && job->job != NULL)
    ls_net_open_cancel (job->job);
}

LsgDocument *
lsg_net_open_adopt_document (LsgNetOpen *job)
{
  if (job == NULL || job->job == NULL || job->adopted)
    return NULL;

  ls_net_open_status s = ls_net_open_poll (job->job);
  if (s.state != LS_NET_OPEN_DONE || s.doc == NULL)
    return NULL;

  job->adopted = TRUE;
  /* The produced ls_doc outlives the job; the adopted document follows the
   * normal lsg_document_close lifecycle, independent of lsg_net_open_release.
   */
  return lsg_document_adopt (s.doc);
}

void
lsg_net_open_release (LsgNetOpen *job)
{
  if (job == NULL)
    return;
  if (job->job != NULL)
    ls_net_open_release (job->job); /* cancels + joins if still in flight */
  g_free (job);
}
