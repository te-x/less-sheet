/*
 * lsg_document.h — the GTK frontend's windowed DOCUMENT SESSION (slice 1:
 * "open + display + scroll"). This is the C analog of the macOS
 * `DocumentSession` + `CoreDocumentSession` + `DocumentSessionOpening` layer:
 * the SINGLE place that wraps the core's two-lane `ls_*` access for the viewer.
 *
 * Contract role (frozen; the prototypes/structs ARE the signatures — compiled
 * with -Werror so any drift against a stub/caller fails compilation). Symbols
 * are namespaced `lsg_` / `Lsg` / `LSG_` (the GTK frontend) to never collide
 * with the core's frozen `ls_` / `LS_` ABI in <lesssheet.h>, which this header
 * builds ON (never copies).
 *
 * WHAT SLICE 1 COVERS HERE: open a LOCAL file (`ls_open`) into a session; the
 * fixed facts (column count, dialect, header cells); the pollable row-count /
 * index progress; the WINDOW-lane materialize of a viewport (+ scroll buffer)
 * as owned, display-ready cells; per-cell truncation + per-row oversized markers
 * + the original (source) row number for the gutter; and close. A NETWORK URL
 * open produces the same `LsgDocument` and lives in <lsg_net_open.h> (adopted on
 * DONE). Find / jump / filter / streaming copy / Settings / dialect override are
 * LATER slices and are NOT part of this frozen surface yet (it grows per slice).
 *
 * OWNERSHIP (the eviction-safe borrow rule, re-expressed for C/GLib):
 *   - The core owns all bytes behind an `ls_doc`. This session COPIES every
 *     borrowed `ls_str` out immediately, sanitizing invalid UTF-8 to U+FFFD at
 *     the display boundary (see `lsg_utf8_sanitize_dup` and the ABI's
 *     pass-through-UTF-8 rule), so nothing a caller holds is tied to the core's
 *     window-eviction lifetime.
 *   - `char *` RETURNS are OWNED by the caller (free with g_free).
 *   - An `LsgWindow *` OWNS its copied cells; its `lsg_window_cell` bytes are
 *     BORROWED from it and stay valid until `lsg_window_free`.
 *
 * THREADING (mirrors <lesssheet.h> THREADING):
 *   - WINDOW LANE — `lsg_document_set_window` + the `LsgWindow` accessors:
 *     one caller thread at a time (the caller serializes these among
 *     themselves); safe concurrently with the poll/control lane and the core's
 *     background indexing.
 *   - POLL/CONTROL LANE — `lsg_document_column_count`, `_dialect`,
 *     `_has_header`, `_header_cell_dup`, `_row_count`, `_index_progress`:
 *     safe from any thread at any time.
 *   - `lsg_document_open_local` / `lsg_document_close` are exclusive (do not
 *     race any other call on the same document). `close` is idempotent.
 */
#ifndef LSG_DOCUMENT_H
#define LSG_DOCUMENT_H

#include <glib.h>
#include <lesssheet.h>

G_BEGIN_DECLS

/*
 * Document-open outcome, mirroring the core ABI's `ls_status` 1:1 with an
 * explicit success value so a single out-parameter suffices (the C analog of
 * the macOS `DocumentOpenError`, which — being an error type — omits the OK
 * case). The mapping is pinned by a frozen test against the real `LS_*` values.
 */
typedef enum {
  LSG_OPEN_OK = 0,                 /* LS_OK */
  LSG_OPEN_NOT_FOUND = 1,          /* LS_ERROR_NOT_FOUND */
  LSG_OPEN_PERMISSION_DENIED = 2,  /* LS_ERROR_PERMISSION_DENIED */
  LSG_OPEN_IO = 3,                 /* LS_ERROR_IO (incl. a path that is a directory) */
  LSG_OPEN_INVALID_ARGUMENT = 4,   /* LS_ERROR_INVALID_ARGUMENT */
} LsgOpenError;

/* Pure mapper: an `ls_status` code -> `LsgOpenError`. Total; an unrecognized
 * code maps to LSG_OPEN_IO (a specific-but-safe fallback). */
LsgOpenError lsg_open_error_from_status (ls_status status);

/* Row-count knowledge (mirrors `ls_row_count` / the macOS `RowCountInfo`):
 * `count` is exact iff `exact`, else the core's converging estimate (> 0 for
 * any non-empty document from the moment it opens). */
typedef struct {
  guint64 count;
  gboolean exact;
} LsgRowCount;

/* Background-index / scan progress (mirrors `ls_scan_progress`). For a network
 * document `bytes_total` may be LS_BYTES_TOTAL_UNKNOWN while the stream length
 * is not yet known. */
typedef struct {
  guint64 bytes_scanned;
  guint64 bytes_total;
  gboolean complete;
} LsgScanProgress;

/* Progress fraction in [0.0, 1.0] for a progress affordance: 1.0 when complete
 * or for an empty document (bytes_total == 0); 0.0 while bytes_total is unknown
 * (LS_BYTES_TOTAL_UNKNOWN); otherwise bytes_scanned / bytes_total. */
gdouble lsg_scan_progress_fraction (LsgScanProgress progress);

/* The effective dialect report — an OWNED snapshot copied out of
 * `ls_dialect_get` (mirrors `ls_dialect`). Constant for the document's
 * lifetime. `quote` is meaningful only when `has_quote`. `encoding` is a
 * concrete `LS_ENCODING_*` value (never LS_ENCODING_AUTO). */
typedef struct {
  guint8 separator;
  guint8 quote;
  gboolean has_quote;
  gboolean header;
  guint8 encoding;
  gboolean separator_forced;
  gboolean quote_forced;
  gboolean header_forced;
  gboolean encoding_forced;
} LsgDialect;

/* Opaque handles. `LsgDocument` wraps one open `ls_doc` (plus the two lane
 * locks). `LsgWindow` owns one materialized viewport of copied cells. */
typedef struct _LsgDocument LsgDocument;
typedef struct _LsgWindow LsgWindow;

/* The gutter sentinel for a row whose source number is unavailable (outside the
 * materialized window / view range) — mirrors the ABI's LS_NO_ROW. */
#define LSG_NO_ROW (G_MAXUINT64)

/* ------------------------------------------------------------------------- */
/* Open / close (exclusive)                                                   */
/* ------------------------------------------------------------------------- */

/*
 * Open the LOCAL file at `path` (NUL-terminated platform path bytes) into a
 * session, forcing the parse profile in `options` (NULL = all-LS_SNIFF +
 * LS_INDEX_AUTO, exactly like `ls_open`). On success returns a non-NULL
 * `LsgDocument *` and, if `out_error` is non-NULL, sets it to LSG_OPEN_OK. On
 * failure returns NULL and sets `*out_error` to the mapped `LsgOpenError`. An
 * empty file is NOT an error (a valid 0-column / 0-row document).
 */
LsgDocument *lsg_document_open_local (const char *path,
                                      const ls_open_options *options,
                                      LsgOpenError *out_error);

/* Release the session and its core handle (cancelling/joining any core scan
 * threads). Idempotent; nothing else may be called on `doc` afterward.
 * NULL-safe. */
void lsg_document_close (LsgDocument *doc);

/* ------------------------------------------------------------------------- */
/* Fixed facts (poll/control lane; any thread)                                */
/* ------------------------------------------------------------------------- */

/* Column count (field count of record 1; 0 for an empty document). */
guint32 lsg_document_column_count (const LsgDocument *doc);

/* The effective dialect report (copied-out snapshot). */
LsgDialect lsg_document_dialect (const LsgDocument *doc);

/* Whether record 1 is the effective header. */
gboolean lsg_document_has_header (const LsgDocument *doc);

/* The effective header label at `col` as an OWNED, U+FFFD-sanitized, NUL-
 * terminated UTF-8 string (free with g_free). Returns a fresh empty string ("")
 * when the header is off or `col` is out of range — never NULL. */
char *lsg_document_header_cell_dup (const LsgDocument *doc, guint32 col);

/* ------------------------------------------------------------------------- */
/* Row-count knowledge and index progress (poll/control lane; any thread)     */
/* ------------------------------------------------------------------------- */

/* Current row-count knowledge (never blocks). */
LsgRowCount lsg_document_row_count (const LsgDocument *doc);

/* Current index/scan progress (never blocks). */
LsgScanProgress lsg_document_index_progress (const LsgDocument *doc);

/* ------------------------------------------------------------------------- */
/* Windowed materialize (window lane; caller-serialized)                      */
/* ------------------------------------------------------------------------- */

/*
 * Declare the active viewport (+ scroll buffer) and materialize it, COLUMN-
 * WINDOWED. Materializes the rows of [first_row, first_row + row_count) that
 * lie behind the scan frontier, over the ABSOLUTE column range
 * [first_col, first_col + col_count), copying every cell out (U+FFFD-sanitized).
 * `row_count` is clamped to LS_WINDOW_MAX_ROWS and the column range is clamped
 * to the document's column count, so a wide document's per-window fetch is
 * O(visible columns), never O(column_count). NEVER scans; synchronous-fast;
 * safe on the UI thread for any row size (an over-large source row is served as
 * a bounded prefix and flagged oversized — see `lsg_window_row_oversized`).
 *
 * Returns a new OWNED `LsgWindow *` (free with `lsg_window_free`); never NULL,
 * but its `lsg_window_row_count` may be shorter than requested (or 0) when the
 * range extends beyond the frontier or the document — re-request after the
 * frontier advances (poll-driven). Row/column arguments are VIEW-relative
 * (identity view in slice 1). Issuing a new window invalidates the previous
 * one's core borrows, but a previously returned `LsgWindow` stays valid (it
 * owns its copies) until you free it.
 */
LsgWindow *lsg_document_set_window (LsgDocument *doc,
                                    guint64 first_row, guint32 row_count,
                                    guint32 first_col, guint32 col_count);

/* --- LsgWindow accessors (borrowed until lsg_window_free) --- */

/* The window's materialized geometry. `lsg_window_row_count` /
 * `lsg_window_col_count` are the ACTUAL materialized extents (row count may be
 * < requested; col count == the clamped requested range width). */
guint64 lsg_window_first_row (const LsgWindow *window);
guint32 lsg_window_row_count (const LsgWindow *window);
guint32 lsg_window_first_col (const LsgWindow *window);
guint32 lsg_window_col_count (const LsgWindow *window);

/* Cell text at WINDOW-relative (row, col) — row in [0, row_count), col in
 * [0, col_count) — as a BORROWED, valid, U+FFFD-sanitized, NUL-terminated UTF-8
 * string owned by the window (valid until `lsg_window_free`). Returns "" for
 * any out-of-range (row, col); never NULL. */
const char *lsg_window_cell (const LsgWindow *window, guint32 row, guint32 col);

/* Whether the cell at WINDOW-relative (row, col) was cut by the core's per-cell
 * display cap (`ls_cell_truncated`) — a grid draws a per-cell "…" indicator.
 * The cut is display-only. false for out-of-range. */
gboolean lsg_window_cell_truncated (const LsgWindow *window, guint32 row, guint32 col);

/* Whether the WINDOW-relative `row` is OVERSIZED (`ls_row_oversized`): its
 * source extent exceeded the per-row scan cap so it was served as a bounded
 * prefix — a grid draws a per-ROW gutter marker, distinct from the per-cell
 * indicator. false for out-of-range. */
gboolean lsg_window_row_oversized (const LsgWindow *window, guint32 row);

/* The ORIGINAL (unfiltered) 0-based data-row number of WINDOW-relative `row`
 * (`ls_source_row`) — the gutter value. Identity on servable rows without a
 * filter. Returns LSG_NO_ROW for an out-of-range row. */
guint64 lsg_window_source_row (const LsgWindow *window, guint32 row);

/* Release a window and its copied cells. NULL-safe. */
void lsg_window_free (LsgWindow *window);

/* ------------------------------------------------------------------------- */
/* Display-boundary UTF-8 sanitization                                        */
/* ------------------------------------------------------------------------- */

/*
 * Copy `len` bytes at `bytes` into a fresh OWNED, NUL-terminated UTF-8 string
 * (free with g_free), replacing every invalid/ill-formed byte sequence with
 * U+FFFD — the display-boundary rule the ABI mandates for the UTF-8 pass-through
 * path. `bytes` may be NULL only when `len` is 0 (yields ""). This is the single
 * point the session marshals borrowed core bytes into caller-safe strings.
 */
char *lsg_utf8_sanitize_dup (const guint8 *bytes, gsize len);

G_END_DECLS

#endif /* LSG_DOCUMENT_H */
