/*
 * lesssheet.h — the frozen, language-neutral cross-component contract of less-sheet.
 *
 * This single C99 header is the ENTIRE surface between the Zig core and every
 * frontend. The core (backend/) exports exactly these symbols with the C calling
 * convention; frontends (apps/macos/, …) import this header and link the static
 * library. It is frozen by the workspace-root planner: implementers on either
 * side may not change it (two-key change-request process only).
 *
 * Scope (viewer-ui + find-seek + csv-hardening slices): open a document with
 * an optionally forced parse profile (separator / quote / header / ENCODING),
 * read the effective dialect report (now including the resolved encoding),
 * access any contiguous row window over a file of any size (64-bit row
 * addressing) with per-cell text served UTF-8 and capped to a display size,
 * observe background indexing and row-count knowledge (count + exact/
 * estimated), run cancellable jump-scans with progress, and run streaming
 * content SEARCHES: text and column-predicate match-scans with bounded
 * per-block match counts, match navigation (next/previous), and pollable
 * progress — sharing the single scan slot with jumps. The walking-skeleton
 * head-window surface is superseded.
 *
 * csv-hardening adds two things to the delimited-text path without changing
 * any existing signature: (1) ENCODING — the core detects (or is forced to)
 * one of UTF-8, UTF-16 LE/BE, ISO-8859-1 (Latin-1), or Windows-1252 and
 * transcodes to UTF-8 internally so the ABI stays byte-clean (see TEXT AND
 * ENCODING); (2) a per-cell DISPLAY CAP of LS_CELL_MAX_BYTES so a pathological
 * giant cell or first record can never make open O(file) or blow window
 * memory (see the cap and ls_cell_truncated / ls_header_cell_truncated).
 *
 * FORMAT NEUTRALITY
 *   - Nothing here promises that a document is a text file. The document /
 *     window / index / jump / row-count / search surface is format-agnostic;
 *     the dialect options and report describe the DELIMITED-TEXT parse
 *     profile (the only format this slice ships). Future formats (XLSX,
 *     Parquet) ignore the dialect options and are specified at their slices.
 *   - Row addressing is view-relative (see ls_cell): a row index addresses
 *     the document's current row set (today: the identity view — all data
 *     rows in file order), never a physical file line. Filtered views can be
 *     added later without breaking the addressing model. The search-job
 *     handle is deliberately opaque state on the document so a later slice
 *     can promote a search into a view definition.
 *
 * OWNERSHIP AND VALIDITY (the eviction-safe borrow rule)
 *   - The core owns ALL storage behind a document handle. Cell text crosses
 *     the ABI as borrowed UTF-8 bytes (pointer + length, NOT NUL-terminated).
 *   - Every ls_str borrowed from a document (ls_cell, ls_header_cell) remains
 *     valid until the NEXT ls_window_set() call on that document or until
 *     ls_close(), whichever comes first. ls_window_set may evict; nothing
 *     else invalidates borrows — in particular the core's own background
 *     scanning (indexing, jump-scans, AND match-scans) NEVER invalidates a
 *     borrow. Callers copy at their own boundary; they never free anything
 *     obtained from the core.
 *   - Allocation discipline: ls_open, ls_window_set, ls_search_start, and
 *     ls_search_nav are the only CALLS that may allocate (running background
 *     scans may also allocate internally for index/count storage). Every
 *     accessor and poll (ls_dialect_get, ls_column_count, ls_row_count_get,
 *     ls_index_poll, ls_cell, ls_cell_truncated, ls_header_cell,
 *     ls_header_cell_truncated, ls_jump_poll, ls_search_poll) and
 *     ls_jump_cancel / ls_search_cancel performs ZERO heap allocation and
 *     never fails; out-of-range access returns the empty string / a
 *     well-defined value. Additionally, once every scan has reported a
 *     terminal state (index complete or idle, jump slot not LS_JUMP_SCANNING,
 *     search not LS_SEARCH_SCANNING), the core performs no further internal
 *     allocation on that document until the next mutating call
 *     (ls_window_set, ls_jump_start, ls_search_start, ls_search_nav).
 *   - Source files are read-only to the core: never modified, locked, or
 *     copied. Steady-state memory is O(materialized window + index
 *     checkpoints), never O(file) and never O(rows). A search adds
 *     O(index checkpoints) count storage + O(1) job state — see SEARCH.
 *
 * OPEN COST (the cold-start contract)
 *   - ls_open performs O(head) work regardless of file size: it consumes at
 *     most LS_OPEN_HEAD_MAX_BYTES of the file (encoding detection, transcode,
 *     sniffing, column count, header decision, and the initial index frontier
 *     all come from this head region) and never blocks on file length. A 10 GB
 *     document opens as fast as a 10 KB one, in every encoding: the O(head)
 *     bound is measured in SOURCE bytes (bytes faulted from the file), so a
 *     giant first record or first cell cannot make open O(file) either (see
 *     the column-count / record-1 rule and LS_CELL_MAX_BYTES). The search
 *     machinery is lazy: it costs nothing (no storage, no threads, no scan
 *     work) until the first ls_search_start on the document.
 *   - After a successful open the scan frontier covers at least
 *     min(total rows, LS_OPEN_READY_MIN_ROWS) rows, provided those rows fit
 *     within LS_OPEN_HEAD_MAX_BYTES — so a window at the top of the document
 *     is always served immediately.
 *   - Determinism pin: a file whose SIZE (source bytes) is <=
 *     LS_OPEN_HEAD_MAX_BYTES is fully indexed by open itself — its index
 *     reports complete and its row count exact from the moment open returns
 *     (in both index modes), whatever its encoding. For larger files open
 *     stops within the byte budget (at a record boundary), measured in source
 *     bytes; where exactly is implementation detail.
 *
 * THE SCAN FRONTIER, INDEX, AND JUMPS
 *   - The core maintains a sparse row index (row -> byte offset at safe
 *     record boundaries, correct across quoted embedded newlines) and a scan
 *     FRONTIER: the point up to which records have been indexed. The
 *     frontier only ever advances (monotone) and survives job cancellation:
 *     work behind it is paid once and rows behind it are permanently
 *     servable. Index memory is O(checkpoints), never O(rows).
 *   - With LS_INDEX_AUTO (default) a core-owned background thread starts at
 *     open and advances the frontier to EOF without blocking any accessor.
 *     With LS_INDEX_MANUAL there is no automatic advance; the frontier moves
 *     only through jump-scans and match-scans. MANUAL exists for
 *     deterministic testing and cost measurement; interactive frontends use
 *     AUTO.
 *   - A jump-scan (ls_jump_start) advances the SAME frontier toward a target
 *     row, asynchronously, with pollable progress and cancellation. Targets
 *     are reached by scanning — never guessed from byte offsets.
 *
 * SEARCH (MATCH-SCANS, COUNTS, AND NAVIGATION — find-seek slice)
 *   - A document has at most ONE active search: the request passed to the
 *     most recent successful ls_search_start. Starting a new search replaces
 *     the previous one ENTIRELY: counts reset, the navigation slot resets to
 *     LS_SEARCH_NAV_NONE with found/position fields zeroed, and the match-
 *     scan restarts from row 0. A failed (rejected) start changes NOTHING.
 *   - Matching is defined PER CELL on the cell's FULL transcoded UTF-8 text
 *     (quoting removed, the column-count truncate/pad rule applied: a missing
 *     cell of a ragged record is the empty string). It scans the WHOLE cell,
 *     NOT the LS_CELL_MAX_BYTES-capped bytes ls_cell serves — the display cap
 *     is presentation-only (see TEXT AND ENCODING). A match, and its reported
 *     column/position, can therefore lie past the bytes a frontend can display
 *     (the ls_cell_truncated flag signals more exists; frontends clamp any
 *     in-cell highlight to the served bytes). Only DATA rows are evaluated;
 *     the effective header record is never searched. A row matches when any
 *     in-scope cell matches (TEXT) or the target column's cell matches
 *     (PREDICATE). The match column reported for a row is the lowest-indexed
 *     in-scope matching column (TEXT) / the predicate column (PREDICATE).
 *     Matching semantics per kind are pinned at ls_search_request.
 *   - THE MATCH-SCAN (started by ls_search_start) sweeps data rows from row
 *     0 toward EOF, evaluating the matcher per row and maintaining match
 *     COUNTS per index block (the sparse row-index checkpoint granularity).
 *     It never materializes a list of match rows: search memory is
 *     O(index checkpoints) + O(1) job state, independent of match density.
 *     The counted region is contiguous from row 0; counts are exact for the
 *     counted region, never estimated. `total` (m) is the number of matching
 *     rows counted so far — monotone within one search — and is final
 *     exactly when the scan completes (state LS_SEARCH_DONE, total_exact
 *     true). Behind the byte frontier the match-scan re-lexes from the mmap
 *     (disk-bound, fast); beyond it, it advances the SHARED frontier exactly
 *     like a jump-scan (paid once, kept — every byte feeds the row index).
 *   - NAVIGATION (ls_search_nav) is streaming: find the nearest matching row
 *     from an anchor in a direction (semantics pinned at ls_search_nav),
 *     asynchronously. When the answer is already determined by the counted
 *     region, the nav completes BEFORE the call returns (O(one block
 *     re-lex), never O(file)); otherwise the match-scan serves it as it
 *     advances, keeping the counted region contiguous — which is why a found
 *     match ALWAYS has an exact 1-based `position` (n) among all matching
 *     rows, with total >= position. Found results persist in the poll until
 *     the next ls_search_nav or ls_search_start.
 *   - THE SINGLE SCAN SLOT: search jobs and jump jobs share the document's
 *     one background-scan slot. Pinned interaction with ls_jump_*:
 *       - A successful ls_search_start takes the slot: a jump in
 *         LS_JUMP_SCANNING is cancelled (its poll reports LS_JUMP_IDLE, its
 *         frontier gains are kept); a completed jump's LS_JUMP_DONE persists.
 *       - An ls_jump_start that must SCAN (target beyond the frontier with
 *         an inexact count) takes the slot: a search in LS_SEARCH_SCANNING
 *         becomes LS_SEARCH_CANCELLED (terminal; counts, found results, and
 *         frontier gains are kept; a pending LS_SEARCH_NAV_SEARCHING resolves
 *         to LS_SEARCH_NAV_NONE). A jump that completes before returning
 *         (target behind the frontier, or EOF clamp with an exact count)
 *         does NOT disturb a running search.
 *       - An ls_search_nav that must scan re-engages the slot for the search
 *         (cancelling a scanning jump as above). On a CANCELLED search this
 *         RESUMES the match-scan — state returns to LS_SEARCH_SCANNING —
 *         but only as far as the nav needs: at the nav's terminal the state
 *         is LS_SEARCH_DONE if the scan reached EOF, else LS_SEARCH_CANCELLED
 *         again. Counts are never lost; progress stays monotone.
 *       - ls_search_cancel stops the search's scanning (state
 *         LS_SEARCH_CANCELLED; LS_SEARCH_DONE persists; a pending
 *         LS_SEARCH_NAV_SEARCHING resolves to LS_SEARCH_NAV_NONE). It never
 *         affects the jump slot. The AUTO background indexer is independent
 *         of the slot and continues regardless.
 *   - PROGRESS: ls_search_status.progress is the fraction of the match-scan's
 *     total work covered so far, in [0.0, 1.0] — monotone non-decreasing
 *     within one search (including across cancel/resume), exactly 1.0 when
 *     state is LS_SEARCH_DONE, frozen at its last value when CANCELLED (the
 *     measurement axis is implementation detail, as for jumps).
 *   - Search state belongs to the document handle. A dialect change is a
 *     re-open (ls_close + ls_open) and therefore invalidates ALL search
 *     state: a fresh handle polls LS_SEARCH_IDLE with an all-zero snapshot.
 *
 * THREADING
 *   - ls_open / ls_close: exclusive. Do not call anything on a document
 *     concurrently with its open or close. ls_close may be called while
 *     scans are running (jump-scans AND match-scans): it cancels and joins
 *     all core-owned threads for that document before releasing storage.
 *   - Window lane — ls_window_set, ls_cell, ls_header_cell: one caller
 *     thread at a time (callers serialize these among themselves). They are
 *     safe to call concurrently with the poll/control lane and with the
 *     core's own background scanning.
 *   - Poll/control lane — ls_dialect_get, ls_column_count, ls_row_count_get,
 *     ls_index_poll, ls_jump_start, ls_jump_cancel, ls_jump_poll,
 *     ls_search_start, ls_search_nav, ls_search_cancel, ls_search_poll: safe
 *     from any thread at any time (internally synchronized), except
 *     concurrently with ls_open/ls_close on the same document.
 *   - Distinct documents are fully independent.
 *
 * TEXT AND ENCODING (source encoding detection + internal transcode to UTF-8)
 *   - Every cell / header byte crossing this ABI is UTF-8. The core resolves
 *     ONE source encoding at open (constant for the document's lifetime; a new
 *     choice is a re-open) from a fixed set, and transcodes on demand:
 *       * UTF-8 (detected or forced): PASS-THROUGH. Bytes are handed through
 *         unchanged and are NOT validated by the core; consumers replace
 *         invalid sequences with U+FFFD at the display boundary. An invalid
 *         UTF-8 byte therefore survives in the served cell (Option A: the
 *         UTF-8 path never rewrites bytes). Search matches over these same
 *         pass-through bytes (see ls_search_request for the byte-level rule).
 *       * UTF-16 LE, UTF-16 BE, ISO-8859-1 (Latin-1), Windows-1252: TRANSCODED
 *         to guaranteed-VALID UTF-8. Latin-1 maps all 256 byte values (never
 *         U+FFFD from decoding); Windows-1252's five undefined bytes
 *         (0x81 0x8D 0x8F 0x90 0x9D) and any ill-formed / lone-surrogate
 *         UTF-16 code unit map to U+FFFD.
 *   - DETECTION (encoding == LS_ENCODING_AUTO, the default), on the raw head
 *     bytes, before dialect sniffing, in this order:
 *       1. BOM: EF BB BF -> UTF-8; FF FE -> UTF-16LE; FE FF -> UTF-16BE.
 *       2. NUL-ratio heuristic (BOM-less): a head sample dominated by NUL
 *          bytes in one alternating parity of positions resolves UTF-16 — LE
 *          when the NULs fall on odd offsets (48 00 65 00 ...), BE on even
 *          (00 48 00 65 ...). The exact threshold is implementation detail.
 *       3. UTF-8 validation of the head sample -> UTF-8 (a multibyte sequence
 *          cut by the head boundary does not fail detection).
 *       4. Otherwise ISO-8859-1 (Latin-1) — the never-lose-a-byte 8-bit
 *          default. (No statistical charset guessing; head-only detection can
 *          miss an 8-bit file whose first non-ASCII byte is past the head —
 *          the caller then forces the encoding, which re-opens correctly.)
 *   - FORCING (encoding == one of LS_ENCODING_UTF8..LS_ENCODING_WINDOWS1252)
 *     bypasses detection entirely: the head and every window are decoded as
 *     the forced encoding. A forced UTF-16 LE/BE is honored with or without a
 *     BOM. A leading BOM that MATCHES the resolved encoding (forced or
 *     detected) is consumed before parsing and never appears in a cell — the
 *     UTF-8 BOM strip generalizes to the resolved encoding's BOM (UTF-8
 *     EF BB BF, UTF-16LE FF FE, UTF-16BE FE FF).
 *   - Transcoding is streaming and windowed: index checkpoints are byte
 *     offsets in the SOURCE file; a window transcodes only its source byte
 *     range on demand; jump / search / index scans read source bytes. Nothing
 *     transcodes the whole file; cell memory scales with the window + sparse
 *     index, never the file (UTF-8 is zero-copy pass-through). The O(head)
 *     open bound is on source bytes (see OPEN COST); transcoded output may be
 *     larger (Latin-1 high bytes double, UTF-16 ASCII halves) but reads no
 *     more file.
 *   - DISPLAY CAP: ls_cell and ls_header_cell serve at most LS_CELL_MAX_BYTES
 *     of a cell's transcoded UTF-8, cut at a UTF-8 code-point boundary (never
 *     a split code point). ls_cell_truncated / ls_header_cell_truncated report
 *     whether a served cell was cut. This cap is DISPLAY-ONLY: it never alters
 *     the source file, and SEARCH scans the full cell, not the capped bytes
 *     (see SEARCH and ls_search_request). Normal cells (<= the cap) are served
 *     whole with the flag false.
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
 *   - BOUNDED RECORD 1: if record 1 does not terminate within the O(head)
 *     source-byte budget (a multi-hundred-MB first line, or a giant
 *     unterminated quoted cell), the document still opens — it does NOT error.
 *     The column count is the number of fields decoded within the budget
 *     (always >= 1), the final in-progress field is display-truncated (its
 *     ls_cell_truncated / ls_header_cell_truncated flag set), and the header
 *     decision runs on those (capped) record-1 cells. This extends the capped-
 *     record mechanism (which defers a record spilling past the budget beyond
 *     record 1) to make record 1 itself safe and keep open O(head).
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
 *     This grammar is shared verbatim by the search surface: the ordering
 *     predicates (see ls_search_op) parse cells and values with it.
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

/*
 * Text encoding of the source file (ls_open_options.encoding and, resolved,
 * ls_dialect.encoding — see TEXT AND ENCODING). LS_ENCODING_AUTO is the detect
 * sentinel (options only; negative, in the LS_SNIFF / LS_QUOTE_NONE style) and
 * is NEVER reported in ls_dialect.encoding, which always names a concrete
 * resolved encoding. The concrete values are stable uint8 enum values.
 */
#define LS_ENCODING_AUTO (-1)        /* options only: detect from the head. */
#define LS_ENCODING_UTF8 (0)
#define LS_ENCODING_UTF16LE (1)
#define LS_ENCODING_UTF16BE (2)
#define LS_ENCODING_LATIN1 (3)       /* ISO-8859-1 (maps all 256 byte values). */
#define LS_ENCODING_WINDOWS1252 (4)

/*
 * Maximum UTF-8 bytes ls_cell / ls_header_cell serve for a single cell (the
 * per-cell DISPLAY CAP). A larger cell is served truncated at a UTF-8 code-
 * point boundary (<= this many bytes) and flagged by ls_cell_truncated /
 * ls_header_cell_truncated. Display-only: SEARCH still scans the full cell.
 */
#define LS_CELL_MAX_BYTES (4096)

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
 *   encoding   — LS_ENCODING_AUTO (detect), or one of LS_ENCODING_UTF8,
 *                LS_ENCODING_UTF16LE, LS_ENCODING_UTF16BE, LS_ENCODING_LATIN1,
 *                LS_ENCODING_WINDOWS1252 (force). See TEXT AND ENCODING.
 * A forced separator equal to a forced quote byte is invalid. Any field
 * outside its domain (or the collision) fails with
 * LS_ERROR_INVALID_ARGUMENT. Forcing a parameter equal to a SNIFF-resolved
 * value of the other is legal: sniffing simply excludes the forced byte from
 * its candidates. Encoding is orthogonal to the dialect parameters (forcing/
 * detecting it bypasses none of them). The struct is copied by ls_open; the
 * caller keeps ownership.
 */
typedef struct ls_open_options {
    int32_t separator;
    int32_t quote;
    int32_t header;
    int32_t index_mode;
    int32_t encoding;
} ls_open_options;

/*
 * The effective dialect report: what was sniffed/detected and/or forced at
 * open — exactly what dialect UI (guess-pills, the encoding picker) renders.
 * Constant for the document's lifetime. For an empty document: separator/quote
 * report the forced values or the sniff defaults (',' and '"'), header is
 * false, and encoding is the forced value, or UTF-8 (or the BOM's encoding for
 * a UTF-16 BOM-only file).
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
    /* The effective (resolved) source encoding: one concrete LS_ENCODING_*
     * value (UTF8 / UTF16LE / UTF16BE / LATIN1 / WINDOWS1252) — NEVER
     * LS_ENCODING_AUTO. In AUTO mode this is what detection chose; when forced
     * it echoes the forced value. */
    uint8_t encoding;
    /* Which parameters the caller forced (vs. sniffed/detected/grammar-
     * derived). encoding_forced mirrors the others for the encoding picker. */
    bool separator_forced;
    bool quote_forced;
    bool header_forced;
    bool encoding_forced;
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
 * across cancelled jobs); bytes_total is the file size. complete is true
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
    /* No jump since open, or the last jump was cancelled (by ls_jump_cancel
     * or by a search taking the scan slot). */
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
/* Search types (see the SEARCH section above for the job model)              */
/* ------------------------------------------------------------------------- */

/* The two match kinds of ls_search_request. */
typedef enum ls_search_kind {
    /* Substring text match over a set of columns, with smart case. */
    LS_SEARCH_TEXT = 0,
    /* Single-column typed predicate (operator + value). */
    LS_SEARCH_PREDICATE = 1,
} ls_search_kind;

/*
 * Predicate operators. EQ/NE compare BYTE-EXACTLY; LT/GT/LE/GE compare
 * NUMERICALLY (see ls_search_request for the pinned semantics).
 */
typedef enum ls_search_op {
    LS_SEARCH_OP_EQ = 0, /* =  */
    LS_SEARCH_OP_NE = 1, /* ≠  */
    LS_SEARCH_OP_LT = 2, /* <  */
    LS_SEARCH_OP_GT = 3, /* >  */
    LS_SEARCH_OP_LE = 4, /* ≤  */
    LS_SEARCH_OP_GE = 5, /* ≥  */
} ls_search_op;

/* Navigation direction (see ls_search_nav for the pinned anchor semantics). */
typedef enum ls_search_dir {
    LS_SEARCH_FORWARD = 0,
    LS_SEARCH_BACKWARD = 1,
} ls_search_dir;

/* State of the document's (single) search job. */
typedef enum ls_search_state {
    /* No search since open. The whole snapshot is zero. */
    LS_SEARCH_IDLE = 0,
    /* The match-scan (and/or a navigation it serves) is running. */
    LS_SEARCH_SCANNING = 1,
    /* The match-scan covered every data row: `total` is final
     * (total_exact true), progress is exactly 1.0. Terminal until the next
     * ls_search_start. */
    LS_SEARCH_DONE = 2,
    /* The match-scan stopped before EOF (ls_search_cancel, or a jump-scan
     * took the slot). Counts, found results, progress, and frontier gains
     * are kept, frozen at their last values. Terminal — except that an
     * ls_search_nav needing uncovered rows resumes scanning (see SEARCH). */
    LS_SEARCH_CANCELLED = 3,
} ls_search_state;

/* State of the search job's (single) navigation slot. */
typedef enum ls_search_nav_state {
    /* No navigation requested since this search started. */
    LS_SEARCH_NAV_NONE = 0,
    /* A navigation is pending (being served by the scan). */
    LS_SEARCH_NAV_SEARCHING = 1,
    /* The navigation found a match: found_row / found_col / position are
     * valid and persist until the next ls_search_nav or ls_search_start. */
    LS_SEARCH_NAV_FOUND = 2,
    /* The navigation exhausted its direction: no matching row exists
     * at-or-after (FORWARD) / strictly-before (BACKWARD) the anchor.
     * Terminal for that navigation. */
    LS_SEARCH_NAV_EXHAUSTED = 3,
} ls_search_nav_state;

/*
 * A search request. The struct and every buffer it points to are borrowed
 * only for the DURATION of the ls_search_start call: the core copies what it
 * keeps; the caller retains ownership. `request` semantics:
 *
 *   kind == LS_SEARCH_TEXT — substring match with SMART CASE:
 *     - value_ptr/value_len: the UTF-8 query bytes (len > 0 required; the
 *       empty query means "no search" and is rejected).
 *     - A cell matches when the query occurs as a byte substring of the cell
 *       text. If the query contains at least one ASCII uppercase byte
 *       (0x41..0x5A) the comparison is byte-exact. Otherwise it is
 *       case-insensitive over ASCII ONLY: bytes 0x41..0x5A compare equal to
 *       their lowercase forms; every other byte — including all bytes >=
 *       0x80, i.e. all non-ASCII UTF-8 — compares exactly. (Full Unicode
 *       folding is out of scope; ASCII smart case is the pinned v1 rule.)
 *     - scope_ptr/scope_len: the set of column indices to evaluate (each <
 *       ls_column_count; duplicates permitted and redundant). NULL scope_ptr
 *       means ALL columns. A non-NULL scope with scope_len == 0, or any
 *       out-of-range index, rejects the request. Frontends pass their
 *       visible-column set; the scope is FIXED for the search's lifetime
 *       (visibility changes apply from the next ls_search_start).
 *     - column / op are ignored.
 *
 *   kind == LS_SEARCH_PREDICATE — single-column typed comparison:
 *     - column: the target column (< ls_column_count, else rejected). Any
 *       column may be targeted (hidden ones included — hiding is a frontend
 *       presentation concept).
 *     - value_ptr/value_len: the comparison value bytes.
 *     - LS_SEARCH_OP_EQ / NE: the cell matches iff its bytes are exactly
 *       equal / not equal to the value bytes. NO case folding, NO whitespace
 *       trimming. The empty value is legal (EQ matches empty cells,
 *       including the padded cells of ragged records).
 *     - LS_SEARCH_OP_LT / GT / LE / GE: numeric. The cell matches iff BOTH
 *       the cell and the value parse under the pinned numeric grammar (see
 *       HEADER RULE — the same grammar, verbatim) AND the parsed values
 *       compare accordingly. A non-numeric cell NEVER matches an ordering
 *       operator. A non-numeric VALUE rejects the request at
 *       ls_search_start (frontends validate first; the core enforces).
 *       Comparison is by MATHEMATICAL value and EXACT: sign, digits, and
 *       exponent are compared arithmetically, never rounded through binary
 *       floating point — "2.0" equals "2", "1e2" equals "100", a 40-digit
 *       integer orders correctly against its neighbor, and "1e400" > "1e399"
 *       even though both overflow a double. (Sole documented latitude:
 *       exponent values beyond int64 may saturate.)
 *     - scope_ptr/scope_len are ignored.
 *
 *   value_ptr may be NULL only when value_len is 0.
 */
typedef struct ls_search_request {
    ls_search_kind kind;
    ls_search_op op;
    uint32_t column;
    const uint8_t *value_ptr;
    size_t value_len;
    const uint32_t *scope_ptr;
    size_t scope_len;
} ls_search_request;

/*
 * Search job snapshot (see the SEARCH section for the full model).
 *   state       — job state; IDLE means "no search since open" (all other
 *                 fields zero).
 *   nav         — navigation slot state.
 *   progress    — match-scan work fraction in [0.0, 1.0]; monotone within
 *                 one search (across cancel/resume); exactly 1.0 when DONE;
 *                 frozen when CANCELLED.
 *   found_row   — the matched data row; valid only when nav is FOUND.
 *   found_col   — the matched column (lowest in-scope matching column for
 *                 TEXT; the predicate column for PREDICATE); valid only when
 *                 nav is FOUND.
 *   position    — 1-based position (n) of found_row among ALL matching rows
 *                 in file order; valid only when nav is FOUND, and then
 *                 always exact, with total >= position.
 *   total       — matching rows counted so far (m); exact for the counted
 *                 region; monotone within one search.
 *   total_exact — true iff the match-scan completed (state DONE): `total`
 *                 is the final match count and stops growing.
 */
typedef struct ls_search_status {
    ls_search_state state;
    ls_search_nav_state nav;
    double progress;
    uint64_t found_row;
    uint32_t found_col;
    uint64_t position;
    uint64_t total;
    bool total_exact;
} ls_search_status;

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
 * cost of changing the parse profile — and all search state is gone: the
 * new handle polls LS_SEARCH_IDLE).
 */
ls_status ls_open(const char *path, const ls_open_options *options, ls_doc **out_doc);

/*
 * Release the document and all storage owned by it, first cancelling and
 * joining any core-owned scan threads (background index, jump-scans, and
 * match-scans — calling ls_close during any of them is safe). Every ls_str
 * borrowed from this document becomes invalid. `doc` must be a handle
 * returned by a successful ls_open, closed exactly once.
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
 * index, ls_jump_start, or a match-scan) and then re-issuing ls_window_set
 * with the same range. May allocate (through the document's allocator); on
 * internal failure it degrades to a shorter (possibly empty) returned range
 * — it never fails. Invalidates all previously borrowed ls_str of this
 * document.
 *
 * Eviction guarantee: a row evicted and later re-materialized serves
 * byte-identical cell text (re-lexed from the same file bytes).
 */
ls_row_range ls_window_set(ls_doc *doc, uint64_t first_row, uint32_t row_count);

/*
 * Borrowed text of the data cell at (row, col): quoting removed, the
 * column-count truncate/pad rule applied, then DISPLAY-CAPPED to at most
 * LS_CELL_MAX_BYTES of UTF-8 (cut at a code-point boundary; see TEXT AND
 * ENCODING). ls_cell_truncated reports whether that cap cut this cell.
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
 * Whether the cell ls_cell(doc, row, col) serves was cut by the
 * LS_CELL_MAX_BYTES display cap (its full transcoded content is longer than
 * the served bytes). Same (row, col) domain and window/borrow rules as
 * ls_cell; returns false for any cell ls_cell serves whole and for every
 * out-of-range / unmaterialized (row, col). The cut is display-only — SEARCH
 * still matches the full cell. ZERO allocation; never fails; never scans.
 */
bool ls_cell_truncated(const ls_doc *doc, uint64_t row, uint32_t col);

/*
 * Borrowed text of the effective header record's cell at `col`: column-count
 * truncate/pad rule applied, then DISPLAY-CAPPED exactly like ls_cell.
 * Returns the empty string for every col when the effective header is off,
 * and for out-of-range col. Header cells are materialized at open (they are
 * not subject to window eviction, but the borrow-validity rule is the same).
 * ZERO allocation; never fails.
 */
ls_str ls_header_cell(const ls_doc *doc, uint32_t col);

/*
 * Whether the header cell ls_header_cell(doc, col) serves was cut by the
 * LS_CELL_MAX_BYTES display cap. Returns false when the effective header is
 * off, for out-of-range col, and for any header cell served whole. Same
 * display-only semantics as ls_cell_truncated. ZERO allocation; never fails.
 */
bool ls_header_cell_truncated(const ls_doc *doc, uint32_t col);

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
 *     LS_JUMP_DONE with the (clamped) landed_row, no scan runs, and a
 *     running search is NOT disturbed.
 *   - Otherwise an asynchronous scan advances the shared frontier toward
 *     the target (in both index modes), observable via ls_jump_poll, and
 *     completes when the frontier covers the target or EOF clamps it
 *     (reaching EOF makes the row count exact). Taking the scan slot
 *     cancels a search in LS_SEARCH_SCANNING (it becomes
 *     LS_SEARCH_CANCELLED; its counts, found results, and frontier gains
 *     are kept — see SEARCH).
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

/* ------------------------------------------------------------------------- */
/* Search (asynchronous match-scans + navigation; shared scan slot;           */
/* any thread — see the SEARCH section for the full job model)                */
/* ------------------------------------------------------------------------- */

/*
 * Start the document's search for `request` (non-NULL; borrowed only for
 * this call — the core copies what it keeps). Validates the request first:
 *
 *   returns false — request rejected, and NOTHING changes (no slot is
 *   taken, a previous search and a running jump are untouched) — when:
 *     - kind or op (PREDICATE) is outside its enum domain;
 *     - TEXT: value_len == 0 (the empty query means "no search"), or
 *       scope_ptr != NULL with scope_len == 0, or any scope index >=
 *       ls_column_count;
 *     - PREDICATE: column >= ls_column_count, or the operator is
 *       LT/GT/LE/GE and the value does not parse under the pinned numeric
 *       grammar (such a predicate could never match — the core refuses to
 *       run a pointless scan).
 *
 *   returns true — the search REPLACES any previous search entirely (counts
 *   reset; nav LS_SEARCH_NAV_NONE with found/position zeroed) and the
 *   match-scan starts from row 0, taking the scan slot (a jump in
 *   LS_JUMP_SCANNING is cancelled to LS_JUMP_IDLE; LS_JUMP_DONE persists).
 *   Never blocks: the scan is asynchronous, observable via ls_search_poll
 *   (state is LS_SEARCH_SCANNING, or already LS_SEARCH_DONE for a document
 *   with nothing to scan). Note that starting a search performs NO
 *   navigation: issue ls_search_nav(doc, 0, LS_SEARCH_FORWARD) for
 *   "first match in the file".
 *
 * May allocate (count storage sized by the index checkpoints — O(index
 * checkpoints) regardless of match density; see SEARCH).
 */
bool ls_search_start(ls_doc *doc, const ls_search_request *request);

/*
 * Request a navigation on the active search: find the nearest matching row
 *   FORWARD  — the FIRST matching row with row >= anchor_row;
 *   BACKWARD — the LAST matching row with row < anchor_row (STRICTLY).
 * This asymmetry is deliberate: it makes every navigation expressible with
 * plain uint64 anchors — first-in-file = (0, FORWARD); next-after-R =
 * (R + 1, FORWARD); previous-before-R = (R, BACKWARD); last-in-file =
 * (UINT64_MAX, BACKWARD), since no data row can have index UINT64_MAX.
 * "Previous" from the first match is therefore a core-uniform EXHAUSTED
 * (the frontend wraps).
 *
 * Replaces the pending navigation, if any (only one at a time). Never
 * blocks beyond the sanctioned fast path:
 *   - If the answer is already determined by the counted region — the
 *     nearest match in `dir` lies within it, or the counted region already
 *     proves exhaustion — the navigation completes BEFORE this call returns
 *     (LS_SEARCH_NAV_FOUND / LS_SEARCH_NAV_EXHAUSTED; cost O(one block
 *     re-lex), never O(file)). After LS_SEARCH_DONE every navigation takes
 *     this path.
 *   - Otherwise the match-scan serves it as it advances (resuming a
 *     CANCELLED scan — see SEARCH), reporting LS_SEARCH_NAV_SEARCHING until
 *     found/exhausted. A nav that must scan takes the scan slot (cancelling
 *     a jump in LS_JUMP_SCANNING).
 * No-op when no search is active (state LS_SEARCH_IDLE). May allocate.
 */
void ls_search_nav(ls_doc *doc, uint64_t anchor_row, ls_search_dir dir);

/*
 * Stop the active search's scanning, if any (no-op otherwise — including
 * after LS_SEARCH_DONE, which persists). After this call returns,
 * ls_search_poll reports LS_SEARCH_CANCELLED: counts, found results, and
 * progress freeze at their last values (exact for the counted region); a
 * pending LS_SEARCH_NAV_SEARCHING resolves to LS_SEARCH_NAV_NONE. All
 * frontier gains are KEPT. The jump slot and the AUTO background indexer
 * are unaffected. ZERO allocation.
 */
void ls_search_cancel(ls_doc *doc);

/* Current search snapshot (see ls_search_status). Before the first
 * ls_search_start on this handle: state LS_SEARCH_IDLE and every other
 * field zero. ZERO allocation; never fails. */
ls_search_status ls_search_poll(const ls_doc *doc);

#ifdef __cplusplus
}
#endif

#endif /* LESSSHEET_H */
