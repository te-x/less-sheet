/*
 * lesssheet.h — the frozen, language-neutral cross-component contract of less-sheet.
 *
 * This single C99 header is the ENTIRE surface between the Zig core and every
 * frontend. The core (backend/) exports exactly these symbols with the C calling
 * convention; frontends (apps/macos/, …) import this header and link the static
 * library. It is frozen by the workspace-root planner: implementers on either
 * side may not change it (two-key change-request process only).
 *
 * Scope (walking-skeleton slice): open a CSV document, read the loaded head
 * window (dimensions, header suggestion, borrowed cell text), close. Later
 * slices extend this surface via the planner; nothing here promises that a
 * document is a text file, and row addressing is defined view-relative (see
 * ls_cell) so filtered views can be added later without breaking it.
 *
 * OWNERSHIP AND VALIDITY
 *   - The core owns ALL storage behind a document handle. Cell text crosses the
 *     ABI as borrowed UTF-8 bytes (pointer + length, NOT NUL-terminated) that
 *     remain valid until ls_close() is called on that document. Callers copy at
 *     their own boundary; they never free anything obtained from the core.
 *   - The accessor paths (ls_data_row_count, ls_column_count,
 *     ls_header_suggested, ls_cell, ls_header_cell) perform ZERO heap
 *     allocation and never fail.
 *   - Source files are read-only to the core: never modified, locked, or
 *     copied. Only the head region of the file is read in this slice — open
 *     cost is O(loaded head), independent of file size.
 *
 * THREADING
 *   - Accessor calls on an opened document are read-only and safe to call
 *     concurrently from multiple threads. ls_open and ls_close are not
 *     synchronized: do not call ls_close concurrently with any other call on
 *     the same document. Distinct documents are fully independent.
 *
 * TEXT AND ENCODING
 *   - Cell bytes are the raw file bytes with CSV quoting removed (see the CSV
 *     dialect below). They are assumed UTF-8 but NOT validated by the core;
 *     consumers replace invalid sequences (U+FFFD) at the display boundary.
 *   - A leading UTF-8 BOM (EF BB BF) at the start of the file is stripped
 *     before parsing and never appears in cell text.
 *
 * CSV DIALECT (pinned for this slice)
 *   - Delimiter: comma only. No delimiter sniffing.
 *   - RFC-4180 quoting: a field that begins with '"' is quoted; a doubled '""'
 *     inside a quoted field is a literal '"'; quoted fields may contain commas,
 *     CR and LF (embedded newlines do NOT end the record).
 *   - Record terminators outside quotes: LF or CRLF, equivalent. A terminator
 *     after the last record does not add a record; an empty line elsewhere is a
 *     record with a single empty field.
 *   - Column count of the document = the field count of record 1 (after BOM
 *     strip), whether record 1 is the header or data. Records with more fields
 *     are truncated to the column count; records with fewer read as empty cells
 *     at the missing positions.
 *   - An empty (0-byte, or BOM-only) file opens successfully as an empty
 *     document: 0 columns, 0 data rows, no header suggested.
 *
 * HEADER RULE (computed by the core; applied/overridden by the frontend)
 *   - Record 1 is suggested to be the header UNLESS every cell of record 1 is
 *     numeric; in that case no header is suggested and record 1 is data row 0.
 *   - "Numeric" (pinned grammar): strip ASCII whitespace (bytes 0x09..0x0D and
 *     0x20) from both ends; the remainder must be non-empty and fully match
 *         sign? ( digits ( '.' digits? )? | '.' digits ) ( ('e'|'E') sign? digits )?
 *     where sign is '+' or '-' and digits is [0-9]+. Decimal separator is '.'
 *     only. Examples: "1", "-2", "+1e5", ".5", "5.", " 12 " are numeric;
 *     "", "0x1F", "1,000", "1e", "e5", "--1", "1 2", "NaN", "inf" are not.
 *     An empty cell is NOT numeric.
 */
#ifndef LESSSHEET_H
#define LESSSHEET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Maximum number of data rows the walking-skeleton slice materializes when a
 * document is opened (the loaded "head" window; it must overfill any current
 * screen). At most one header record + this many data records are parsed.
 * Later slices replace the fixed head window with windowed viewport access.
 */
#define LS_HEAD_MAX_DATA_ROWS 200

/* Opaque document handle: one opened tabular file. Core-owned. */
typedef struct ls_doc ls_doc;

/* Result of ls_open. Failure codes are distinct and stable. */
typedef enum ls_status {
    LS_OK = 0,
    /* The path does not name an existing file. */
    LS_ERROR_NOT_FOUND = 1,
    /* The file exists but the process lacks permission to read it. */
    LS_ERROR_PERMISSION_DENIED = 2,
    /* Any other open/read failure — including paths that exist but cannot be
     * read as a file (e.g. a directory). Exists and is distinct so frontends
     * can always render a specific error. */
    LS_ERROR_IO = 3,
} ls_status;

/*
 * Borrowed text: `len` UTF-8 bytes at `ptr`. NOT NUL-terminated. `ptr` is
 * never NULL; when `len` is 0 it points to a valid address whose contents
 * must not be read. Valid until ls_close() on the owning document.
 */
typedef struct ls_str {
    const uint8_t *ptr;
    size_t len;
} ls_str;

/*
 * Open the document at `path` (non-NULL, NUL-terminated, platform path bytes)
 * and materialize its head window (at most one header record plus
 * LS_HEAD_MAX_DATA_ROWS data records, per the CSV dialect above).
 *
 * On success: returns LS_OK and stores a non-NULL handle in *out_doc.
 * On failure: returns the distinct error code and stores NULL in *out_doc.
 * `out_doc` must be non-NULL. An empty file is NOT an error (LS_OK, 0x0).
 * Reads O(loaded head) bytes regardless of file size and never blocks on
 * file length.
 */
ls_status ls_open(const char *path, ls_doc **out_doc);

/*
 * Release the document and all storage owned by it. Every ls_str borrowed
 * from this document becomes invalid. `doc` must be a handle returned by a
 * successful ls_open, closed exactly once.
 */
void ls_close(ls_doc *doc);

/*
 * Number of loaded DATA rows (excludes the suggested header record), in
 * [0, LS_HEAD_MAX_DATA_ROWS]. A file with more data records than the cap
 * loads exactly LS_HEAD_MAX_DATA_ROWS; a file with fewer loads them all.
 */
uint32_t ls_data_row_count(const ls_doc *doc);

/* Column count of the document (field count of record 1; 0 for an empty file). */
uint32_t ls_column_count(const ls_doc *doc);

/*
 * The core's header suggestion: true when record 1 is suggested to be the
 * header (i.e. NOT every cell of record 1 is numeric — see the pinned grammar
 * above). False for an empty document. When true, the header record is served
 * by ls_header_cell() and is excluded from data-row addressing; when false,
 * ls_header_cell() serves empty strings and record 1 is data row 0.
 * Frontends apply this suggestion to the display and MUST offer a user
 * override; the override is presentation state and does not involve the core.
 */
bool ls_header_suggested(const ls_doc *doc);

/*
 * Borrowed text of the data cell at (row, col), truncate/pad rule applied.
 *   row — 0-based index into the loaded data rows of the document's row set
 *         (today: the identity view — all data rows in file order). This is a
 *         view-relative logical record index, NOT a physical file line number
 *         (quoted fields may span lines; later slices add filtered views).
 *   col — 0-based column index, < ls_column_count().
 * Total function: any out-of-range (row, col) returns the empty string.
 * ZERO allocation; never fails.
 */
ls_str ls_cell(const ls_doc *doc, uint32_t row, uint32_t col);

/*
 * Borrowed text of the suggested header record's cell at `col` (truncate/pad
 * rule applied). Returns the empty string for every col when no header is
 * suggested, and for out-of-range col. ZERO allocation; never fails.
 */
ls_str ls_header_cell(const ls_doc *doc, uint32_t col);

#ifdef __cplusplus
}
#endif

#endif /* LESSSHEET_H */
