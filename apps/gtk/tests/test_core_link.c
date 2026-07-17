/*
 * Bootstrap behavior test: prove the Zig core (liblesssheet.a) links and is
 * callable over the frozen C ABI (api/lesssheet.h) from C in the container.
 *
 * Display-free by design (no GTK): it opens a tiny in-repo CSV through the
 * core, checks the document's shape against the ABI contract, and closes.
 * The real view-model / logic tests are authored later, after the freeze.
 */
#include <glib.h>
#include <lesssheet.h>

static void
test_open_tiny (void)
{
  ls_doc *doc = NULL;
  ls_status st = ls_open (FIXTURE_PATH, NULL, &doc);

  g_assert_cmpint (st, ==, LS_OK);
  g_assert_nonnull (doc);

  /* tiny.csv is "name,age,city" (header) + 2 data rows => 3 columns. */
  g_assert_cmpuint (ls_column_count (doc), ==, 3);

  /* Record 1 is not all-numeric, so it is the header (pinned header grammar). */
  ls_dialect dialect = ls_dialect_get (doc);
  g_assert_true (dialect.header);

  /* A file <= LS_OPEN_HEAD_MAX_BYTES is fully indexed by open itself, so the
   * row count is exact from the moment open returns (ABI OPEN COST pin). */
  ls_row_count rc = ls_row_count_get (doc);
  g_assert_true (rc.exact);
  g_assert_cmpuint (rc.count, ==, 2);

  ls_close (doc);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/core/open-tiny", test_open_tiny);
  return g_test_run ();
}
