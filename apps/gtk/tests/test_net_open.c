/*
 * test_net_open.c — RED behavior tests for the network-open reducer + drive
 * (lsg_net_open.h). Display-free (glib only). Maps the slice-1 network-open
 * criteria that ARE deterministic in the sealed container: the state/error
 * mappers + the progress reducer (over SYNTHETIC ls_net_open_status snapshots),
 * and the SYNCHRONOUS scheme-rejection lifecycle through the REAL ABI (a
 * non-http/https URL fails INVALID_ARGUMENT with no network).
 *
 * DOCUMENTED GAP: a real successful fetch over the wire (TLS, a live host) is
 * not reachable in the gate (the core's fake transport is a Zig-internal seam,
 * not a C-ABI entry point) — it is the author's human GUI pass (ARCH H5).
 */
#include <glib.h>
#include <lesssheet.h>
#include <lsg_net_open.h>

/* --- state mapper --- */

static void
test_state_mapping (void)
{
  g_assert_cmpint (lsg_net_state_from_abi (0), ==, LSG_NET_PENDING);
  g_assert_cmpint (lsg_net_state_from_abi (1), ==, LSG_NET_FETCHING);
  g_assert_cmpint (lsg_net_state_from_abi (2), ==, LSG_NET_DONE);
  g_assert_cmpint (lsg_net_state_from_abi (3), ==, LSG_NET_FAILED);
  g_assert_cmpint (lsg_net_state_from_abi (4), ==, LSG_NET_CANCELLED);
  /* Unknown codes fall back to FAILED (never a bogus in-flight state). */
  g_assert_cmpint (lsg_net_state_from_abi (99), ==, LSG_NET_FAILED);

  g_assert_true (lsg_net_state_is_terminal (LSG_NET_DONE));
  g_assert_true (lsg_net_state_is_terminal (LSG_NET_FAILED));
  g_assert_true (lsg_net_state_is_terminal (LSG_NET_CANCELLED));
  g_assert_false (lsg_net_state_is_terminal (LSG_NET_PENDING));
  g_assert_false (lsg_net_state_is_terminal (LSG_NET_FETCHING));
}

/* --- error mapper (pinned 1:1 against ls_net_status) --- */

static void
test_error_mapping (void)
{
  g_assert_cmpint (lsg_net_error_from_abi (LS_NET_OK), ==, LSG_NET_OK);
  g_assert_cmpint (lsg_net_error_from_abi (LS_NET_ERROR_INVALID_ARGUMENT), ==, LSG_NET_ERROR_INVALID_ARGUMENT);
  g_assert_cmpint (lsg_net_error_from_abi (LS_NET_ERROR_UNREACHABLE), ==, LSG_NET_ERROR_UNREACHABLE);
  g_assert_cmpint (lsg_net_error_from_abi (LS_NET_ERROR_TIMEOUT), ==, LSG_NET_ERROR_TIMEOUT);
  g_assert_cmpint (lsg_net_error_from_abi (LS_NET_ERROR_HTTP_STATUS), ==, LSG_NET_ERROR_HTTP_STATUS);
  g_assert_cmpint (lsg_net_error_from_abi (LS_NET_ERROR_TOO_MANY_REDIRECTS), ==, LSG_NET_ERROR_TOO_MANY_REDIRECTS);
  g_assert_cmpint (lsg_net_error_from_abi (LS_NET_ERROR_IO), ==, LSG_NET_ERROR_IO);
  g_assert_cmpint (lsg_net_error_from_abi (LS_NET_ERROR_CANCELLED), ==, LSG_NET_ERROR_CANCELLED);
}

/* --- progress reducer over synthetic ABI snapshots --- */

static void
test_progress_reducer (void)
{
  /* FETCHING, unknown total: indeterminate fraction + a live byte counter. */
  ls_net_open_status s0 = { 0 };
  s0.state = LS_NET_OPEN_FETCHING;
  s0.progress = LS_NET_PROGRESS_UNKNOWN;
  s0.bytes_fetched = 4096;
  s0.bytes_total = 0;
  s0.error = LS_NET_OK;
  LsgNetProgress p0 = lsg_net_progress_from_status (&s0);
  g_assert_cmpint (p0.state, ==, LSG_NET_FETCHING);
  g_assert_false (p0.has_fraction);
  g_assert_cmpuint (p0.bytes_fetched, ==, 4096);

  /* FETCHING, known total: a real fraction. */
  ls_net_open_status s1 = { 0 };
  s1.state = LS_NET_OPEN_FETCHING;
  s1.progress = 0.5;
  s1.bytes_fetched = 50;
  s1.bytes_total = 100;
  s1.error = LS_NET_OK;
  LsgNetProgress p1 = lsg_net_progress_from_status (&s1);
  g_assert_cmpint (p1.state, ==, LSG_NET_FETCHING);
  g_assert_true (p1.has_fraction);
  g_assert_cmpfloat (p1.fraction, ==, 0.5);
  g_assert_cmpuint (p1.bytes_total, ==, 100);

  /* DONE. */
  ls_net_open_status s2 = { 0 };
  s2.state = LS_NET_OPEN_DONE;
  s2.progress = 1.0;
  s2.error = LS_NET_OK;
  LsgNetProgress p2 = lsg_net_progress_from_status (&s2);
  g_assert_cmpint (p2.state, ==, LSG_NET_DONE);
  g_assert_true (lsg_net_state_is_terminal (p2.state));

  /* FAILED with an HTTP status carried through. */
  ls_net_open_status s3 = { 0 };
  s3.state = LS_NET_OPEN_FAILED;
  s3.progress = LS_NET_PROGRESS_UNKNOWN;
  s3.error = LS_NET_ERROR_HTTP_STATUS;
  s3.http_status = 404;
  LsgNetProgress p3 = lsg_net_progress_from_status (&s3);
  g_assert_cmpint (p3.state, ==, LSG_NET_FAILED);
  g_assert_cmpint (p3.error, ==, LSG_NET_ERROR_HTTP_STATUS);
  g_assert_cmpint (p3.http_status, ==, 404);
}

/* --- synchronous scheme rejection through the real ABI (no network) --- */

static void
test_bad_scheme_rejected (void)
{
  LsgNetOpen *job = lsg_net_open_start ("ftp://example.invalid/data.csv", NULL);
  g_assert_nonnull (job); /* an invalid scheme is a valid job, not a NULL return */

  LsgNetProgress p = lsg_net_open_poll (job);
  g_assert_cmpint (p.state, ==, LSG_NET_FAILED);
  g_assert_cmpint (p.error, ==, LSG_NET_ERROR_INVALID_ARGUMENT);

  /* Nothing to adopt from a failed open. */
  g_assert_null (lsg_net_open_adopt_document (job));

  lsg_net_open_release (job);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/net-open/state-mapping", test_state_mapping);
  g_test_add_func ("/net-open/error-mapping", test_error_mapping);
  g_test_add_func ("/net-open/progress-reducer", test_progress_reducer);
  g_test_add_func ("/net-open/bad-scheme-rejected", test_bad_scheme_rejected);
  return g_test_run ();
}
