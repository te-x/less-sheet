/*
 * lsg_document.c — the GTK frontend's windowed DOCUMENT SESSION
 * (lsg_document.h). The C analog of the macOS
 * `DocumentSession`/`CoreDocumentSession`/`DocumentSessionOpening` layer: the
 * SINGLE place that wraps the core's two-lane `ls_*` access for the viewer.
 *
 * Ownership / validity (the eviction-safe borrow rule): every borrowed `ls_str`
 * is COPIED out immediately, invalid UTF-8 sanitized to U+FFFD at the display
 * boundary (`lsg_utf8_sanitize_dup`), so nothing a caller holds is tied to the
 * core's window eviction. `char *` returns are caller-owned (g_free); an
 * `LsgWindow` owns its copied cells until `lsg_window_free`.
 *
 * Threading (mirrors <lesssheet.h>): the poll/control-lane accessors delegate
 * to the core's internally-synchronized, any-thread-safe entry points; the
 * window lane (`set_window` + the WINDOW-lane `ls_header_cell` behind
 * `header_cell_dup`) is serialized by the session's `window_lock`; `close`
 * acquires both lane locks in a fixed order (window then control) before
 * releasing — the two-lock discipline the ARCH mandates so a later slice's
 * control-lane worker (copy/find/filter) can run concurrent with live
 * scrolling. In slice 1 the session holds no cached mutable state of its own, so
 * `control_lock` is reserved (acquired only by `close`).
 */
#include <lsg_document.h>
#include "lsg_document_internal.h"

struct _LsgDocument {
  ls_doc *doc;
  /* Heap-allocated so the poll-lane accessors can lock through a
   * `const LsgDocument *` (locking mutates the pointee, not the const field). */
  GMutex *window_lock;
  GMutex *control_lock;
};

struct _LsgWindow {
  guint64 first_row;
  guint32 row_count;   /* ACTUAL materialized rows (<= requested) */
  guint32 first_col;   /* clamped to [0, column_count] */
  guint32 col_count;   /* clamped requested range width */
  char **cells;        /* row_count * col_count owned UTF-8 strings (or NULL) */
  gboolean *truncated; /* row_count * col_count per-cell display-cap flags */
  gboolean *oversized; /* row_count per-row oversized flags */
  guint64 *source_row; /* row_count original data-row numbers */
};

/* ------------------------------------------------------------------------- */
/* Pure mappers                                                               */
/* ------------------------------------------------------------------------- */

LsgOpenError
lsg_open_error_from_status (ls_status status)
{
  switch (status)
    {
    case LS_OK:                        return LSG_OPEN_OK;
    case LS_ERROR_NOT_FOUND:           return LSG_OPEN_NOT_FOUND;
    case LS_ERROR_PERMISSION_DENIED:   return LSG_OPEN_PERMISSION_DENIED;
    case LS_ERROR_IO:                  return LSG_OPEN_IO;
    case LS_ERROR_INVALID_ARGUMENT:    return LSG_OPEN_INVALID_ARGUMENT;
    default:                           return LSG_OPEN_IO; /* total: safe fallback */
    }
}

gdouble
lsg_scan_progress_fraction (LsgScanProgress progress)
{
  if (progress.bytes_total == LS_BYTES_TOTAL_UNKNOWN)
    return 0.0;                                  /* length not yet known */
  if (progress.complete || progress.bytes_total == 0)
    return 1.0;                                  /* done, or an empty document */
  return (gdouble) progress.bytes_scanned / (gdouble) progress.bytes_total;
}

/* ------------------------------------------------------------------------- */
/* Display-boundary UTF-8 sanitization                                        */
/* ------------------------------------------------------------------------- */

char *
lsg_utf8_sanitize_dup (const guint8 *bytes, gsize len)
{
  if (len == 0)
    return g_strdup ("");
  /* g_utf8_make_valid returns a fresh NUL-terminated string with every
   * ill-formed byte sequence replaced by U+FFFD; valid UTF-8 survives verbatim
   * (the ABI's pass-through UTF-8 rule). */
  return g_utf8_make_valid ((const char *) bytes, (gssize) len);
}

/* ------------------------------------------------------------------------- */
/* Construction / open / close                                                */
/* ------------------------------------------------------------------------- */

static LsgDocument *
doc_wrap (ls_doc *core)
{
  LsgDocument *d = g_new0 (LsgDocument, 1);
  d->doc = core;
  d->window_lock = g_new0 (GMutex, 1);
  d->control_lock = g_new0 (GMutex, 1);
  g_mutex_init (d->window_lock);
  g_mutex_init (d->control_lock);
  return d;
}

LsgDocument *
lsg_document_open_local (const char *path, const ls_open_options *options,
                         LsgOpenError *out_error)
{
  ls_doc *core = NULL;
  ls_status st = ls_open (path, options, &core);
  if (st != LS_OK || core == NULL)
    {
      if (out_error != NULL)
        *out_error = lsg_open_error_from_status (st);
      return NULL;
    }
  if (out_error != NULL)
    *out_error = LSG_OPEN_OK;
  return doc_wrap (core);
}

LsgDocument *
lsg_document_adopt (ls_doc *core_doc)
{
  if (core_doc == NULL)
    return NULL;
  return doc_wrap (core_doc);
}

void
lsg_document_close (LsgDocument *doc)
{
  if (doc == NULL)
    return;

  /* Two-lock close in a fixed order (window then control): no window-lane or
   * control-lane call may complete past this point. */
  g_mutex_lock (doc->window_lock);
  g_mutex_lock (doc->control_lock);
  if (doc->doc != NULL)
    {
      ls_close (doc->doc);
      doc->doc = NULL;
    }
  g_mutex_unlock (doc->control_lock);
  g_mutex_unlock (doc->window_lock);

  g_mutex_clear (doc->window_lock);
  g_mutex_clear (doc->control_lock);
  g_free (doc->window_lock);
  g_free (doc->control_lock);
  g_free (doc);
}

/* ------------------------------------------------------------------------- */
/* Fixed facts / row-count / progress (poll/control lane; any thread)         */
/* ------------------------------------------------------------------------- */

guint32
lsg_document_column_count (const LsgDocument *doc)
{
  if (doc == NULL || doc->doc == NULL)
    return 0;
  return ls_column_count (doc->doc);
}

LsgDialect
lsg_document_dialect (const LsgDocument *doc)
{
  LsgDialect out = { 0, 0, FALSE, FALSE, 0, FALSE, FALSE, FALSE, FALSE };
  if (doc == NULL || doc->doc == NULL)
    return out;

  ls_dialect d = ls_dialect_get (doc->doc);
  out.separator = d.separator;
  out.quote = d.quote;
  out.has_quote = d.has_quote;
  out.header = d.header;
  out.encoding = d.encoding;
  out.separator_forced = d.separator_forced;
  out.quote_forced = d.quote_forced;
  out.header_forced = d.header_forced;
  out.encoding_forced = d.encoding_forced;
  return out;
}

gboolean
lsg_document_has_header (const LsgDocument *doc)
{
  if (doc == NULL || doc->doc == NULL)
    return FALSE;
  return ls_dialect_get (doc->doc).header;
}

char *
lsg_document_header_cell_dup (const LsgDocument *doc, guint32 col)
{
  if (doc == NULL || doc->doc == NULL)
    return g_strdup ("");

  /* ls_header_cell is a WINDOW-lane call; serialize it against set_window so
   * this stays safe from any thread (the borrow is copied out immediately). */
  g_mutex_lock (doc->window_lock);
  ls_str s = ls_header_cell (doc->doc, col);
  char *copy = lsg_utf8_sanitize_dup (s.ptr, s.len);
  g_mutex_unlock (doc->window_lock);
  return copy;
}

LsgRowCount
lsg_document_row_count (const LsgDocument *doc)
{
  LsgRowCount out = { 0, FALSE };
  if (doc == NULL || doc->doc == NULL)
    return out;
  ls_row_count rc = ls_row_count_get (doc->doc);
  out.count = rc.count;
  out.exact = rc.exact;
  return out;
}

LsgScanProgress
lsg_document_index_progress (const LsgDocument *doc)
{
  LsgScanProgress out = { 0, 0, FALSE };
  if (doc == NULL || doc->doc == NULL)
    return out;
  ls_scan_progress p = ls_index_poll (doc->doc);
  out.bytes_scanned = p.bytes_scanned;
  out.bytes_total = p.bytes_total;
  out.complete = p.complete;
  return out;
}

/* ------------------------------------------------------------------------- */
/* Windowed materialize (window lane; caller-serialized)                      */
/* ------------------------------------------------------------------------- */

LsgWindow *
lsg_document_set_window (LsgDocument *doc, guint64 first_row, guint32 row_count,
                         guint32 first_col, guint32 col_count)
{
  LsgWindow *w = g_new0 (LsgWindow, 1);
  if (doc == NULL || doc->doc == NULL)
    return w;                              /* empty window; never NULL */

  g_mutex_lock (doc->window_lock);

  /* Column windowing: clamp the ABSOLUTE column range to the document's column
   * count, so a wide document's per-window fetch is O(visible columns). */
  guint32 ncols = ls_column_count (doc->doc);
  guint32 fc = (first_col > ncols) ? ncols : first_col;
  guint64 req_end = (guint64) first_col + (guint64) col_count;
  guint32 end = (req_end > (guint64) ncols) ? ncols : (guint32) req_end;
  guint32 cc = (end > fc) ? (end - fc) : 0;

  /* Materialize the row window (the core clamps row_count to LS_WINDOW_MAX_ROWS
   * and never scans; the returned range starts at first_row). */
  ls_row_range r = ls_window_set (doc->doc, first_row, row_count);
  guint32 rc = (r.row_count > (guint64) LS_WINDOW_MAX_ROWS)
                   ? LS_WINDOW_MAX_ROWS
                   : (guint32) r.row_count;

  w->first_row = r.first_row;
  w->row_count = rc;
  w->first_col = fc;
  w->col_count = cc;

  if (rc > 0)
    {
      w->oversized = g_new0 (gboolean, rc);
      w->source_row = g_new0 (guint64, rc);
      if (cc > 0)
        {
          w->cells = g_new0 (char *, (gsize) rc * cc);
          w->truncated = g_new0 (gboolean, (gsize) rc * cc);
        }

      for (guint32 ri = 0; ri < rc; ri++)
        {
          guint64 abs_row = r.first_row + ri;
          w->oversized[ri] = ls_row_oversized (doc->doc, abs_row) ? TRUE : FALSE;
          w->source_row[ri] = ls_source_row (doc->doc, abs_row);

          for (guint32 ci = 0; ci < cc; ci++)
            {
              guint32 abs_col = fc + ci;
              gsize idx = (gsize) ri * cc + ci;
              ls_str s = ls_cell (doc->doc, abs_row, abs_col);
              /* Copy immediately: no intervening ls_window_set invalidates it. */
              w->cells[idx] = lsg_utf8_sanitize_dup (s.ptr, s.len);
              w->truncated[idx] =
                  ls_cell_truncated (doc->doc, abs_row, abs_col) ? TRUE : FALSE;
            }
        }
    }

  g_mutex_unlock (doc->window_lock);
  return w;
}

/* --- LsgWindow accessors (borrowed until lsg_window_free) --- */

guint64
lsg_window_first_row (const LsgWindow *window)
{
  return (window != NULL) ? window->first_row : 0;
}

guint32
lsg_window_row_count (const LsgWindow *window)
{
  return (window != NULL) ? window->row_count : 0;
}

guint32
lsg_window_first_col (const LsgWindow *window)
{
  return (window != NULL) ? window->first_col : 0;
}

guint32
lsg_window_col_count (const LsgWindow *window)
{
  return (window != NULL) ? window->col_count : 0;
}

const char *
lsg_window_cell (const LsgWindow *window, guint32 row, guint32 col)
{
  if (window == NULL || row >= window->row_count || col >= window->col_count
      || window->cells == NULL)
    return "";
  const char *s = window->cells[(gsize) row * window->col_count + col];
  return (s != NULL) ? s : "";
}

gboolean
lsg_window_cell_truncated (const LsgWindow *window, guint32 row, guint32 col)
{
  if (window == NULL || row >= window->row_count || col >= window->col_count
      || window->truncated == NULL)
    return FALSE;
  return window->truncated[(gsize) row * window->col_count + col];
}

gboolean
lsg_window_row_oversized (const LsgWindow *window, guint32 row)
{
  if (window == NULL || row >= window->row_count || window->oversized == NULL)
    return FALSE;
  return window->oversized[row];
}

guint64
lsg_window_source_row (const LsgWindow *window, guint32 row)
{
  if (window == NULL || row >= window->row_count || window->source_row == NULL)
    return LSG_NO_ROW;
  return window->source_row[row];
}

void
lsg_window_free (LsgWindow *window)
{
  if (window == NULL)
    return;
  if (window->cells != NULL)
    {
      gsize n = (gsize) window->row_count * window->col_count;
      for (gsize i = 0; i < n; i++)
        g_free (window->cells[i]);
      g_free (window->cells);
    }
  g_free (window->truncated);
  g_free (window->oversized);
  g_free (window->source_row);
  g_free (window);
}
