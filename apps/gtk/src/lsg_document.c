/*
 * lsg_document.c — RED SEED for the windowed document session
 * (lsg_document.h). Compiles clean under -Werror (conformance GREEN) but
 * opens nothing and marshals empty/zero values (behavior RED): the frozen
 * tests in tests/test_document.c fail here and turn GREEN as the real two-lane
 * wrapper over the Zig core is implemented.
 */
#include <lsg_document.h>

struct _LsgDocument {
  int unused;
};

struct _LsgWindow {
  int unused;
};

LsgOpenError
lsg_open_error_from_status (ls_status status)
{
  (void) status;
  return LSG_OPEN_OK; /* SEED: ignores the code */
}

gdouble
lsg_scan_progress_fraction (LsgScanProgress progress)
{
  (void) progress;
  return 0.0; /* SEED */
}

LsgDocument *
lsg_document_open_local (const char *path, const ls_open_options *options, LsgOpenError *out_error)
{
  (void) path;
  (void) options;
  if (out_error != NULL)
    *out_error = LSG_OPEN_OK;
  return NULL; /* SEED: nothing opens */
}

void
lsg_document_close (LsgDocument *doc)
{
  (void) doc;
}

guint32
lsg_document_column_count (const LsgDocument *doc)
{
  (void) doc;
  return 0;
}

LsgDialect
lsg_document_dialect (const LsgDocument *doc)
{
  (void) doc;
  LsgDialect d = { 0, 0, FALSE, FALSE, 0, FALSE, FALSE, FALSE, FALSE };
  return d;
}

gboolean
lsg_document_has_header (const LsgDocument *doc)
{
  (void) doc;
  return FALSE;
}

char *
lsg_document_header_cell_dup (const LsgDocument *doc, guint32 col)
{
  (void) doc;
  (void) col;
  return g_strdup ("");
}

LsgRowCount
lsg_document_row_count (const LsgDocument *doc)
{
  (void) doc;
  LsgRowCount rc = { 0, FALSE };
  return rc;
}

LsgScanProgress
lsg_document_index_progress (const LsgDocument *doc)
{
  (void) doc;
  LsgScanProgress p = { 0, 0, FALSE };
  return p;
}

LsgWindow *
lsg_document_set_window (LsgDocument *doc, guint64 first_row, guint32 row_count,
                         guint32 first_col, guint32 col_count)
{
  (void) doc;
  (void) first_row;
  (void) row_count;
  (void) first_col;
  (void) col_count;
  return g_new0 (LsgWindow, 1); /* SEED: an empty (0-row, 0-col) window */
}

guint64
lsg_window_first_row (const LsgWindow *window)
{
  (void) window;
  return 0;
}

guint32
lsg_window_row_count (const LsgWindow *window)
{
  (void) window;
  return 0;
}

guint32
lsg_window_first_col (const LsgWindow *window)
{
  (void) window;
  return 0;
}

guint32
lsg_window_col_count (const LsgWindow *window)
{
  (void) window;
  return 0;
}

const char *
lsg_window_cell (const LsgWindow *window, guint32 row, guint32 col)
{
  (void) window;
  (void) row;
  (void) col;
  return "";
}

gboolean
lsg_window_cell_truncated (const LsgWindow *window, guint32 row, guint32 col)
{
  (void) window;
  (void) row;
  (void) col;
  return FALSE;
}

gboolean
lsg_window_row_oversized (const LsgWindow *window, guint32 row)
{
  (void) window;
  (void) row;
  return FALSE;
}

guint64
lsg_window_source_row (const LsgWindow *window, guint32 row)
{
  (void) window;
  (void) row;
  return LSG_NO_ROW;
}

void
lsg_window_free (LsgWindow *window)
{
  g_free (window);
}

char *
lsg_utf8_sanitize_dup (const guint8 *bytes, gsize len)
{
  (void) bytes;
  (void) len;
  return g_strdup (""); /* SEED: never actually sanitizes */
}
