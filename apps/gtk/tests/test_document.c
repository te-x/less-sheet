/*
 * test_document.c — RED behavior tests for the windowed document session
 * (lsg_document.h) over the REAL Zig core. Display-free (glib only). Maps the
 * slice-1 "open + display + scroll" data-path acceptance criteria: open a local
 * fixture and read its facts/window/cells; the open-error taxonomy; viewport-
 * only bounded windows (LS_WINDOW_MAX_ROWS clamp + column windowing, no
 * O(rows)); and the U+FFFD display-boundary sanitization.
 *
 * These are RED against the seeded src/ (which opens nothing and marshals
 * empty/zero) and turn GREEN as the session wrapper is implemented.
 */
#include <glib.h>
#include <glib/gstdio.h>
#include <lesssheet.h>
#include <lsg_document.h>

/* --- open-error mapping (pure; pinned against the real LS_* values) --- */

static void
test_open_error_mapping (void)
{
  g_assert_cmpint (lsg_open_error_from_status (LS_OK), ==, LSG_OPEN_OK);
  g_assert_cmpint (lsg_open_error_from_status (LS_ERROR_NOT_FOUND), ==, LSG_OPEN_NOT_FOUND);
  g_assert_cmpint (lsg_open_error_from_status (LS_ERROR_PERMISSION_DENIED), ==, LSG_OPEN_PERMISSION_DENIED);
  g_assert_cmpint (lsg_open_error_from_status (LS_ERROR_IO), ==, LSG_OPEN_IO);
  g_assert_cmpint (lsg_open_error_from_status (LS_ERROR_INVALID_ARGUMENT), ==, LSG_OPEN_INVALID_ARGUMENT);
}

/* --- scan-progress fraction (pure) --- */

static void
test_scan_progress_fraction (void)
{
  LsgScanProgress empty = { 0, 0, TRUE };
  g_assert_cmpfloat (lsg_scan_progress_fraction (empty), ==, 1.0);

  LsgScanProgress half = { 5, 10, FALSE };
  g_assert_cmpfloat (lsg_scan_progress_fraction (half), ==, 0.5);

  LsgScanProgress unknown = { 3, LS_BYTES_TOTAL_UNKNOWN, FALSE };
  g_assert_cmpfloat (lsg_scan_progress_fraction (unknown), ==, 0.0);
}

/* --- open the tiny fixture + read facts --- */

static void
test_open_tiny_facts (void)
{
  LsgOpenError err = LSG_OPEN_IO;
  LsgDocument *doc = lsg_document_open_local (FIXTURE_PATH, NULL, &err);
  g_assert_nonnull (doc);
  g_assert_cmpint (err, ==, LSG_OPEN_OK);

  /* tiny.csv: header "name,age,city" + 2 data rows => 3 columns, exact count 2. */
  g_assert_cmpuint (lsg_document_column_count (doc), ==, 3);
  g_assert_true (lsg_document_has_header (doc));

  LsgDialect d = lsg_document_dialect (doc);
  g_assert_true (d.header);
  g_assert_cmpuint (d.separator, ==, ',');
  g_assert_true (d.has_quote);
  g_assert_cmpuint (d.encoding, ==, LS_ENCODING_UTF8);

  LsgRowCount rc = lsg_document_row_count (doc);
  g_assert_true (rc.exact);
  g_assert_cmpuint (rc.count, ==, 2);

  char *h0 = lsg_document_header_cell_dup (doc, 0);
  char *h1 = lsg_document_header_cell_dup (doc, 1);
  char *h2 = lsg_document_header_cell_dup (doc, 2);
  g_assert_cmpstr (h0, ==, "name");
  g_assert_cmpstr (h1, ==, "age");
  g_assert_cmpstr (h2, ==, "city");
  g_free (h0); g_free (h1); g_free (h2);

  lsg_document_close (doc);
}

/* --- materialize a window + read cells / markers / gutter --- */

static void
test_window_cells (void)
{
  LsgDocument *doc = lsg_document_open_local (FIXTURE_PATH, NULL, NULL);
  g_assert_nonnull (doc);

  LsgWindow *w = lsg_document_set_window (doc, 0, 2, 0, 3);
  g_assert_nonnull (w);
  g_assert_cmpuint (lsg_window_first_row (w), ==, 0);
  g_assert_cmpuint (lsg_window_row_count (w), ==, 2);
  g_assert_cmpuint (lsg_window_first_col (w), ==, 0);
  g_assert_cmpuint (lsg_window_col_count (w), ==, 3);

  g_assert_cmpstr (lsg_window_cell (w, 0, 0), ==, "Alice");
  g_assert_cmpstr (lsg_window_cell (w, 0, 2), ==, "New York");
  g_assert_cmpstr (lsg_window_cell (w, 1, 0), ==, "Bob");
  g_assert_cmpstr (lsg_window_cell (w, 1, 2), ==, "Los Angeles");

  /* No cell is display-capped and no row is oversized in this tiny file. */
  g_assert_false (lsg_window_cell_truncated (w, 0, 0));
  g_assert_false (lsg_window_row_oversized (w, 0));
  g_assert_false (lsg_window_row_oversized (w, 1));

  /* Identity gutter without a filter. */
  g_assert_cmpuint (lsg_window_source_row (w, 0), ==, 0);
  g_assert_cmpuint (lsg_window_source_row (w, 1), ==, 1);

  /* Out-of-range reads are total and safe. */
  g_assert_cmpstr (lsg_window_cell (w, 99, 0), ==, "");
  g_assert_cmpuint (lsg_window_source_row (w, 99), ==, LSG_NO_ROW);

  lsg_window_free (w);
  lsg_document_close (doc);
}

/* --- column windowing: fetch only a sub-range of columns --- */

static void
test_window_column_subrange (void)
{
  LsgDocument *doc = lsg_document_open_local (FIXTURE_PATH, NULL, NULL);
  g_assert_nonnull (doc);

  /* Only the "age" column (index 1). */
  LsgWindow *w = lsg_document_set_window (doc, 0, 2, 1, 1);
  g_assert_nonnull (w);
  g_assert_cmpuint (lsg_window_first_col (w), ==, 1);
  g_assert_cmpuint (lsg_window_col_count (w), ==, 1);
  g_assert_cmpstr (lsg_window_cell (w, 0, 0), ==, "30");
  g_assert_cmpstr (lsg_window_cell (w, 1, 0), ==, "25");

  lsg_window_free (w);
  lsg_document_close (doc);
}

/* --- open failures map to the right taxonomy --- */

static void
test_open_not_found (void)
{
  LsgOpenError err = LSG_OPEN_OK;
  LsgDocument *doc = lsg_document_open_local ("/no/such/less-sheet/file.csv", NULL, &err);
  g_assert_null (doc);
  g_assert_cmpint (err, ==, LSG_OPEN_NOT_FOUND);
}

/* --- viewport-only: a huge request is clamped to LS_WINDOW_MAX_ROWS and the
 *     document is windowed, never enumerated (O(viewport), not O(rows)) --- */

static void
test_window_clamp_and_paging (void)
{
  /* Build a synthetic 2-column CSV of 5000 data rows in a temp dir (well under
   * LS_OPEN_HEAD_MAX_BYTES, so it is fully indexed at open: exact count). */
  GError *gerr = NULL;
  char *dir = g_dir_make_tmp ("lsg-doc-XXXXXX", &gerr);
  g_assert_no_error (gerr);
  char *path = g_build_filename (dir, "big.csv", NULL);

  GString *csv = g_string_new ("a,b\n");
  const guint N = 5000;
  for (guint i = 0; i < N; i++)
    g_string_append_printf (csv, "r,%u\n", i);
  g_assert_true (g_file_set_contents (path, csv->str, (gssize) csv->len, &gerr));
  g_assert_no_error (gerr);
  g_string_free (csv, TRUE);

  LsgDocument *doc = lsg_document_open_local (path, NULL, NULL);
  g_assert_nonnull (doc);
  g_assert_cmpuint (lsg_document_column_count (doc), ==, 2);

  LsgRowCount rc = lsg_document_row_count (doc);
  g_assert_true (rc.exact);
  g_assert_cmpuint (rc.count, ==, N);

  /* A request far larger than the cap comes back clamped to LS_WINDOW_MAX_ROWS,
   * NOT the whole document. */
  LsgWindow *w0 = lsg_document_set_window (doc, 0, 100000, 0, 2);
  g_assert_nonnull (w0);
  g_assert_cmpuint (lsg_window_row_count (w0), ==, LS_WINDOW_MAX_ROWS);
  g_assert_cmpstr (lsg_window_cell (w0, 0, 1), ==, "0");
  lsg_window_free (w0);

  /* Paging past the cap serves the remaining rows. */
  LsgWindow *w1 = lsg_document_set_window (doc, LS_WINDOW_MAX_ROWS, LS_WINDOW_MAX_ROWS, 0, 2);
  g_assert_nonnull (w1);
  g_assert_cmpuint (lsg_window_row_count (w1), ==, N - LS_WINDOW_MAX_ROWS);
  g_assert_cmpstr (lsg_window_cell (w1, 0, 0), ==, "r");
  lsg_window_free (w1);

  lsg_document_close (doc);

  /* A directory path is an IO open failure (exists, not readable as a file). */
  LsgOpenError err = LSG_OPEN_OK;
  LsgDocument *nope = lsg_document_open_local (dir, NULL, &err);
  g_assert_null (nope);
  g_assert_cmpint (err, ==, LSG_OPEN_IO);

  g_unlink (path);
  g_rmdir (dir);
  g_free (path);
  g_free (dir);
}

/* --- U+FFFD display-boundary sanitization --- */

static void
test_utf8_sanitize (void)
{
  /* Valid UTF-8 survives byte-for-byte. */
  char *ok = lsg_utf8_sanitize_dup ((const guint8 *) "hi \xC3\xA9", 5);
  g_assert_cmpstr (ok, ==, "hi \xC3\xA9");
  g_free (ok);

  /* Invalid bytes become valid UTF-8 (U+FFFD), never raw. */
  char *bad = lsg_utf8_sanitize_dup ((const guint8 *) "\xFF\xFE", 2);
  g_assert_true (g_utf8_validate (bad, -1, NULL));
  g_assert_cmpuint (strlen (bad), >, 0);
  g_assert_nonnull (g_strstr_len (bad, -1, "\xEF\xBF\xBD")); /* U+FFFD in UTF-8 */
  g_free (bad);

  /* Empty input yields "". */
  char *empty = lsg_utf8_sanitize_dup (NULL, 0);
  g_assert_cmpstr (empty, ==, "");
  g_free (empty);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/document/open-error-mapping", test_open_error_mapping);
  g_test_add_func ("/document/scan-progress-fraction", test_scan_progress_fraction);
  g_test_add_func ("/document/open-tiny-facts", test_open_tiny_facts);
  g_test_add_func ("/document/window-cells", test_window_cells);
  g_test_add_func ("/document/window-column-subrange", test_window_column_subrange);
  g_test_add_func ("/document/open-not-found", test_open_not_found);
  g_test_add_func ("/document/window-clamp-and-paging", test_window_clamp_and_paging);
  g_test_add_func ("/document/utf8-sanitize", test_utf8_sanitize);
  return g_test_run ();
}
