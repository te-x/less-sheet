/*
 * lesssheet.h — the frozen, language-neutral cross-component contract of less-sheet.
 *
 * This single C99 header is the ENTIRE surface between the Zig core and every
 * frontend. The core (backend/) exports exactly these symbols with the C calling
 * convention; frontends (apps/macos/, …) import this header and link the static
 * library. It is frozen by the workspace-root planner: implementers on either
 * side may not change it (two-key change-request process only).
 *
 * Scope (viewer-ui slice): open a document with an optionally forced parse
 * profile (separator / quote / header), read the effective dialect report,
 * access any contiguous row window over a file of any size (64-bit row
 * addressing), observe background indexing and row-count knowledge
 * (count + exact/estimated), and run cancellable jump-scans with progress.
 * The walking-skeleton head-window surface (LS_HEAD_MAX_DATA_ROWS, fixed head
 * accessors) is superseded by this surface.
 *
 * FORMAT NEUTRALITY
 *   - Nothing here promises that a document is a text file. The document /
 *     window / index / jump / row-count surface is format-agnostic; the
 *     dialect options and report describe the DELIMITED-TEXT parse profile
 *     (the only format this slice ships). Future formats (XLSX, Parquet)
 *     ignore the dialect options and are specified at their slices.
 *   - Row addressing is view-relative (see ls_cell): a row index addresses
 *     the document's current row set (today: the identity view — all data
 *     rows in file order), never a physical file line. Filtered views can be
 *     added later without breaking the addressing model.
 *
 * OWNERSHIP AND VALIDITY (the eviction-safe borrow rule)
 *   - The core owns ALL storage behind a document handle. Cell text crosses
 *     the ABI as borrowed UTF-8 bytes (pointer + length, NOT NUL-terminated).
 *   - Every ls_str borrowed from a document (ls_cell, ls_header_cell) remains
 *     valid until the NEXT ls_window_set() call on that document or until
 *     ls_close(), whichever comes first. ls_window_set may evict; nothing
 *     else invalidates borrows — in particular the core's own background
 *     scanning NEVER invalidates a borrow. Callers copy at their own
 *     boundary; they never free anything obtained from the core.
 *   - Allocation discipline: ls_open and ls_window_set are the only calls
 *     that may allocate. Every accessor and poll (ls_dialect_get,
 *     ls_column_count, ls_row_count_get, ls_index_poll, ls_cell,
 *     ls_header_cell, ls_jump_poll) performs ZERO heap allocation and never
 *     fails; out-of-range access returns the empty string / a well-defined
 *     value. Additionally, once a scan has reported completion (index
 *     complete, or jump state LS_JUMP_DONE with no other scan active), the
 *     core performs no further internal allocation on that document until
 *     the next mutating call.
 *   - Source files are read-only to the core: never modified, locked, or
 *     copied. Steady-state memory is O(materialized window + index
 *     checkpoints), never O(file) and never O(rows).
 *
 * OPEN COST (the cold-start contract)
 *   - ls_open performs O(head) work regardless of file size: it consumes at
 *     most LS_OPEN_HEAD_MAX_BYTES of the file (sniffing, column count,
 *     header decision, and the initial index frontier all come from this
 *     head region) and never blocks on file length. A 10 GB document opens
 *     as fast as a 10 KB one.
 *   - After a successful open the scan frontier covers at least
 *     min(total rows, LS_OPEN_READY_MIN_ROWS) rows, provided those rows fit
 *     within LS_OPEN_HEAD_MAX_BYTES — so a window at the top of the document
 *     is always served immediately.
 *   - Determinism pin: a file whose size is <= LS_OPEN_HEAD_MAX_BYTES is
 *     fully indexed by open itself — its index reports complete and its row
 *     count exact from the moment open returns (in both index modes). For
 *     larger files open stops within the byte budget (at a record boundary);
 *     where exactly is implementation detail.
 *
 * THE SCAN FRONTIER, INDEX, AND JUMPS
 *   - The core maintains a sparse row index (row -> byte offset at safe
 *     record boundaries, correct across quoted embedded newlines) and a scan
 *     FRONTIER: the point up to which records have been indexed. The
 *     frontier only ever advances (monotone) and survives jump cancellation:
 *     work behind it is paid once and rows behind it are permanently
 *     servable. Index memory is O(checkpoints), never O(rows).
 *   - With LS_INDEX_AUTO (default) a core-owned background thread starts at
 *     open and advances the frontier to EOF without blocking any accessor.
 *     With LS_INDEX_MANUAL there is no automatic advance; the frontier moves
 *     only through jump-scans (ls_jump_start). MANUAL exists for
 *     deterministic testing and cost measurement; interactive frontends use
 *     AUTO.
 *   - A jump-scan (ls_jump_start) advances the SAME frontier toward a target
 *     row, asynchronously, with pollable progress and cancellation. Targets
 *     are reached by scanning — never guessed from byte offsets.
 *
 * THREADING
 *   - ls_open / ls_close: exclusive. Do not call anything on a document
 *     concurrently with its open or close. ls_close may be called while
 *     scans are running: it cancels and joins all core-owned threads for
 *     that document before releasing storage.
 *   - Window lane — ls_window_set, ls_cell, ls_header_cell: one caller
 *     thread at a time (callers serialize these among themselves). They are
 *     safe to call concurrently with the poll/control lane and with the
 *     core's own background scanning.
 *   - Poll/control lane — ls_dialect_get, ls_column_count, ls_row_count_get,
 *     ls_index_poll, ls_jump_start, ls_jump_cancel, ls_jump_poll: safe from
 *     any thread at any time (internally synchronized), except concurrently
 *     with ls_open/ls_close on the same document.
 *   - Distinct documents are fully independent.
 *
 * TEXT AND ENCODING
 *   - Cell bytes are the raw file bytes with quoting removed per the
 *     effective dialect. They are assumed UTF-8 but NOT validated by the
 *     core; consumers replace invalid sequences (U+FFFD) at the display
 *     boundary.
 *   - A leading UTF-8 BOM (EF BB BF) at the start of the file is stripped
 *     before parsing and never appears in cell text.
 *
 * DELIMITED-TEXT DIALECT (parameterized; RFC-4180 generalized)
 *   - Effective separator: one byte. Effective quote: one byte, or NONE
 *     (quoting disabled: quote characters are literal text and no field is
 *     ever quoted).
 *   - Quoting (when a quote byte is effective): a field that begins with the
 *     quote byte is quoted; a doubled quote byte inside a quoted field is a
 *     literal quote byte; quoted fields may contain separators, CR and LF
 *     (embedded newlines do NOT end the record).
 *   - Record terminators outside quotes: LF, CRLF, or a lone CR — each ends
 *     exactly one record (CRLF counts as one terminator). A terminator after
 *     the last record does not add a record; an empty line elsewhere is a
 *     record with a single empty field.
 *   - Column count of the document = the field count of record 1 (after BOM
 *     strip) under the effective dialect, whether record 1 is the header or
 *     data. It is fixed for the document's lifetime. Records with more
 *     fields are truncated to the column count; records with fewer read as
 *     empty cells at the missing positions. A separator that never occurs
 *     yields a single-column document — that is NOT an error.
 *   - An empty (0-byte, or BOM-only) file opens successfully as an empty
 *     document: 0 columns, 0 data rows (exact), no header, index complete.
 *
 * DIALECT SNIFFING (unless forced; O(head sample) only)
 *   - Separator candidates, in tie-break preference order:
 *     ',' (0x2C), ';' (0x3B), TAB (0x09), '|' (0x7C).
 *     Quote candidates, in tie-break preference order: '"' (0x22), '\'' (0x27).
 *     The sniffer never selects NONE and never selects a value equal to a
 *     forced parameter (a forced separator is excluded from the quote
 *     candidates and vice versa).
 *   - Candidate pairs are scored for consistent field counts across the
 *     records of the head sample (exact scoring is implementation detail,
 *     with two pinned outcomes: a candidate that consistently splits records
 *     into multiple fields beats one that leaves single fields, and exact
 *     ties resolve by the preference order above — comma and double quote
 *     first). A file where no candidate splits anything sniffs as
 *     comma / double-quote and renders as a single column.
 *   - Sniffing reads only the head sample (within LS_OPEN_HEAD_MAX_BYTES);
 *     it never scans the file.
 *
 * HEADER RULE (LS_SNIFF; pinned grammar unchanged from the previous slice)
 *   - Record 1 is the header UNLESS every cell of record 1 (under the
 *     effective dialect) is numeric; in that case record 1 is data row 0.
 *   - "Numeric" (pinned grammar): strip ASCII whitespace (bytes 0x09..0x0D
 *     and 0x20) from both ends; the remainder must be non-empty and fully
 *     match
 *         sign? ( digits ( '.' digits? )? | '.' digits ) ( ('e'|'E') sign? digits )?
 *     where sign is '+' or '-' and digits is [0-9]+. Decimal separator is
 *     '.' only. Examples: "1", "-2", "+1e5", ".5", "5.", " 12 " are numeric;
 *     "", "0x1F", "1,000", "1e", "e5", "--1", "1 2", "NaN", "inf" are not.
 *     An empty cell is NOT numeric.
 *   - A forced header (LS_HEADER_ON / LS_HEADER_OFF) bypasses the grammar.
 *     An empty document reports header false regardless of forcing.
 *   - When the effective header is on, record 1 is served by ls_header_cell
 *     and is EXCLUDED from data-row addressing and row counts; when off,
 *     ls_header_cell serves empty strings and record 1 is data row 0.
 */
#ifndef LESSSHEET_H
#define LESSSHEET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------- */
/* Constants                                                                  */
/* ------------------------------------------------------------------------- */

/*
 * Sentinel for ls_open_options fields: detect this parameter from the file
 * (sniff separator/quote, apply the header grammar).
 */
#define LS_SNIFF (-1)

/* ls_open_options.quote only: quoting disabled — quote bytes are literal. */
#define LS_QUOTE_NONE (-2)

/* ls_open_options.header forced values (LS_SNIFF = apply the grammar). */
#define LS_HEADER_OFF (0)
#define LS_HEADER_ON (1)

/* ls_open_options.index_mode values (see THE SCAN FRONTIER above). */
#define LS_INDEX_AUTO (0)
#define LS_INDEX_MANUAL (1)

/*
 * Minimum rows behind the scan frontier after a successful open (when the
 * document has that many and they fit LS_OPEN_HEAD_MAX_BYTES): the first
 * screen is always served without waiting for any scan.
 */
#define LS_OPEN_READY_MIN_ROWS (512)

/* Maximum bytes of the file ls_open may consume (the O(head) bound). */
#define LS_OPEN_HEAD_MAX_BYTES (4 * 1024 * 1024)

/* ls_window_set row_count is clamped to this (bounds window memory). */
#define LS_WINDOW_MAX_ROWS (4096)

/* ------------------------------------------------------------------------- */
/* Types                                                                      */
/* ------------------------------------------------------------------------- */

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
    /* The caller broke the API contract: an ls_open_options field is outside
     * its documented domain, or the forced separator and quote collide (see
     * ls_open_options). Distinct usage error; the file is not touched. */
    LS_ERROR_INVALID_ARGUMENT = 4,
} ls_status;

/*
 * Borrowed text: `len` UTF-8 bytes at `ptr`. NOT NUL-terminated. `ptr` is
 * never NULL; when `len` is 0 it points to a valid address whose contents
 * must not be read. Validity: see OWNERSHIP AND VALIDITY (until the next
 * ls_window_set on the owning document, or ls_close).
 */
typedef struct ls_str {
    const uint8_t *ptr;
    size_t len;
} ls_str;

/*
 * Open options: the caller's forced parse profile. Field domains:
 *   separator  — LS_SNIFF, or an ASCII byte value in [0x01, 0x7F] that is
 *                neither LF (0x0A) nor CR (0x0D).
 *   quote      — LS_SNIFF, LS_QUOTE_NONE, or an ASCII byte value in
 *                [0x01, 0x7F] that is neither LF nor CR.
 *   header     — LS_SNIFF, LS_HEADER_OFF, or LS_HEADER_ON.
 *   index_mode — LS_INDEX_AUTO or LS_INDEX_MANUAL.
 * A forced separator equal to a forced quote byte is invalid. Any field
 * outside its domain (or the collision) fails with
 * LS_ERROR_INVALID_ARGUMENT. Forcing a parameter equal to a SNIFF-resolved
 * value of the other is legal: sniffing simply excludes the forced byte from
 * its candidates. The struct is copied by ls_open; the caller keeps
 * ownership.
 */
typedef struct ls_open_options {
    int32_t separator;
    int32_t quote;
    int32_t header;
    int32_t index_mode;
} ls_open_options;

/*
 * The effective dialect report: what was sniffed and/or forced at open —
 * exactly what dialect UI (guess-pills) renders. Constant for the document's
 * lifetime. For an empty document: separator/quote report the forced values
 * or the sniff defaults (',' and '"'), header is false.
 */
typedef struct ls_dialect {
    /* The effective separator byte. */
    uint8_t separator;
    /* The effective quote byte; meaningful only when has_quote is true. */
    uint8_t quote;
    /* False = quoting disabled (LS_QUOTE_NONE): quote bytes are literal. */
    bool has_quote;
    /* True when record 1 is the header (forced or per the pinned grammar). */
    bool header;
    /* Which parameters the caller forced (vs. sniffed/grammar-derived). */
    bool separator_forced;
    bool quote_forced;
    bool header_forced;
} ls_dialect;

/*
 * Row-count knowledge. `exact` is true iff the index is complete (then
 * `count` equals the true data-record count, header excluded — also
 * immediately true for documents fully indexed by open, including empty
 * ones). While estimating, `count` is derived from file bytes / mean indexed
 * row bytes: it is > 0 for any non-empty document from the moment open
 * returns, and it converges as the frontier advances.
 */
typedef struct ls_row_count {
    uint64_t count;
    bool exact;
} ls_row_count;

/* A contiguous, half-open row range [first_row, first_row + row_count). */
typedef struct ls_row_range {
    uint64_t first_row;
    uint64_t row_count;
} ls_row_range;

/*
 * Background-index progress. bytes_scanned counts file bytes behind the
 * frontier (monotone non-decreasing over the document's lifetime, including
 * across cancelled jumps); bytes_total is the file size. complete is true
 * iff every record is indexed (bytes_scanned == bytes_total) — from then on
 * ls_row_count_get reports exact. Empty file: {0, 0, true}.
 */
typedef struct ls_scan_progress {
    uint64_t bytes_scanned;
    uint64_t bytes_total;
    bool complete;
} ls_scan_progress;

/* State of the document's (single) jump slot. */
typedef enum ls_jump_state {
    /* No jump since open, or the last jump was cancelled. */
    LS_JUMP_IDLE = 0,
    /* A scan toward the target is running. */
    LS_JUMP_SCANNING = 1,
    /* The jump finished; landed_row is valid. Persists until the next
     * ls_jump_start. */
    LS_JUMP_DONE = 2,
} ls_jump_state;

/*
 * Jump progress snapshot. `progress` is the fraction of the scan distance
 * toward the target covered so far, in [0.0, 1.0] — monotone non-decreasing
 * within one jump, and exactly 1.0 when state is LS_JUMP_DONE (the distance
 * measurement axis is implementation detail). `landed_row` is meaningful
 * only when state is LS_JUMP_DONE: the target row, clamped to the last data
 * row when the target lies at/past EOF (0 for a document with no data rows).
 */
typedef struct ls_jump_status {
    ls_jump_state state;
    double progress;
    uint64_t landed_row;
} ls_jump_status;

/* ------------------------------------------------------------------------- */
/* Lifecycle                                                                  */
/* ------------------------------------------------------------------------- */

/*
 * Open the document at `path` (non-NULL, NUL-terminated, platform path
 * bytes) with the given options; `options` may be NULL, meaning all-LS_SNIFF
 * + LS_INDEX_AUTO. Performs the O(head) work described above (sniff, column
 * count, header decision, initial frontier) and, under LS_INDEX_AUTO, starts
 * the background indexer.
 *
 * On success: returns LS_OK and stores a non-NULL handle in *out_doc.
 * On failure: returns the distinct error code and stores NULL in *out_doc.
 * `out_doc` must be non-NULL. An empty file is NOT an error (LS_OK; empty
 * document). Option-domain violations fail with LS_ERROR_INVALID_ARGUMENT
 * before any file access.
 *
 * A dialect change is a re-open: close the document and open the same path
 * with the new forced options (the index restarts — that is the documented
 * cost of changing the parse profile).
 */
ls_status ls_open(const char *path, const ls_open_options *options, ls_doc **out_doc);

/*
 * Release the document and all storage owned by it, first cancelling and
 * joining any core-owned scan threads. Every ls_str borrowed from this
 * document becomes invalid. `doc` must be a handle returned by a successful
 * ls_open, closed exactly once.
 */
void ls_close(ls_doc *doc);

/* ------------------------------------------------------------------------- */
/* Document facts (constant after open; zero-alloc; total)                    */
/* ------------------------------------------------------------------------- */

/* The effective dialect report (see ls_dialect). */
ls_dialect ls_dialect_get(const ls_doc *doc);

/* Column count of the document (field count of record 1; 0 for an empty
 * document). Fixed for the document's lifetime. */
uint32_t ls_column_count(const ls_doc *doc);

/* ------------------------------------------------------------------------- */
/* Row-count knowledge and index progress (zero-alloc; any thread)            */
/* ------------------------------------------------------------------------- */

/* Current row-count knowledge (see ls_row_count). */
ls_row_count ls_row_count_get(const ls_doc *doc);

/* Current index/scan progress (see ls_scan_progress). */
ls_scan_progress ls_index_poll(const ls_doc *doc);

/* ------------------------------------------------------------------------- */
/* Windowed row access                                                        */
/* ------------------------------------------------------------------------- */

/*
 * Declare the caller's active row window and materialize it. `row_count` is
 * clamped to LS_WINDOW_MAX_ROWS. Synchronously materializes the rows of
 * [first_row, first_row + row_count) that lie BEHIND the scan frontier and
 * evicts previously materialized rows outside the new window; returns the
 * contiguous materialized range, which always starts at first_row (row_count
 * 0 when no requested row is behind the frontier or in the document).
 *
 * ls_window_set NEVER advances the frontier and never scans: cost is
 * O(window bytes) re-lexing from the nearest index checkpoint, so it is the
 * only synchronous-fast path and is safe to call on the UI thread. Rows
 * beyond the frontier become servable by advancing the frontier (background
 * index or ls_jump_start) and then re-issuing ls_window_set with the same
 * range. May allocate (through the document's allocator); on internal
 * failure it degrades to a shorter (possibly empty) returned range — it
 * never fails. Invalidates all previously borrowed ls_str of this document.
 *
 * Eviction guarantee: a row evicted and later re-materialized serves
 * byte-identical cell text (re-lexed from the same file bytes).
 */
ls_row_range ls_window_set(ls_doc *doc, uint64_t first_row, uint32_t row_count);

/*
 * Borrowed text of the data cell at (row, col), truncate/pad rule applied.
 *   row — 0-based, 64-bit view-relative data-row index (the effective header
 *         record is not a data row). Only rows inside the currently
 *         materialized window are served.
 *   col — 0-based column index, < ls_column_count().
 * Total function: any (row, col) outside the materialized window / column
 * range returns the empty string. ZERO allocation; never fails; never
 * scans.
 */
ls_str ls_cell(const ls_doc *doc, uint64_t row, uint32_t col);

/*
 * Borrowed text of the effective header record's cell at `col` (truncate/pad
 * rule applied). Returns the empty string for every col when the effective
 * header is off, and for out-of-range col. Header cells are materialized at
 * open (they are not subject to window eviction, but the borrow-validity
 * rule is the same). ZERO allocation; never fails.
 */
ls_str ls_header_cell(const ls_doc *doc, uint32_t col);

/* ------------------------------------------------------------------------- */
/* Jump-scans (asynchronous; shared frontier; any thread)                     */
/* ------------------------------------------------------------------------- */

/*
 * Start (or retarget) the document's jump toward `target_row` (0-based data
 * row). A previous unfinished jump is implicitly cancelled (its frontier
 * gains are kept). Never blocks the caller:
 *   - If the target is already behind the frontier — or the row count is
 *     exact and the target is at/past EOF (clamp) — the jump completes
 *     BEFORE this call returns: ls_jump_poll immediately reports
 *     LS_JUMP_DONE with the (clamped) landed_row and no scan runs.
 *   - Otherwise an asynchronous scan advances the shared frontier toward
 *     the target (in both index modes), observable via ls_jump_poll, and
 *     completes when the frontier covers the target or EOF clamps it
 *     (reaching EOF makes the row count exact).
 * On a document with no data rows a jump completes immediately with
 * landed_row 0.
 */
void ls_jump_start(ls_doc *doc, uint64_t target_row);

/*
 * Cancel the active jump, if any (no-op otherwise). After this call
 * returns, ls_jump_poll reports LS_JUMP_IDLE — unless the jump had already
 * completed, in which case LS_JUMP_DONE persists. All frontier progress made
 * by the cancelled scan is KEPT (paid once); under LS_INDEX_AUTO the
 * background indexer continues independently. Restoring the viewport is the
 * caller's affair (the core does not track viewport positions).
 */
void ls_jump_cancel(ls_doc *doc);

/* Current jump status snapshot (see ls_jump_status). ZERO allocation. */
ls_jump_status ls_jump_poll(const ls_doc *doc);

#ifdef __cplusplus
}
#endif

#endif /* LESSSHEET_H */
