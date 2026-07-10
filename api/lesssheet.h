/*
 * lesssheet.h — the frozen, language-neutral cross-component contract of less-sheet.
 *
 * This single C99 header is the ENTIRE surface between the Zig core and every
 * frontend. The core (backend/) exports exactly these symbols with the C calling
 * convention; frontends (apps/macos/, …) import this header and link the static
 * library. It is frozen by the workspace-root planner: implementers on either
 * side may not change it (two-key change-request process only).
 *
 * Scope (viewer-ui + find-seek + csv-hardening + filtered-views + select-copy
 * slices):
 * open a document with
 * an optionally forced parse profile (separator / quote / header / ENCODING),
 * read the effective dialect report (now including the resolved encoding),
 * access any contiguous row window over a file of any size (64-bit row
 * addressing) with per-cell text served UTF-8 and capped to a display size,
 * observe background indexing and row-count knowledge (count + exact/
 * estimated), run cancellable jump-scans with progress, and run streaming
 * content SEARCHES: text and column-predicate match-scans with bounded
 * per-block match counts, match navigation (next/previous), and pollable
 * progress — sharing the single scan slot with jumps. filtered-views adds a
 * derived FILTER view over the same machinery: set a filter from an
 * ls_search_request and the row accessors, jumps, and searches then operate
 * in FILTERED coordinates (row i = the i-th matching data row), with each
 * match's original row number retrievable — see FILTERED VIEWS. select-copy
 * adds ls_cell_copy: a bounded, window-INDEPENDENT LOSSLESS read of a single
 * cell's COMPLETE transcoded content into a caller-owned buffer (up to a
 * caller-provided byte cap), so a frontend can faithfully copy cells whose
 * content runs past the ls_cell display cap — see FULL-CELL READ. The
 * walking-skeleton head-window surface is superseded.
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
 *     the document's current row set (the identity view — all data rows in
 *     file order — by default, or a FILTER view while one is active), never
 *     a physical file line. A filter is a second view kind over the same
 *     document (see FILTERED VIEWS); it does not change the addressing model.
 *     The search-job
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
 *     scanning (indexing, jump-scans, match-scans, AND filter-scans) NEVER
 *     invalidates a
 *     borrow. Callers copy at their own boundary; they never free anything
 *     obtained from the core. ls_cell_copy is the exception that proves the
 *     rule: it does NOT borrow — it COPIES a cell's bytes into a caller-owned
 *     buffer, so its output is owned by the caller and is NOT invalidated by a
 *     later ls_window_set (on any thread). See FULL-CELL READ.
 *   - Allocation discipline: ls_open, ls_window_set, ls_search_start,
 *     ls_search_nav, and ls_filter_set are the only CALLS that may allocate
 *     (running background
 *     scans may also allocate internally for index/count storage). Every
 *     accessor and poll (ls_dialect_get, ls_column_count, ls_row_count_get,
 *     ls_index_poll, ls_cell, ls_cell_truncated, ls_header_cell,
 *     ls_header_cell_truncated, ls_jump_poll, ls_search_poll, ls_filter_poll,
 *     ls_source_row, ls_row_oversized, ls_cell_copy) and ls_jump_cancel / ls_search_cancel /
 *     ls_filter_clear
 *     performs ZERO heap allocation and
 *     never fails; out-of-range access returns the empty string / a
 *     well-defined value. Additionally, once every scan has reported a
 *     terminal state (index complete or idle, jump slot not LS_JUMP_SCANNING,
 *     search not LS_SEARCH_SCANNING, filter not LS_FILTER_SCANNING), the core
 *     performs no further internal allocation on that document until the next
 *     mutating call (ls_window_set, ls_jump_start, ls_search_start,
 *     ls_search_nav, ls_filter_set).
 *   - Source files are read-only to the core: never modified, locked, or
 *     copied. Steady-state memory is O(materialized window + index
 *     checkpoints), never O(file) and never O(rows). A search adds
 *     O(index checkpoints) count storage + O(1) job state — see SEARCH. A
 *     filter adds the same O(index checkpoints) counter storage + O(1) mode
 *     state (never a match-row list) — see FILTERED VIEWS.
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
 *     work) until the first ls_search_start on the document. The filter
 *     machinery is likewise lazy: nothing until the first ls_filter_set.
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
 * FILTERED VIEWS (filtered-views slice — a derived row view, counters not lists)
 *   - A document has at most ONE active FILTER: a VIEW MODE set from an
 *     ls_search_request (the SAME request type, grammar, and validation as
 *     ls_search_start) by ls_filter_set, and removed by ls_filter_clear. A
 *     filter is a view mode, not a transient job: once set it PERSISTS until
 *     cleared or the document is re-opened, regardless of scan-slot contention.
 *   - THE FILTERED VIEW. While a filter is active the document PRESENTS ONLY
 *     the data rows that satisfy the filter predicate, indexed 0..m-1 in file
 *     order (row i = the i-th matching data row). ALL row-addressing accessors
 *     reinterpret their row arguments AND results in these FILTERED
 *     coordinates:
 *       * ls_row_count_get — reports m (matching rows); see COUNT below.
 *       * ls_window_set / ls_cell / ls_cell_truncated / ls_cell_copy — address
 *         and serve the matching rows and their cells (every cell rule
 *         unchanged: quoting, the truncate/pad rule, the LS_CELL_MAX_BYTES
 *         display cap and flag; ls_cell_copy reads the FULL cell — FULL-CELL
 *         READ — in these same filtered coordinates).
 *       * ls_jump_* — target is an ORIGINAL data-row number; see JUMP below.
 *       * ls_search_* — the find predicate is evaluated only over rows that
 *         satisfy the filter; see FIND below.
 *     The effective HEADER record is NOT a data row and is UNAFFECTED:
 *     ls_header_cell / ls_header_cell_truncated are unchanged by a filter.
 *     With NO filter (LS_FILTER_IDLE) every accessor behaves exactly as
 *     specified elsewhere in this header — the identity view is the "m == all
 *     data rows" case, and ls_source_row(doc, i) == i for a servable row.
 *   - COUNTERS, NOT LISTS (memory). The matching rows are tracked with
 *     per-block match COUNTERS aligned to the sparse row-index checkpoints (the
 *     SEARCH mechanism), NEVER a materialized list of matching row numbers.
 *     Filter memory is O(index checkpoints) + O(1) mode state, INDEPENDENT of
 *     the match count — a filter over a 10 GB file with millions of matches
 *     uses the same bounded memory as the base index. Mapping a filtered index
 *     to/from its source row, and materializing a filtered window, are served
 *     by counting into blocks (O(checkpoints)) plus a bounded in-block re-lex
 *     (O(window)); NEVER O(m).
 *   - THE FILTER-SCAN & FRONTIER. ls_filter_set starts a streaming FILTER-SCAN
 *     that sweeps data rows from row 0 toward EOF, tallying the per-block match
 *     counts and advancing the SHARED scan frontier exactly like a match-scan
 *     (every byte it scans also feeds the base row index — paid once). It does
 *     NOT scan the whole file before returning: the first screen of matching
 *     rows is servable as soon as they are found behind the frontier
 *     (O(viewport)), and the scan continues in the background with pollable
 *     progress. The filter's COUNTED REGION is contiguous from row 0; its
 *     discovered-match frontier is MONOTONE (only advances, never regresses)
 *     and survives slot contention.
 *   - THE SINGLE SCAN SLOT (now three contenders: jump, find, filter). The
 *     filter-scan shares the document's one background-scan slot with
 *     jump-scans and match-scans:
 *       * ls_filter_set takes the slot for the filter-scan: a jump in
 *         LS_JUMP_SCANNING is cancelled (LS_JUMP_IDLE, frontier gains kept) and
 *         any active search is RESET (see RESET below).
 *       * An ls_jump_start that must scan, or an ls_search_start / ls_search_nav
 *         that must scan, TAKES the slot from a running filter-scan: the filter
 *         goes LS_FILTER_CANCELLED (counts, progress, and frontier gains kept,
 *         frozen at their last values) but the filter MODE PERSISTS — the view
 *         stays filtered and already-counted rows stay servable.
 *       * Under LS_INDEX_AUTO the filter-scan is a background view-completion
 *         job: it converges to LS_FILTER_DONE (m exact, progress 1.0) WITHOUT
 *         further caller input, whatever jumps/finds intervene (mirroring the
 *         AUTO indexer's drive to completion). Under LS_INDEX_MANUAL it advances
 *         only while it owns the slot: after slot contention it stays
 *         LS_FILTER_CANCELLED until re-driven (ls_filter_set again, or a
 *         filtered jump/find that re-engages the slot and advances the
 *         frontier).
 *   - COUNT (ls_row_count_get and ls_filter_status.total). While a filter is
 *     active BOTH report the SAME value: the number of matching rows COUNTED SO
 *     FAR (m) — exact for the counted region, MONOTONE non-decreasing within one
 *     filter, and FINAL exactly when the filter-scan completes (LS_FILTER_DONE:
 *     total_exact and ls_row_count.exact both true). It is 0 while scanning has
 *     found no match yet, and exactly 0 (exact) for a completed filter that
 *     matches nothing. This mirrors the base row count during indexing (a
 *     converging lower bound that becomes exact), so a frontend renders "N of M
 *     rows" with N growing alongside the scan %.
 *   - SOURCE ROWS (ls_source_row). For any view row currently SERVABLE (inside
 *     the materialized window), ls_source_row returns its ORIGINAL (unfiltered)
 *     0-based data-row number — the gutter value. Total, zero-alloc; identical
 *     window/borrow domain to ls_cell; returns LS_NO_ROW for a row outside the
 *     materialized window or the view's row range. Without a filter it is the
 *     identity on servable rows (ls_source_row(doc, i) == i).
 *   - JUMP under a filter. ls_jump_start's target_row is interpreted as an
 *     ORIGINAL data-row number: the jump advances the filter-scan (with
 *     progress) to the FIRST matching row whose original index >= target_row and
 *     reports THAT row's FILTERED index as ls_jump_status.landed_row (clamped to
 *     the last match when target_row is at/after EOF; 0 when the filtered view
 *     has no rows). Behind the filter frontier it completes before the call
 *     returns (no scan), as jumps do today.
 *   - FIND under a filter. ls_search_* operates entirely in FILTERED
 *     coordinates: ls_search_nav anchors and found_row are FILTERED indices, and
 *     the find predicate is evaluated ONLY over rows that satisfy the filter.
 *     total and position count rows satisfying BOTH the filter and the find
 *     predicate; navigation (first/next/previous, wrap) moves within the
 *     filtered view. Counts are exact for the scanned region and converge with
 *     progress, exactly as Find does without a filter. Filter and find share the
 *     single slot (above).
 *   - RESET. Setting a filter, clearing a filter, and a dialect/encoding re-open
 *     each RESET any active search (the coordinate space changed):
 *     ls_search_poll returns LS_SEARCH_IDLE with an all-zero snapshot. A re-open
 *     (ls_close + ls_open — a new document identity) ADDITIONALLY clears the
 *     filter: a fresh handle polls LS_FILTER_IDLE. Setting or clearing a filter
 *     also returns the jump slot to LS_JUMP_IDLE (a scanning jump is cancelled
 *     with its frontier gains kept; a completed jump's landing does not persist
 *     across the coordinate change).
 *   - LAZINESS & COST. The filter machinery costs nothing until the first
 *     ls_filter_set (no storage, no scan). Setting a filter is O(viewport) to
 *     the first matching rows plus a background scan; it never reads the whole
 *     file before returning and never blocks the caller. Re-deriving a filtered
 *     window behind the frontier is O(window) re-lex + O(checkpoints) counting —
 *     safe on the caller/UI thread (ls_window_set never scans, in either view).
 *
 * THREADING
 *   - ls_open / ls_close: exclusive. Do not call anything on a document
 *     concurrently with its open or close. ls_close may be called while
 *     scans are running (jump-scans, match-scans, AND filter-scans): it
 *     cancels and joins
 *     all core-owned threads for that document before releasing storage.
 *   - Window lane — ls_window_set, ls_cell, ls_source_row, ls_row_oversized,
 *     ls_header_cell:
 *     one caller
 *     thread at a time (callers serialize these among themselves). They are
 *     safe to call concurrently with the poll/control lane and with the
 *     core's own background scanning.
 *   - Poll/control lane — ls_dialect_get, ls_column_count, ls_row_count_get,
 *     ls_index_poll, ls_jump_start, ls_jump_cancel, ls_jump_poll,
 *     ls_search_start, ls_search_nav, ls_search_cancel, ls_search_poll,
 *     ls_filter_set, ls_filter_clear, ls_filter_poll, ls_cell_copy: safe from
 *     any thread at any time (internally synchronized), except
 *     concurrently with ls_open/ls_close on the same document. ls_cell_copy in
 *     particular is safe on a background (copy) worker WHILE the window lane
 *     runs on another thread: it is window-INDEPENDENT (neither reads nor
 *     evicts the materialized window) and copies into the caller's buffer, so a
 *     frontend can copy a large selection off-thread while the UI keeps
 *     scrolling (ls_window_set / ls_cell) undisturbed.
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
 *     whole with the flag false. For a LOSSLESS read of a cell's COMPLETE
 *     transcoded content PAST this display cap (e.g. clipboard copy), use
 *     ls_cell_copy, which fills a caller buffer up to a caller-provided byte
 *     cap — see FULL-CELL READ.
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
 * ls_source_row sentinel: the given view row is not currently servable
 * (outside the materialized window, or beyond the view's row range). No data
 * row can have this index. See FILTERED VIEWS.
 */
#define LS_NO_ROW (UINT64_MAX)

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

/*
 * Per-row SOURCE-byte scan cap for the SYNCHRONOUS window path (ls_window_set).
 * While materializing a window the core scans at most this many source bytes
 * per row seeking that row's terminator; a row whose source extent exceeds this
 * cap is served as a bounded PREFIX (the fields decoded within the cap, the
 * last display-capped, any remaining columns padded to the empty string) and
 * flagged by ls_row_oversized. This bounds ls_window_set to
 * O(min(row bytes, this) x rows), so it is safe on the UI thread for ANY row
 * size; finding a huge row's true end (to reach later rows and to count it) is
 * the background frontier's job, off the caller thread.
 *
 * DISTINCT from LS_CELL_MAX_BYTES, and both apply: that caps a single cell's
 * OUTPUT (display) bytes; this caps the SOURCE bytes SCANNED for a whole row
 * (and is far larger). Cells within the scanned prefix are still individually
 * display-capped by LS_CELL_MAX_BYTES / flagged by ls_cell_truncated.
 */
#define LS_WINDOW_ROW_SCAN_MAX_BYTES (1024 * 1024)

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
/* Filter types (see the FILTERED VIEWS section above for the view model)      */
/* ------------------------------------------------------------------------- */

/* State of the document's (single) filter — its scan-slot occupancy. */
typedef enum ls_filter_state {
    /* No filter active: the IDENTITY view. The whole snapshot is zero. */
    LS_FILTER_IDLE = 0,
    /* A filter is active and its filter-scan is advancing. */
    LS_FILTER_SCANNING = 1,
    /* A filter is active and its filter-scan covered every data row: `total`
     * is final (total_exact true), progress is exactly 1.0. */
    LS_FILTER_DONE = 2,
    /* A filter is active but its filter-scan stopped before EOF (a jump-scan
     * or match-scan took the slot). Counts, progress, and frontier gains are
     * kept, frozen at their last values; the filter MODE persists (the view is
     * still filtered). See FILTERED VIEWS for when it resumes. */
    LS_FILTER_CANCELLED = 3,
} ls_filter_state;

/*
 * Filter snapshot (see the FILTERED VIEWS section for the full model). Like
 * ls_search_status without the navigation slot.
 *   state       — filter/scan state; LS_FILTER_IDLE means "no filter active"
 *                 (the identity view, every other field zero). SCANNING / DONE
 *                 / CANCELLED all mean a filter IS active (the view is
 *                 filtered).
 *   progress    — filter-scan work fraction in [0.0, 1.0]; monotone within one
 *                 filter; exactly 1.0 at LS_FILTER_DONE; frozen when CANCELLED.
 *   total       — matching rows counted so far (m); exact for the counted
 *                 region; monotone within one filter. While a filter is active
 *                 this equals ls_row_count_get().count.
 *   total_exact — true iff the filter-scan completed (LS_FILTER_DONE): `total`
 *                 is the final match count and stops growing.
 */
typedef struct ls_filter_status {
    ls_filter_state state;
    double progress;
    uint64_t total;
    bool total_exact;
} ls_filter_status;

/* ------------------------------------------------------------------------- */
/* Full-cell read result (select-copy slice — see FULL-CELL READ)             */
/* ------------------------------------------------------------------------- */

/*
 * Result of ls_cell_copy, the bounded full-cell read. Distinct, stable values.
 */
typedef enum ls_copy_result {
    /* The cell was read: *out_len UTF-8 bytes (<= buf_len) were written to
     * buf, and *out_truncated is true iff the cell's full transcoded content
     * is longer than those bytes (it was cut). An empty cell is LS_COPY_OK
     * with *out_len 0 and *out_truncated false. */
    LS_COPY_OK = 0,
    /* `row` lies at/beyond the scan frontier: its byte offset is not yet known,
     * so it is not yet servable, and nothing was written. Advance the frontier
     * toward it with ls_jump_start (which reports progress) and retry —
     * ls_cell_copy itself never scans and never advances the frontier. */
    LS_COPY_PENDING = 1,
    /* No such cell exists — col >= ls_column_count(), or `row` is at/beyond the
     * view's row count when that count is EXACT (past the last row), or the
     * document is empty; nothing was written. Distinct from LS_COPY_PENDING:
     * retrying will NOT help (do not jump). While the row count is still an
     * estimate, a row past the frontier is LS_COPY_PENDING, not this. */
    LS_COPY_NO_CELL = 2,
} ls_copy_result;

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
 * cost of changing the parse profile — all search state is gone AND any
 * filter is cleared: the new handle polls LS_SEARCH_IDLE and LS_FILTER_IDLE).
 */
ls_status ls_open(const char *path, const ls_open_options *options, ls_doc **out_doc);

/*
 * Release the document and all storage owned by it, first cancelling and
 * joining any core-owned scan threads (background index, jump-scans,
 * match-scans, and filter-scans — calling ls_close during any is safe). Every ls_str
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

/* Current row-count knowledge (see ls_row_count). While a filter is active
 * this is the matching-row count m, in filtered coordinates — see FILTERED
 * VIEWS. */
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
 * ls_window_set NEVER advances the frontier and never scans past the per-row
 * cap: cost is O(min(row bytes, LS_WINDOW_ROW_SCAN_MAX_BYTES) x rows) re-lexing
 * from the nearest index checkpoint, so it is the only synchronous-fast path
 * and is safe to call on the UI thread for ANY row size (this was "O(window
 * bytes)", which held only when every row was bounded). A row whose source
 * extent exceeds the per-row scan cap is served as a bounded PREFIX and flagged
 * by ls_row_oversized (see it); its true end is found later by the background
 * frontier, after which rows AFTER it become servable. Rows beyond the frontier
 * become servable by advancing the frontier (background index, ls_jump_start,
 * or a match-scan) and then re-issuing ls_window_set with the same range. May allocate (through the document's allocator); on
 * internal failure it degrades to a shorter (possibly empty) returned range
 * — it never fails. Invalidates all previously borrowed ls_str of this
 * document.
 *
 * While a filter is active, first_row/row_count are in FILTERED coordinates
 * and the window serves matching rows (O(window) re-lex + O(checkpoints)
 * counting — still no scan) — see FILTERED VIEWS.
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
 *         record is not a data row; a FILTERED index while a filter is
 *         active — see FILTERED VIEWS). Only rows inside the currently
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

/*
 * Whether view row `row` is OVERSIZED: its SOURCE extent exceeded
 * LS_WINDOW_ROW_SCAN_MAX_BYTES, so ls_window_set served it as a bounded PREFIX
 * (the fields decoded within the per-row scan cap — the last display-capped,
 * any remaining columns the empty string) instead of the whole row. True means
 * MORE SOURCE EXISTS past the served cells and the row's true end may lie past
 * this window; the cells that ARE served still obey every normal rule (quoting,
 * the truncate/pad rule, the LS_CELL_MAX_BYTES display cap + ls_cell_truncated).
 *
 * This is a PER-ROW signal, DISTINCT from the per-cell ls_cell_truncated (the
 * OUTPUT display cap on one cell): a normal row may have a display-capped cell
 * without being oversized, and an oversized row's served cell(s) may or may not
 * be display-capped. Frontends draw a per-row gutter marker from this, distinct
 * from the per-cell truncation indicator.
 *
 *   row — 0-based, 64-bit view-relative data-row index (a FILTERED index while
 *         a filter is active — see FILTERED VIEWS), interpreted exactly as
 *         ls_cell / ls_source_row interpret it. Only rows inside the currently
 *         materialized window are defined.
 * Total function: returns false for any `row` outside the materialized window
 * or the view's row range, and for any row served whole. Identical window/borrow
 * domain to ls_cell / ls_source_row (set by ls_window_set alongside the served
 * cells). ZERO allocation; never fails; never scans.
 */
bool ls_row_oversized(const ls_doc *doc, uint64_t row);

/* ------------------------------------------------------------------------- */
/* Full-cell read (select-copy slice; window-INDEPENDENT; any thread)          */
/* ------------------------------------------------------------------------- */

/*
 * Copy the COMPLETE content of the data cell at (row, col) — the same cell
 * ls_cell addresses (quoting removed, the column-count truncate/pad rule
 * applied, transcoded to UTF-8 per the resolved encoding) — into the caller's
 * buffer, WITHOUT the LS_CELL_MAX_BYTES display cap. This is the LOSSLESS
 * full-cell read the display-capped ls_cell cannot provide (a cell longer than
 * the display cap is searchable but not readable through ls_cell); a frontend
 * uses it to copy a selection to the clipboard faithfully.
 *
 *   row, col — addressed exactly as ls_cell: 0-based, 64-bit, view-relative
 *              (a FILTERED index while a filter is active — see FILTERED VIEWS;
 *              col is a physical column index). UNLIKE ls_cell, ls_cell_copy is
 *              INDEPENDENT of the materialized window: it does not require,
 *              consult, or disturb ls_window_set's window — it serves ANY row
 *              the core can already locate without scanning.
 *   buf, buf_len — the caller's output buffer and its capacity in bytes;
 *              buf_len is the read's byte cap. buf may be NULL only when buf_len
 *              is 0. The core writes at most buf_len UTF-8 bytes, cut at a UTF-8
 *              code-point boundary (never a split code point), so the written
 *              bytes are always valid UTF-8 (for valid source).
 *   out_len, out_truncated — out-params (both non-NULL). On LS_COPY_OK,
 *              *out_len is the byte count written (<= buf_len) and *out_truncated
 *              is true iff the cell's full content exceeds them. On
 *              LS_COPY_PENDING / LS_COPY_NO_CELL, *out_len is 0 and
 *              *out_truncated is false (nothing was written).
 *
 * Returns LS_COPY_OK, LS_COPY_PENDING, or LS_COPY_NO_CELL (see ls_copy_result).
 * A cell that fits is copied whole (*out_truncated false); one that exceeds
 * buf_len is copied to exactly the boundary-cut prefix that fits (*out_truncated
 * true). Servable rows are those the core can locate WITHOUT scanning — the
 * same rows behind the scan frontier that ls_window_set can materialize (plus
 * the pinned bounded record-1 row 0); a row at/beyond the frontier is
 * LS_COPY_PENDING until the frontier advances over it (ls_jump_start / the AUTO
 * indexer), exactly as such rows become servable to ls_window_set.
 *
 * COST is bounded: O(min(source bytes to reach and decode the cell,
 * LS_WINDOW_ROW_SCAN_MAX_BYTES)) + O(min(cell bytes, buf_len)) output — the
 * SAME per-row SOURCE-byte bound as ls_window_set, so it is safe on ANY thread
 * for ANY row size and never blocks. For an OVERSIZED row (source extent to the
 * target cell exceeds LS_WINDOW_ROW_SCAN_MAX_BYTES — see ls_row_oversized) the
 * cell is served as a bounded prefix (possibly empty, for a column past the
 * source bound) with *out_truncated true; ls_cell_copy never re-lexes a giant
 * row's full bytes.
 *
 * OWNERSHIP: ls_cell_copy does NOT borrow — it COPIES into the caller's buffer,
 * which the caller owns. Its output therefore has NO tie to the ls_str eviction
 * rule: a subsequent ls_window_set (on this or any thread) never affects bytes
 * already written. ZERO heap allocation; never fails (always a well-defined
 * ls_copy_result). Poll/control lane — safe from ANY thread at any time,
 * concurrently with the window lane and background scans (see THREADING), which
 * is what lets a frontend copy a large selection off the UI thread.
 */
ls_copy_result ls_cell_copy(const ls_doc *doc, uint64_t row, uint32_t col,
                            uint8_t *buf, size_t buf_len,
                            size_t *out_len, bool *out_truncated);

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
 *
 * While a filter is active, target_row is an ORIGINAL data-row number and
 * landed_row is the FILTERED index of the nearest matching row at/after it
 * — see FILTERED VIEWS.
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

/* ------------------------------------------------------------------------- */
/* Filtered views (set/clear a filter; poll it; map a view row to its source; */
/* the row accessors + jump + search operate in filtered coordinates while a  */
/* filter is active — see the FILTERED VIEWS section for the full model)       */
/* ------------------------------------------------------------------------- */

/*
 * Set (or replace) the document's active FILTER from `request` (non-NULL;
 * borrowed only for this call — the core copies what it keeps). The request is
 * validated EXACTLY as ls_search_start validates it (same TEXT / PREDICATE
 * grammar and rejection rules; see ls_search_request and ls_search_start).
 *
 *   returns false — request rejected, and NOTHING changes: the current view
 *   (filtered or identity), any active search, and a running jump are all
 *   untouched. Same rejection conditions as ls_search_start (empty TEXT query;
 *   non-NULL scope with scope_len 0; out-of-range scope/column; an ordering
 *   operator whose value is non-numeric; out-of-domain kind/op).
 *
 *   returns true — the document enters (or re-enters) FILTERED MODE with this
 *   request, REPLACING any previous filter entirely (its counted region and
 *   match counts reset; the filter-scan restarts from row 0). Takes the scan
 *   slot for the filter-scan (a jump in LS_JUMP_SCANNING is cancelled to
 *   LS_JUMP_IDLE, gains kept) and RESETS any active search to LS_SEARCH_IDLE
 *   (the coordinate space changed). Never blocks: the filter-scan is
 *   asynchronous, observable via ls_filter_poll (state LS_FILTER_SCANNING, or
 *   already LS_FILTER_DONE for a document with nothing to scan). See FILTERED
 *   VIEWS.
 *
 * May allocate (per-block counter storage sized by the index checkpoints —
 * O(index checkpoints) regardless of match count).
 */
bool ls_filter_set(ls_doc *doc, const ls_search_request *request);

/*
 * Clear the active filter, restoring the IDENTITY view (no-op when no filter
 * is active). After this call ls_filter_poll reports LS_FILTER_IDLE and every
 * accessor addresses physical data rows again. Clearing RESETS any active
 * search to LS_SEARCH_IDLE and returns the jump slot to LS_JUMP_IDLE (a
 * scanning filter-scan or jump-scan is stopped; all frontier gains are KEPT).
 * Re-anchoring the viewport near the row you were viewing is the caller's
 * affair (capture ls_source_row of the top visible row BEFORE clearing). ZERO
 * allocation.
 */
void ls_filter_clear(ls_doc *doc);

/* Current filter snapshot (see ls_filter_status and FILTERED VIEWS). Before
 * any ls_filter_set on this handle, and after ls_filter_clear: LS_FILTER_IDLE
 * with every other field zero. ZERO allocation; never fails. */
ls_filter_status ls_filter_poll(const ls_doc *doc);

/*
 * The ORIGINAL (unfiltered) 0-based data-row number of view row `row` — the
 * gutter value. `row` is a view-relative index (a FILTERED index while a filter
 * is active; a physical data row otherwise). Defined ONLY for rows inside the
 * currently materialized window (identical window/borrow domain to ls_cell):
 * returns LS_NO_ROW for any `row` outside the materialized window or the view's
 * row range. Without a filter this is the identity on servable rows
 * (ls_source_row(doc, i) == i). Total function; ZERO allocation; never fails;
 * never scans.
 */
uint64_t ls_source_row(const ls_doc *doc, uint64_t row);

#ifdef __cplusplus
}
#endif

#endif /* LESSSHEET_H */
