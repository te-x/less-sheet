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
 * adds ls_cell_copy: a bounded, window-INDEPENDENT full read of a single
 * cell's COMPLETE transcoded content into a caller-owned buffer (up to a
 * caller-provided byte cap), so a frontend can faithfully copy cells whose
 * content runs past the ls_cell display cap — see FULL-CELL READ.
 * security-hardening adds one output-only behavior: ALL clipboard-bound copy —
 * ls_cell_copy AND the streaming copy job (ls_copy_open / ls_copy_next /
 * ls_copy_close) — NEUTRALIZES spreadsheet formula-injection: a cell whose first
 * byte is '=' or '@' ALWAYS, and a '+'/'-' cell UNLESS it is a plain number
 * (e.g. -3, +2.5 copy raw), is emitted with a single leading apostrophe, so
 * a copied cell can never become a live formula when pasted into Excel / Sheets
 * / Numbers. Display (ls_cell) and search are byte-for-byte unaffected — see
 * COPY OUTPUT SAFETY. The
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
 *     whole with the flag false. For a read of a cell's COMPLETE
 *     transcoded content PAST this display cap (e.g. clipboard copy), use
 *     ls_cell_copy, which fills a caller buffer up to a caller-provided byte
 *     cap (and neutralizes copy-injection — see COPY OUTPUT SAFETY and
 *     FULL-CELL READ).
 *
 * COPY OUTPUT SAFETY (spreadsheet formula-injection neutralization; security-
 * hardening slice — always on, no opt-out)
 *   - MOTIVE. A cell like =cmd|'/C calc'!A0 or +2+3 is inert TEXT in this viewer
 *     (there is no formula engine), but pasting it into Excel / Google Sheets /
 *     Numbers can execute it. The core therefore neutralizes such values in the
 *     bytes it emits for CLIPBOARD COPY, so no frontend has to (single source of
 *     truth; both current frontends and every future one inherit it for free).
 *   - THE RULE (number-aware). Keyed on the value's FIRST byte:
 *       * '=' (0x3D) or '@' (0x40): a single APOSTROPHE ' (0x27) is ALWAYS
 *         prepended to the value.
 *       * '+' (0x2B) or '-' (0x2D): the apostrophe is prepended ONLY when the
 *         value is NOT a plain number (grammar below). A plain number (e.g. -3,
 *         +2.5, -1.5e3) is emitted RAW — it is inert text, not an injection
 *         vector, and the raw form is what a spreadsheet should receive.
 *     Any other first byte — including an apostrophe already present — is
 *     emitted unchanged, and an EMPTY cell (no first byte) is never prefixed.
 *     The transform keys only on the first byte (and, for '+'/'-', on whether
 *     the whole value is a plain number), so it is applied AT MOST ONCE per cell
 *     and re-copying an already-neutralized value never adds a second apostrophe
 *     (idempotent).
 *   - PLAIN NUMBER (the testable grammar). A '+'/'-'-led value is a plain number
 *     IFF, after consuming that single leading sign, the ENTIRE remaining byte
 *     sequence matches
 *         digit+ ( '.' digit+ )? ( ('e'|'E') ('+'|'-')? digit+ )?
 *     where digit is ASCII 0-9. The match must consume the whole value: NO
 *     whitespace, NO thousands separators, NO leading or trailing '.', NO second
 *     sign outside the exponent, NO trailing bytes. Anything that fails is
 *     neutralized — the fail-safe direction is to OVER-neutralize, never under.
 *     This is deliberately STRICTER than the HEADER RULE numeric grammar (which
 *     strips surrounding whitespace and admits a bare leading/trailing '.'):
 *     reusing that parser here would UNDER-neutralize, so it must not be reused.
 *       * RAW (emitted unchanged): -3, +2.5, -0.5, +1e9, -2.5E-3.
 *       * NEUTRALIZED: =SUM(A1), @ref, +cmd, +2+3, -1+x, --3, -.5, -3., "-3 "
 *         (trailing space), -1,000, -3e, and a bare '+' or '-'.
 *   - WHERE IT APPLIES. Exactly the two clipboard-bound read paths: ls_cell_copy
 *     (the full-cell read) and ls_copy_next (each field of the streaming TSV).
 *     It is applied to the cell's transcoded value (after quote removal, the
 *     column-count truncate/pad rule, and encoding transcode) BEFORE the
 *     streaming copy's TSV framing, so it is ORTHOGONAL to spreadsheet quoting:
 *     a quoted field carries the apostrophe on its value inside the quotes, and
 *     the single-cell raw 1x1 copy still neutralizes (=SUM(A1) copies as
 *     '=SUM(A1), +cmd as '+cmd, while a plain -3 stays -3). The apostrophe, when
 *     added, is one output byte and counts against ls_cell_copy's buf_len /
 *     *out_len and ls_copy_next's `written`.
 *   - WHERE IT DOES NOT APPLY. ls_cell / ls_header_cell (on-screen display) and
 *     the search / predicate / filter / ls_window_match_flags matchers all see
 *     the RAW cell text, unchanged — the grid shows and search matches the true
 *     content; only the clipboard-bound bytes are neutralized. The source file
 *     is never modified (read-only core).
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
 *
 * NETWORK (never-full-download-streaming slice — see NEVER-FULL-DOWNLOAD
 * STREAMING EXTENSION at the end of this header): for a network-sourced
 * document (any ls_open_url_* open) the frontier is DEMAND-DRIVEN and no
 * background scan advances it. bytes_scanned is the fetched/indexed
 * high-water; bytes_total is the known resource size, or
 * LS_BYTES_TOTAL_UNKNOWN (== UINT64_MAX) for an unknown-length stream (total
 * not yet known — disambiguated from the empty-file {0, 0, true}); complete
 * becomes true only when navigation has reached EOF (or a small resource was
 * fully fetched at open). LOCAL (mmap / gzip) documents follow the rule above
 * byte-identically.
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
    /* Substring text match over a set of columns; ASCII case folding per the
     * request's case_sensitive flag (see ls_search_request). */
    LS_SEARCH_TEXT = 0,
    /* Single-column typed predicate (operator + value). */
    LS_SEARCH_PREDICATE = 1,
} ls_search_kind;

/*
 * Predicate operators. EQ/NE test (in)equality, folding ASCII case per the
 * request's case_sensitive flag; LT/GT/LE/GE compare NUMERICALLY and ignore
 * case_sensitive (see ls_search_request for the pinned semantics).
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
 *   kind == LS_SEARCH_TEXT — substring match, case folding per case_sensitive:
 *     - value_ptr/value_len: the UTF-8 query bytes (len > 0 required; the
 *       empty query means "no search" and is rejected).
 *     - A cell matches when the query occurs as a byte substring of the cell
 *       text. When case_sensitive == false (the default) the comparison is
 *       case-insensitive over ASCII ONLY: bytes 0x41..0x5A compare equal to
 *       their lowercase forms; every other byte — including all bytes >=
 *       0x80, i.e. all non-ASCII UTF-8 — compares exactly. When
 *       case_sensitive == true the comparison is byte-exact. (Full Unicode
 *       folding is out of scope; ASCII-only folding is the pinned v1 rule.)
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
 *     - LS_SEARCH_OP_EQ / NE: the cell matches iff its bytes are equal / not
 *       equal to the value bytes, with case folding per case_sensitive.
 *       case_sensitive == false (the default) folds ASCII (bytes 0x41..0x5A
 *       equal their lowercase forms; every byte >= 0x80 compares exactly, the
 *       same invariant as the TEXT rule); case_sensitive == true is byte-exact.
 *       NO whitespace trimming in either mode. The empty value is legal (EQ
 *       matches empty cells, including the padded cells of ragged records),
 *       independent of case_sensitive. NE is the exact complement of EQ.
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
 *
 *   case_sensitive (below) selects the ASCII case-folding rule for both
 *   LS_SEARCH_TEXT and predicate EQ/NE, as detailed per-field; ordering
 *   predicates ignore it.
 */
typedef struct ls_search_request {
    ls_search_kind kind;
    ls_search_op op;
    uint32_t column;
    const uint8_t *value_ptr;
    size_t value_len;
    const uint32_t *scope_ptr;
    size_t scope_len;
    /* ASCII case folding for LS_SEARCH_TEXT substring matching and predicate
     * LS_SEARCH_OP_EQ / NE. false (the default / zero-init) = case-INSENSITIVE
     * (bytes 0x41..0x5A fold to their lowercase forms; every byte >= 0x80
     * compares exactly); true = byte-exact. Ordering predicates
     * (LS_SEARCH_OP_LT / GT / LE / GE) are numeric and ignore this field.
     * Honored identically by ls_search_start, ls_filter_set, ls_search_nav,
     * and ls_window_match_flags (which reuse the active request). */
    bool case_sensitive;
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
 * buffer, WITHOUT the LS_CELL_MAX_BYTES display cap. This is the full-cell read
 * the display-capped ls_cell cannot provide (a cell longer than the display cap
 * is searchable but not readable through ls_cell); a frontend uses it to copy a
 * cell to the clipboard faithfully.
 *
 * FORMULA-INJECTION NEUTRALIZATION (security-hardening (f), always on): because
 * this is a CLIPBOARD-bound read, a value whose first byte is '=' or '@', or a
 * '+'/'-' value that is NOT a plain number, is emitted with a single leading
 * apostrophe (0x27) — see COPY OUTPUT SAFETY for the exact, number-aware,
 * idempotent rule (a plain number like -3 or +2.5 copies raw). The apostrophe,
 * when added, is part of the copied value: it counts toward *out_len and the
 * buf_len cap, and it is the only way the output differs from the cell's raw
 * transcoded bytes. (Applied at most once, and never to an empty cell.)
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
 * The request's case_sensitive flag (see ls_search_request) governs TEXT
 * substring and predicate EQ/NE case folding; the match-scan, every
 * ls_search_nav it serves, and ls_window_match_flags all inherit it from this
 * one request.
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
 * grammar and rejection rules; see ls_search_request and ls_search_start). It
 * honors the request's case_sensitive flag identically to ls_search_start, so
 * the filter row-set and its counts — and, while the filter is active,
 * ls_search_nav and ls_window_match_flags — all fold ASCII case iff
 * case_sensitive == false.
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

/* =========================================================================
 * COLUMN METADATA EXTENSION (column-config slice) — ADDITIVE, ABI v1
 * =========================================================================
 * Everything below this line is a single append-only extension block. It adds
 * bounded, lazy CSV column TYPE INFERENCE, an explicit per-session type/null-
 * sentinel/format configuration model, and stable conflict/proposal state,
 * plus a zero-allocation batch way to read that metadata and copy header
 * labels — all WITHOUT touching one existing byte above. Adding THIS
 * column-config extension changed nothing above it: every constant, enum,
 * struct, and prototype defined before this block kept its exact value,
 * layout, signature, allocation behavior, threading lane, and borrow lifetime,
 * and no existing enum gained a case or existing struct grew.
 *
 * FROZEN-SURFACE AMENDMENT — search-case-mode (v1). The additive /
 * byte-identical discipline stated by this and the later extension blocks
 * (never-full-download-streaming, match-flags, streaming-copy) describes each
 * block's OWN additivity; it is NOT a whole-header external-ABI guarantee. The
 * later search-case-mode change deliberately GROWS ls_search_request by one
 * `bool case_sensitive` and rewrites its case-folding prose (smart case is
 * deleted). That is a clean, audited frozen-surface edit — sound because the
 * whole workspace statically links the core and rebuilds LOCK-STEP from this
 * one header, with no external pinned-binary ABI consumer and no compat path.
 * Only ls_search_request changed shape; every other symbol's layout is
 * unchanged. See ls_search_request and
 * docs/architecture/ARCH-search-case-mode.md.
 *
 * FROZEN-SURFACE AMENDMENT — security-hardening (v1; pre-launch MUST items d/e/
 * f), as converged by its 2026-07-24 amendment. An audited, lock-step frozen-
 * surface edit (root-planner freeze; see docs/architecture/ARCH-security-
 * hardening.md). As it now stands: (d) is WITHDRAWN — a benchmark disproved the
 * decompression-"bomb" ratio cap (no signal separates a bomb from a legitimate
 * highly-compressible CSV), so gzip work-amplification is an accepted known risk
 * and ls_scan_progress carries NO expansion/bomb field at all (an earlier freeze
 * had added one; it was RETIRED, not deprecated — no-backcompat v1); (e) adds
 * two trailing ls_net_status cases, LS_NET_ERROR_INSECURE_REDIRECT (8) and
 * LS_NET_ERROR_SHORT_BODY (9), and ships the CONNECT timeout only for v1 (the
 * idle-read timeout is deferred — Zig 0.16 std has no per-read deadline hook);
 * and (f) documents an always-on, NUMBER-AWARE copy-output change (COPY OUTPUT
 * SAFETY: ls_cell_copy / ls_copy_next prefix a ' to a leading '=' / '@' always,
 * and to a leading '+' / '-' unless the cell is a plain number) with NO
 * signature or struct change beyond (d)'s field removal. Every other symbol's
 * layout is byte-identical; sound for the same reason — one header, lock-step
 * static-linked rebuild, no external pinned-binary consumer.
 *
 * WHAT IT DOES NOT CHANGE. The document / window / index / jump / row-count /
 * search / filter / raw-cell / full-cell-copy surface above is untouched. This
 * extension NEVER changes what ls_cell / ls_cell_copy / search / filter see:
 * they keep consuming the existing canonical raw cell (quoting removed, the
 * truncate/pad rule applied, transcoded to UTF-8). The core still serves RAW
 * cells and never serves display-formatted strings; grouping, rounding,
 * localized dates, and null presentation are entirely a frontend concern built
 * ON TOP of this metadata. Type inference does not advance the scan frontier,
 * does not enlarge or delay ls_open, and does not turn the sparse index into a
 * cell scan.
 *
 * FIXED-LAYOUT PLAIN-VALUE SNAPSHOTS. Every new struct is a fixed-layout plain
 * value containing only fixed-width integers, `double`, nested fixed values,
 * and explicit reserved storage — never a pointer, `bool`, native-width enum,
 * or `size_t`. Enum-valued fields are stored as `uint32_t` (the typed enums
 * below name the legal values). On every supported 64-bit target the sizes and
 * field offsets are exactly those pinned by the LS_COLUMN_STATIC_ASSERT checks
 * that follow each struct (and by matching Zig comptime pins); all explicit
 * reserved fields and output padding are zero. Each snapshot carries its own
 * `struct_size` + `abi_version` so a caller/core mismatch is a clean
 * LS_COLUMN_INVALID_ARGUMENT, never an out-of-bounds write.
 *
 * CALLER-OWNED, WINDOW-INDEPENDENT. Unlike ls_cell's borrowed ls_str, every
 * snapshot the caller receives, every metadata item, every label span, and
 * every copied UTF-8 byte (header label, null sentinel, conflict example) is
 * owned by the caller the instant the call returns and stays valid across every
 * later ls_window_set, worker commit, inference request, and cancel. ls_close
 * does not affect a caller-owned copy. No new call returns an ls_str, and the
 * existing "until the next window/close" borrow rule is byte-for-byte unchanged.
 * Variable-length UTF-8 crosses ONLY through the caller-buffer copy calls.
 *
 * ALLOCATION DISCIPLINE (extends, never alters, the legacy rule above). The
 * MUTATING calls — ls_column_inference_request, ls_column_override_set,
 * ls_column_null_sentinel_set — are the only NEW calls that may allocate (to
 * create sparse per-column state / copy IDs or bytes); on failure they return
 * LS_COLUMN_OUT_OF_MEMORY and leave the previous configuration untouched. Every
 * other new call — the batch snapshot get, poll, cancel, override/sentinel
 * clear, accept-proposal, and all label/sentinel/example copies — performs ZERO
 * heap allocation and never fails for want of memory. No legacy symbol's
 * allocation behavior changes.
 *
 * THREADING. All new calls are on the poll/control lane: internally
 * synchronized with the worker and safe from any thread at any time, and safe
 * concurrently with the serialized window lane — EXCEPT, exactly like every
 * existing call, they must not race ls_open / ls_close on the same handle. They
 * never invalidate an ls_str borrow.
 *
 * BATCH RULES (shared by the *_get_many / *_copy_many / inference_request calls).
 * An ID batch preserves caller order and permits duplicates. A zero-length
 * batch (count 0) is a valid no-op / empty query (its pointers may be NULL). A
 * non-zero batch requires non-NULL input/output pointers, `count` and any item
 * `capacity` at most LS_COLUMN_BATCH_MAX, output capacity at least `count`, and
 * every ID below ls_column_count(). Validation is ALL-OR-NOTHING: an invalid ID,
 * shape, descriptor, size/version, or capacity produces NO output and NO
 * mutation. For an output status/metadata item/label span the caller initializes
 * ONLY `struct_size` and `abi_version` to the v1 values before the call; for an
 * input ls_column_type it initializes those two and zeros `flags`/`reserved`.
 *
 * TWO-PASS COPY PROTOCOL (labels / sentinel / conflict example). Call once with
 * a NULL/zero output buffer to learn the required byte length (and, for labels,
 * to fill the spans); call again with a buffer of at least that size to receive
 * the bytes. A non-zero buffer smaller than required returns
 * LS_COLUMN_BUFFER_TOO_SMALL with the required length written (and label spans
 * filled) but NO partial byte payload. Every other error leaves all outputs
 * untouched.
 *
 * GENERATIONS. The document starts at global metadata generation 0. Each
 * successful atomic metadata commit allocates the next non-zero global
 * generation and stamps every column it changed with that value. A worker chunk
 * that changes several columns' evidence/counts/conflict is ONE commit; each
 * config mutation is its own commit. Polling the single global generation
 * (ls_column_metadata_poll / the out-generation of ls_column_metadata_get_many)
 * tells the frontend only THAT some column changed; it then re-queries the
 * currently visible IDs and compares per-column generations — it never
 * enumerates all columns. Generation 0 on a column means "untouched" (no stored
 * state). If the global generation ever saturates at UINT64_MAX it stays there.
 */

/* ---- column-config compile-time layout assertions (C11 / C++; else no-op) - */
#if defined(__cplusplus)
  #define LS_COLUMN_STATIC_ASSERT(cond, msg) static_assert(cond, msg)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
  #define LS_COLUMN_STATIC_ASSERT(cond, msg) _Static_assert(cond, msg)
#else
  /* pre-C11: layout is still pinned authoritatively by the Zig comptime block. */
  #define LS_COLUMN_STATIC_ASSERT(cond, msg)
#endif

/* ---- Constants ---------------------------------------------------------- */

/* Version stamped into every column-config snapshot; bump only in a new ABI. */
#define LS_COLUMN_METADATA_ABI_VERSION (1)
/* Maximum column IDs / output items per batch call. */
#define LS_COLUMN_BATCH_MAX (1024)
/* First-sample bound: data rows (the byte ceiling is LS_OPEN_HEAD_MAX_BYTES). */
#define LS_COLUMN_INFERENCE_HEAD_MAX_ROWS (256)
/* Decoded complete-cell bytes per later materialized-window event / chunk. */
#define LS_COLUMN_INFERENCE_WINDOW_MAX_BYTES (262144)
/* Maximum null-sentinel UTF-8 bytes (0 is valid — empty sentinel). */
#define LS_COLUMN_SENTINEL_MAX_BYTES (256)
/* Maximum conflict-example UTF-8 bytes (cut only at a code-point boundary). */
#define LS_COLUMN_CONFLICT_EXAMPLE_MAX_BYTES (256)
/* ls_column_type.decimal_precision "not applicable / unknown" sentinel (never
 * emitted as a real precision; a saturating precision stops at UINT64_MAX-1). */
#define LS_COLUMN_TYPE_PRECISION_UNSPECIFIED (UINT64_MAX)
/* ls_column_type.decimal_scale "not applicable / unknown" sentinel (real scale
 * stays within [INT64_MIN+1, INT64_MAX]). */
#define LS_COLUMN_TYPE_SCALE_UNSPECIFIED (INT64_MIN)
/* ls_column_type.datetime_fraction_digits "not applicable / unknown" sentinel. */
#define LS_COLUMN_TYPE_FRACTION_DIGITS_UNSPECIFIED (UINT32_MAX)

/* ls_column_metadata.presence_flags bits (which optional slots are present). */
#define LS_COLUMN_HAS_DECLARED (1u << 0)
#define LS_COLUMN_HAS_INFERRED (1u << 1)
#define LS_COLUMN_HAS_OVERRIDE (1u << 2)
#define LS_COLUMN_HAS_PROPOSAL (1u << 3)
#define LS_COLUMN_HAS_NULL_SENTINEL (1u << 4)
#define LS_COLUMN_HAS_CONFLICT_EXAMPLE (1u << 5)

/* ls_column_label_span.flags bits. */
#define LS_COLUMN_LABEL_PRESENT (1u << 0)   /* a source header label exists */
#define LS_COLUMN_LABEL_TRUNCATED (1u << 1) /* it was display-capped (see cap) */

/* ---- Enumerations (each value is frozen; new cases only in a new ABI) --- */

/* Result of every new column-config call (except the void cancel). */
typedef enum ls_column_result {
    LS_COLUMN_OK = 0,
    /* A pointer/shape/ID/capacity/descriptor/size/version was invalid; nothing
     * was written or mutated (all-or-nothing). */
    LS_COLUMN_INVALID_ARGUMENT = 1,
    /* The column ID is not below ls_column_count() (a valid-shape but absent
     * column); nothing was written or mutated. */
    LS_COLUMN_NO_COLUMN = 2,
    /* A single-value copy target has no value (no null sentinel / no conflict
     * example). Distinct from OK+length 0, which is a present-but-EMPTY value. */
    LS_COLUMN_NO_VALUE = 3,
    /* accept-proposal on a column that currently has no proposed replacement. */
    LS_COLUMN_NO_PROPOSAL = 4,
    /* A non-zero output buffer was smaller than the required length; the length
     * (and label spans) were written but no partial byte payload. */
    LS_COLUMN_BUFFER_TOO_SMALL = 5,
    /* A mutating call could not allocate; the previous state is untouched. */
    LS_COLUMN_OUT_OF_MEMORY = 6,
} ls_column_result;

/* Base type kind (stored as uint32_t in ls_column_type.kind). Null is an
 * ORTHOGONAL cell state (see ls_column_null_policy_kind), never a base type:
 * an all-null / all-empty column is UNKNOWN plus its null/empty counts. */
typedef enum ls_column_type_kind {
    LS_COLUMN_TYPE_UNKNOWN = 0,     /* no eligible evidence yet / all-null */
    LS_COLUMN_TYPE_UNSUPPORTED = 1, /* a future reader/type this client can't read */
    LS_COLUMN_TYPE_TEXT = 2,        /* deterministic fallback; never conflicts */
    LS_COLUMN_TYPE_BOOLEAN = 3,     /* ASCII-case-insensitive true/false only */
    LS_COLUMN_TYPE_INTEGER = 4,     /* pinned numeric grammar, no point/exponent */
    LS_COLUMN_TYPE_DECIMAL = 5,     /* pinned numeric grammar with point/exponent */
    LS_COLUMN_TYPE_DATE = 6,        /* exactly YYYY-MM-DD, valid Gregorian date */
    LS_COLUMN_TYPE_DATETIME = 7,    /* exactly YYYY-MM-DDTHH:MM:SS[.f][Z|±HH:MM] */
} ls_column_type_kind;

/* Which slot resolved the effective type (stored as uint32_t). */
typedef enum ls_column_type_source {
    LS_COLUMN_SOURCE_NONE = 0,      /* unknown effective type */
    LS_COLUMN_SOURCE_DECLARED = 1,  /* a self-describing reader (absent for CSV v1) */
    LS_COLUMN_SOURCE_INFERRED = 2,  /* the published inferred candidate */
    LS_COLUMN_SOURCE_OVERRIDE = 3,  /* the user's explicit session override */
} ls_column_type_source;

/* Datetime wall-clock vs zoned semantics (stored as uint32_t). NONE outside a
 * datetime type. Naive and zoned values never agree; two differing explicit
 * offsets agree as ZONED. */
typedef enum ls_column_datetime_semantics {
    LS_COLUMN_DATETIME_NONE = 0,
    LS_COLUMN_DATETIME_NAIVE = 1,
    LS_COLUMN_DATETIME_ZONED = 2,
} ls_column_datetime_semantics;

/* Per-column inference lifecycle (stored as uint32_t). */
typedef enum ls_column_inference_state {
    LS_COLUMN_INFERENCE_UNREQUESTED = 0, /* no inference requested for this column */
    LS_COLUMN_INFERENCE_QUEUED = 1,      /* requested, not yet sampling */
    LS_COLUMN_INFERENCE_SAMPLING = 2,    /* accumulating evidence */
    LS_COLUMN_INFERENCE_PROVISIONAL = 3, /* 1..7 agreeing values; not yet effective */
    LS_COLUMN_INFERENCE_PUBLISHED = 4,   /* a published inferred descriptor exists */
} ls_column_inference_state;

/* Confidence in the published inferred descriptor (stored as uint32_t). */
typedef enum ls_column_confidence {
    LS_COLUMN_CONFIDENCE_NONE = 0,       /* nothing published */
    LS_COLUMN_CONFIDENCE_LOW = 1,        /* provisional (1..7 values) */
    LS_COLUMN_CONFIDENCE_BOUNDED = 2,    /* published on 8 agreeing values */
    LS_COLUMN_CONFIDENCE_EXHAUSTIVE = 3, /* every data row examined (exact count) */
} ls_column_confidence;

/* Null policy (stored as uint32_t). */
typedef enum ls_column_null_policy_kind {
    LS_COLUMN_NULL_NONE = 0,     /* empty fields are empty text, never null */
    LS_COLUMN_NULL_SENTINEL = 1, /* an exact byte-for-byte sentinel marks null */
} ls_column_null_policy_kind;

/* Conflict / proposal state against the published effective type (uint32_t). */
typedef enum ls_column_conflict_state {
    LS_COLUMN_CONFLICT_NONE = 0,     /* no contradictory complete value seen */
    LS_COLUMN_CONFLICT_OBSERVED = 1, /* >=1 contradiction; no agreed replacement */
    LS_COLUMN_CONFLICT_PROPOSED = 2, /* >=8 rows agree on a replacement (a proposal) */
} ls_column_conflict_state;

/* Document-wide inference job state (stored as uint32_t in the poll snapshot). */
typedef enum ls_column_inference_job_state {
    LS_COLUMN_JOB_IDLE = 0,      /* no desired set (never requested / fully unrequested) */
    LS_COLUMN_JOB_QUEUED = 1,    /* a desired set exists, work not yet started */
    LS_COLUMN_JOB_RUNNING = 2,   /* the worker is sampling */
    LS_COLUMN_JOB_DONE = 3,      /* the current finite work set is complete */
    LS_COLUMN_JOB_CANCELLED = 4, /* cancelled; holds until the next request */
} ls_column_inference_job_state;

/* ---- Fixed-layout snapshot structs -------------------------------------- */

/*
 * One type descriptor. Fills the declared/inferred/override/effective/proposal
 * slots of ls_column_metadata; also the input to ls_column_override_set. An
 * absent slot is the canonical UNKNOWN value (kind UNKNOWN, all sentinels).
 * Enum-valued fields are uint32_t (see the named enums). 48 bytes, align 8.
 */
typedef struct ls_column_type {
    uint32_t struct_size;              /* == sizeof(ls_column_type) (48) */
    uint32_t abi_version;              /* == LS_COLUMN_METADATA_ABI_VERSION */
    uint32_t kind;                     /* ls_column_type_kind */
    uint32_t flags;                    /* reserved type flags; zero in v1 */
    uint64_t decimal_precision;        /* DECIMAL: coefficient digits after exact
                                        * base-10 normalization; else UNSPECIFIED */
    int64_t  decimal_scale;            /* DECIMAL: fractional places (may be
                                        * negative for powers of ten); else UNSPECIFIED */
    uint32_t datetime_semantics;       /* ls_column_datetime_semantics (NONE off datetime) */
    uint32_t datetime_fraction_digits; /* DATETIME: max observed 0..9; else UNSPECIFIED */
    uint64_t reserved;                 /* zero */
} ls_column_type;
LS_COLUMN_STATIC_ASSERT(sizeof(ls_column_type) == 48, "ls_column_type must be 48 bytes");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_type, kind) == 8, "ls_column_type.kind @8");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_type, decimal_precision) == 16, "ls_column_type.decimal_precision @16");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_type, decimal_scale) == 24, "ls_column_type.decimal_scale @24");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_type, datetime_semantics) == 32, "ls_column_type.datetime_semantics @32");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_type, datetime_fraction_digits) == 36, "ls_column_type.datetime_fraction_digits @36");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_type, reserved) == 40, "ls_column_type.reserved @40");

/*
 * The coherent per-column snapshot. `override` (a C++/Swift contextual keyword —
 * access it with a backtick in Swift) is the user's explicit session type.
 * `generation` is this column's last committed metadata generation (0 ==
 * untouched). Counts are cumulative committed values under the current null /
 * effective epoch — whole-document totals only when confidence is EXHAUSTIVE.
 * 384 bytes, align 8. Enum-valued fields are uint32_t.
 */
typedef struct ls_column_metadata {
    uint32_t struct_size;                /* == sizeof(ls_column_metadata) (384) */
    uint32_t abi_version;                /* == LS_COLUMN_METADATA_ABI_VERSION */
    uint32_t column;                     /* absolute column ID */
    uint32_t presence_flags;             /* LS_COLUMN_HAS_* */
    uint64_t generation;                 /* this column's committed generation; 0 == untouched */
    ls_column_type declared;             /* @24  self-describing reader slot (CSV: absent) */
    ls_column_type inferred;             /* @72  current CSV candidate */
    ls_column_type override;             /* @120 user's explicit session type */
    ls_column_type effective;            /* @168 override>inferred>declared>unknown */
    ls_column_type proposal;             /* @216 proposed inferred replacement, if any */
    uint32_t effective_source;           /* @264 ls_column_type_source */
    uint32_t inference_state;            /* @268 ls_column_inference_state */
    uint32_t confidence;                 /* @272 ls_column_confidence */
    uint32_t null_policy;                /* @276 ls_column_null_policy_kind */
    uint32_t conflict_state;             /* @280 ls_column_conflict_state */
    uint32_t null_sentinel_bytes;        /* @284 sentinel length when present (may be 0) */
    uint64_t evidence_count;             /* @288 cumulative eligible non-empty non-null values */
    uint64_t sampled_row_count;          /* @296 cumulative source rows examined */
    uint64_t sampled_decoded_bytes;      /* @304 cumulative decoded complete-cell bytes */
    uint64_t empty_count;                /* @312 cumulative empty-text cells (current epoch) */
    uint64_t null_count;                 /* @320 cumulative null cells (current epoch) */
    uint64_t conflict_count;             /* @328 cumulative conflicting cells (current epoch) */
    uint64_t conflict_source_row;        /* @336 representative source data-row; LS_NO_ROW if none */
    uint32_t conflict_example_bytes;     /* @344 conflict-example copy length (see copy call) */
    uint32_t conflict_example_truncated; /* @348 0/1: example cut at the example cap */
    uint64_t reserved[4];                /* @352 zero */
} ls_column_metadata;
LS_COLUMN_STATIC_ASSERT(sizeof(ls_column_metadata) == 384, "ls_column_metadata must be 384 bytes");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, generation) == 16, "ls_column_metadata.generation @16");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, declared) == 24, "ls_column_metadata.declared @24");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, inferred) == 72, "ls_column_metadata.inferred @72");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, override) == 120, "ls_column_metadata.override @120");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, effective) == 168, "ls_column_metadata.effective @168");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, proposal) == 216, "ls_column_metadata.proposal @216");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, effective_source) == 264, "ls_column_metadata.effective_source @264");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, null_sentinel_bytes) == 284, "ls_column_metadata.null_sentinel_bytes @284");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, evidence_count) == 288, "ls_column_metadata.evidence_count @288");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, conflict_source_row) == 336, "ls_column_metadata.conflict_source_row @336");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, conflict_example_bytes) == 344, "ls_column_metadata.conflict_example_bytes @344");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_metadata, reserved) == 352, "ls_column_metadata.reserved @352");

/*
 * A coherent inference-job + global-generation snapshot (ls_column_metadata_poll).
 * The progress axes describe the CURRENT FINITE queued sample; `progress` is 1
 * only when that finite work is done and is frozen on cancel. 112 bytes, align 8.
 */
typedef struct ls_column_inference_status {
    uint32_t struct_size;             /* == sizeof(ls_column_inference_status) (112) */
    uint32_t abi_version;             /* == LS_COLUMN_METADATA_ABI_VERSION */
    uint32_t state;                   /* ls_column_inference_job_state */
    uint32_t reserved0;               /* zero */
    uint64_t request_generation;      /* @16 desired-set epoch (changes on request/cancel) */
    uint64_t metadata_generation;     /* @24 latest global commit generation */
    uint32_t requested_column_count;  /* @32 columns in the current finite work set */
    uint32_t completed_column_count;  /* @36 of those, resolved so far */
    uint64_t source_bytes_scanned;    /* @40 source bytes consumed by the current sample */
    uint64_t source_bytes_budget;     /* @48 source-byte ceiling of the current sample */
    uint64_t rows_scanned;            /* @56 data rows examined by the current sample */
    uint64_t rows_budget;             /* @64 data-row ceiling of the current sample */
    double   progress;                /* @72 [0,1]; 1 only when finite work done */
    uint64_t reserved[4];             /* @80 zero */
} ls_column_inference_status;
LS_COLUMN_STATIC_ASSERT(sizeof(ls_column_inference_status) == 112, "ls_column_inference_status must be 112 bytes");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_inference_status, request_generation) == 16, "status.request_generation @16");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_inference_status, requested_column_count) == 32, "status.requested_column_count @32");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_inference_status, source_bytes_scanned) == 40, "status.source_bytes_scanned @40");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_inference_status, progress) == 72, "status.progress @72");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_inference_status, reserved) == 80, "status.reserved @80");

/*
 * One header-label span into the caller arena filled by ls_column_labels_copy_many.
 * A header-off / empty label has no LS_COLUMN_LABEL_PRESENT flag and len 0; a
 * display-capped label carries LS_COLUMN_LABEL_TRUNCATED. Generic column names
 * remain a frontend concern. 48 bytes, align 8.
 */
typedef struct ls_column_label_span {
    uint32_t struct_size;  /* == sizeof(ls_column_label_span) (48) */
    uint32_t abi_version;  /* == LS_COLUMN_METADATA_ABI_VERSION */
    uint32_t column;       /* requested absolute column ID */
    uint32_t flags;        /* LS_COLUMN_LABEL_* */
    uint64_t offset;       /* @16 byte offset of this label in the caller arena */
    uint64_t len;          /* @24 display-capped UTF-8 byte length */
    uint64_t reserved[2];  /* @32 zero */
} ls_column_label_span;
LS_COLUMN_STATIC_ASSERT(sizeof(ls_column_label_span) == 48, "ls_column_label_span must be 48 bytes");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_label_span, offset) == 16, "label_span.offset @16");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_label_span, len) == 24, "label_span.len @24");
LS_COLUMN_STATIC_ASSERT(offsetof(ls_column_label_span, reserved) == 32, "label_span.reserved @32");

/* ---- Functions ---------------------------------------------------------- */

/*
 * Replace the desired active inference ID set with `ids[0..count]` (a live
 * MUTABLE document). IDs are copied, sorted/coalesced internally; a byte-
 * identical repeated set is idempotent. `count` must be 1..LS_COLUMN_BATCH_MAX
 * and every ID below ls_column_count(). Only requested columns are ever
 * sampled; untouched columns keep no stored state. Poll/control lane; MAY
 * allocate (sparse state + copied IDs) — on OOM returns LS_COLUMN_OUT_OF_MEMORY
 * and the prior request is intact.
 */
ls_column_result ls_column_inference_request(ls_doc *doc, const uint32_t *ids, uint32_t count);

/*
 * Cancel the current desired set/job (a live MUTABLE document). Committed
 * evidence and published metadata remain; queued/no-evidence columns return to
 * unrequested and partially-sampled columns stay provisional. The job state
 * becomes LS_COLUMN_JOB_CANCELLED until a replacement request. Poll/control
 * lane; ZERO allocation; cannot fail.
 */
void ls_column_inference_cancel(ls_doc *doc);

/*
 * Write one coherent job + global-generation snapshot into `*out_status` (a
 * live CONST document). The caller pre-sets out_status->struct_size = 112 and
 * abi_version = 1; a mismatch is LS_COLUMN_INVALID_ARGUMENT with no write.
 * Poll/control lane; ZERO allocation.
 */
ls_column_result ls_column_metadata_poll(const ls_doc *doc, ls_column_inference_status *out_status);

/*
 * Read metadata for `ids[0..count]` into `out_items[0..count]` in caller order
 * (duplicates allowed) under ONE lock, and write the global generation at which
 * they were read to `*out_generation` (a live CONST document). Untouched IDs are
 * SYNTHESIZED as a generation-0 unrequested/unknown item without creating state.
 * `count`/`capacity` at most LS_COLUMN_BATCH_MAX, capacity >= count, every ID
 * below ls_column_count(); each out item's struct_size/abi_version pre-set to
 * 384/1. A zero-length batch is a valid no-op that still writes *out_generation.
 * Poll/control lane; ZERO allocation. On any error every output byte is
 * untouched; on success the caller owns the items permanently.
 */
ls_column_result ls_column_metadata_get_many(const ls_doc *doc, const uint32_t *ids, uint32_t count,
                                             ls_column_metadata *out_items, uint32_t capacity,
                                             uint64_t *out_generation);

/*
 * Set column `column`'s explicit session override to `*type` (a live MUTABLE
 * document) and make it effective atomically. A valid override is an explicit
 * v1 kind — TEXT, BOOLEAN, INTEGER, DECIMAL, DATE, or DATETIME — with `flags`
 * and `reserved` zero and the metadata-only parameters (decimal_precision,
 * decimal_scale, datetime_fraction_digits) left at their UNSPECIFIED sentinels;
 * a DATETIME override additionally requires an explicit NAIVE or ZONED
 * datetime_semantics, and every other kind requires DATETIME_NONE.
 * UNKNOWN/UNSUPPORTED and any other parameter combination are rejected
 * (LS_COLUMN_INVALID_ARGUMENT). The
 * descriptor is copied (borrowed only for the call). Setting an override never
 * discards inferred/declared slots and resets conflict aggregation against the
 * prior effective descriptor. MAY allocate the first sparse state; on OOM /
 * validation failure the prior state is untouched.
 */
ls_column_result ls_column_override_set(ls_doc *doc, uint32_t column, const ls_column_type *type);

/*
 * Idempotently remove column `column`'s override (a live MUTABLE document),
 * revealing the published inferred/declared/unknown effective type and
 * resetting conflicts against the old effective descriptor. Poll/control lane;
 * ZERO allocation; distinguishes only an invalid column (LS_COLUMN_NO_COLUMN).
 */
ls_column_result ls_column_override_clear(ls_doc *doc, uint32_t column);

/*
 * Set column `column`'s null sentinel to `bytes[0..len]` (a live MUTABLE
 * document). `len` is 0..LS_COLUMN_SENTINEL_MAX_BYTES; a NULL `bytes` is valid
 * only when len == 0 (the empty sentinel — the explicit way to treat empty CSV
 * fields as null). The bytes must be valid UTF-8. A null-epoch change resets
 * this column's inferred evidence, conflicts, and proposal and requeues it if
 * active. MAY allocate; invalid UTF-8 / over-length / OOM leaves the old state
 * untouched (atomic).
 */
ls_column_result ls_column_null_sentinel_set(ls_doc *doc, uint32_t column, const uint8_t *bytes, size_t len);

/*
 * Idempotently remove column `column`'s null sentinel (a live MUTABLE document)
 * and start the same fresh-evidence epoch as a sentinel change. Poll/control
 * lane; ZERO allocation; reports only an invalid column.
 */
ls_column_result ls_column_null_sentinel_clear(ls_doc *doc, uint32_t column);

/*
 * Accept column `column`'s proposed inferred replacement (a live MUTABLE
 * document): atomically move the proposal into the inferred/published slot,
 * stay in Auto (never create an override), clear the proposal + conflict
 * aggregate, and commit new generations. Returns LS_COLUMN_NO_PROPOSAL without
 * mutation when there is no proposal. Poll/control lane; ZERO allocation.
 */
ls_column_result ls_column_inference_accept_proposal(ls_doc *doc, uint32_t column);

/*
 * Copy source header labels for `ids[0..count]` (a live CONST document). Fills
 * `out_spans[0..count]` (each pre-set to struct_size 48 / abi_version 1) in
 * requested order and, when `arena` has room, the label bytes into `arena`;
 * writes the total required byte length to `*out_required`. Two-pass: pass a
 * NULL/zero `arena` to fill spans + required length only; then pass an arena of
 * at least *out_required bytes. A non-zero arena smaller than required returns
 * LS_COLUMN_BUFFER_TOO_SMALL (spans + required length written, arena untouched).
 * A header-off/empty label gets no PRESENT flag and len 0; a display-capped one
 * carries TRUNCATED. `capacity` (spans) at most LS_COLUMN_BATCH_MAX and >= count.
 * Poll/control lane; ZERO allocation. Spans/arena are caller-owned and
 * window-independent.
 */
ls_column_result ls_column_labels_copy_many(const ls_doc *doc, const uint32_t *ids, uint32_t count,
                                            ls_column_label_span *out_spans, uint32_t capacity,
                                            uint8_t *arena, size_t arena_capacity,
                                            size_t *out_required);

/*
 * Two-pass copy of column `column`'s null sentinel bytes into `buf[0..buf_capacity]`
 * (a live CONST document), writing the required length to `*out_required`. A
 * NULL/zero buffer reports the required length only. LS_COLUMN_OK with
 * *out_required 0 is a present EMPTY sentinel; LS_COLUMN_NO_VALUE means no
 * sentinel is set. A non-zero buffer smaller than required is
 * LS_COLUMN_BUFFER_TOO_SMALL with the length written and no partial payload.
 * Poll/control lane; ZERO allocation.
 */
ls_column_result ls_column_null_sentinel_copy(const ls_doc *doc, uint32_t column,
                                              uint8_t *buf, size_t buf_capacity, size_t *out_required);

/*
 * Two-pass copy of column `column`'s bounded conflict-example UTF-8 prefix (the
 * value identified by ls_column_metadata.conflict_example_bytes, cut only at a
 * code-point boundary) into `buf[0..buf_capacity]` (a live CONST document),
 * writing the required length to `*out_required`. Same two-pass / BUFFER_TOO_SMALL
 * rules as the sentinel copy; LS_COLUMN_NO_VALUE when there is no example.
 * Poll/control lane; ZERO allocation.
 */
ls_column_result ls_column_conflict_example_copy(const ls_doc *doc, uint32_t column,
                                                 uint8_t *buf, size_t buf_capacity, size_t *out_required);

#undef LS_COLUMN_STATIC_ASSERT

/* =========================================================================
 * NETWORK SOURCE EXTENSION (network-source slice) — ADDITIVE: open a URL
 * =========================================================================
 * Everything below this line is a single append-only extension block. It adds
 * an ASYNCHRONOUS, POLLABLE, CANCELLABLE open of a CSV / .csv.gz served over
 * HTTP(S) — a NEW entry-point family (ls_open_url_*) PARALLEL to (never
 * replacing) ls_open — plus the network error taxonomy and the job-status
 * snapshot it needs. It adds NO symbol above this line and changes NOTHING
 * existing: every constant, enum, struct, prototype, layout, allocation rule,
 * threading lane, and borrow lifetime defined before this block keeps its exact
 * value and meaning, so a client compiled against the pre-network header links
 * and behaves identically. See docs/architecture/ARCH-network-source.md.
 *
 * WHY A NEW ENTRY POINT (not ls_open). A network open is never instant: bytes
 * must be fetched, latency is unbounded, and a transfer can stall or fail
 * mid-flight. ls_open's single blocking "return an ls_doc" shape cannot express
 * that. ls_open_url_* therefore mirrors the existing async-job idiom
 * (ls_jump_start / _poll / _cancel), plus an explicit _release: unlike a jump,
 * the job handle is not owned by an existing document.
 *
 * WHAT A NETWORK DOCUMENT IS. Once a job reaches LS_NET_OPEN_DONE its `doc` is
 * a fully-formed ls_doc*, usable through EVERY existing accessor — window, cell,
 * index, row count, jump, search, filter, full-cell copy, column metadata —
 * exactly like a local open of the SAME bytes, with IDENTICAL dialect / header /
 * encoding / row-count semantics (the O(head) determinism pin is measured
 * against the fetched head rather than an mmap'd head). The CSV/gzip Reader is
 * completely unaware its bytes arrived over the network: this is the payoff of
 * the format-agnostic Source seam. .csv.gz over the network falls out for free
 * (gzip is selected by the 1f 8b magic on the fetched bytes, exactly as for a
 * local file — see the header's FORMAT NEUTRALITY and ARCH-csv-gz).
 *
 * THE ACCESS MODEL (behind the ABI; see ARCH-network-source "Exact access
 * model"). If the server honors ranges (a 206 / Content-Range answer to the
 * probe) the document runs in TRUE random-access mode: any [start,end) byte
 * range is fetched on demand and, once fetched, is mirrored into a private local
 * spool file and forever after served from local disk — never re-fetched. If
 * the server ignores Range (200 OK) or advertises no usable total length, the
 * open falls back to a full sequential download into the same spool, then opens
 * that completed file exactly like a local mmap document — correct either way.
 * A first-time fetch of a never-before-seen range is latency-unbounded BY DESIGN
 * and only ever happens from an async, progress-polled, cancellable path (the
 * initial head fetch here, or the existing jump-scan machinery once open) —
 * NEVER from a "zero-alloc, never blocks" accessor. The scan-frontier promise is
 * unchanged; only the frontier's cost model differs (network latency vs. a page
 * fault). Steady-state resident RAM for the network Source stays bounded (the
 * spool is disk-resident, not RAM-resident).
 *
 * LIFECYCLE & OWNERSHIP. ls_open_url_start returns a job handle immediately
 * (NULL only if the handle itself could not be allocated). An invalid URL /
 * scheme / option is NOT a NULL return — it is a valid job that polls
 * LS_NET_OPEN_FAILED with LS_NET_ERROR_INVALID_ARGUMENT, touching no network.
 * The caller polls ls_net_open_poll until a terminal state, may
 * ls_net_open_cancel at any time, and MUST ls_net_open_release the handle
 * exactly once when done with it (in flight or terminal). Releasing the job does
 * NOT close a DONE job's `doc`: that ls_doc follows the normal, independent
 * ls_close lifecycle like any other document. Closing the doc and releasing the
 * job are independent operations in either order.
 *
 * READ-ONLY, PRIVATE, EPHEMERAL. The remote resource is only ever GET (never
 * written). The local spool file is created mode 0600, unlinked immediately
 * (never visible in its directory while open), never a persistent cache, never
 * reused across opens, and fully gone after ls_close / process exit — the same
 * discipline as the gzip checkpoint spill file (see ARCH-csv-gz). Re-opening the
 * same URL always re-fetches from scratch.
 *
 * SECURITY POSTURE (deliberate choices, not silent defaults). BOTH http:// and
 * https:// are allowed (LAN/test servers without TLS are a supported use). NO
 * authentication (no credential prompt, no cookie jar): a URL requiring auth
 * surfaces as LS_NET_ERROR_HTTP_STATUS (401/403). NO URL scheme beyond
 * http/https is accepted (ftp://, file://, … reject synchronously as
 * LS_NET_ERROR_INVALID_ARGUMENT, untouched). Redirects are followed up to a
 * small fixed cap (no user-facing configuration; exceeding it is
 * LS_NET_ERROR_TOO_MANY_REDIRECTS). A redirect that would DOWNGRADE the
 * transport from https to http is REFUSED with LS_NET_ERROR_INSECURE_REDIRECT
 * (security-hardening (e)); http->https and same-scheme redirects, including
 * cross-host, are still followed within the cap. TLS verification (system
 * roots + hostname) stays on.
 *
 * NO COLD-START BUDGET. The <500 ms cold-start budget and its
 * first_rows_visible_ms marker explicitly DO NOT apply to a network open; the
 * open's own always-visible progress affordance is its "we're working" signal
 * instead (see ARCH-network-source Non-functional constraints).
 *
 * DEPENDENCIES. Zig standard library only (std.http.Client, std.crypto.tls for
 * HTTPS) — no new runtime dependency; the assembled app stays single-digit MB.
 *
 * THREADING. ls_open_url_start spawns the background fetch. ls_net_open_poll is
 * ZERO allocation, total, and never blocks — safe from any thread at any time.
 * ls_net_open_cancel / ls_net_open_release are safe from any thread, but the
 * caller must not race two control calls on the SAME job concurrently, and must
 * not poll or control a job after releasing it. The background fetch never
 * blocks the caller's poll/control lane.
 */

/* ls_net_open_status.progress sentinel: the total resource length is unknown,
 * so the fetch fraction is indeterminate — the frontend shows an indeterminate
 * spinner plus the live bytes_fetched counter instead of a percentage. */
#define LS_NET_PROGRESS_UNKNOWN (-1.0)

/*
 * Network open outcome (ls_net_open_status.error). DISTINCT from ls_status:
 * network failures are a materially different taxonomy from local-file
 * failures. Distinct, stable values; meaningful only when the job state is
 * LS_NET_OPEN_FAILED. No two causes collapse into one code.
 */
typedef enum ls_net_status {
    /* No error (the job is not in a failed state). */
    LS_NET_OK = 0,
    /* The URL scheme is not http/https, the URL is malformed, or an
     * ls_open_options field is outside its documented domain. Rejected
     * SYNCHRONOUSLY by ls_open_url_start; no network is touched. Mirrors
     * ls_open's LS_ERROR_INVALID_ARGUMENT. */
    LS_NET_ERROR_INVALID_ARGUMENT = 1,
    /* DNS resolution or TCP/TLS connection failure — the host could not be
     * reached (a TLS handshake failure is a connection failure). */
    LS_NET_ERROR_UNREACHABLE = 2,
    /* The CONNECT timeout fired: no connection was established within the
     * implementation's connect deadline (a single named const). Retryable:
     * re-open / re-issue the demand. (security-hardening (e) ships the connect
     * timeout only for v1; an idle-read deadline is deferred — Zig 0.16
     * std.http.Client has no per-read timeout hook — so this code signals a
     * failed CONNECT, never a mid-stream stall. The code number 3 is unchanged.) */
    LS_NET_ERROR_TIMEOUT = 3,
    /* The server returned a non-2xx status after following redirects. The
     * numeric status is carried in ls_net_open_status.http_status (e.g. 404,
     * 401, 403) for the frontend to render. */
    LS_NET_ERROR_HTTP_STATUS = 4,
    /* A redirect chain exceeded the fixed redirect cap. */
    LS_NET_ERROR_TOO_MANY_REDIRECTS = 5,
    /* Local spool-file creation/write failure (mirrors ls_open's LS_ERROR_IO).
     * The spool is load-bearing — not a mere optimization — so its failure
     * fails the open rather than silently corrupting or degrading state. */
    LS_NET_ERROR_IO = 6,
    /* The job was cancelled (ls_net_open_cancel) before reaching DONE. */
    LS_NET_ERROR_CANCELLED = 7,
    /* A redirect's Location would DOWNGRADE the transport from https to http
     * (security-hardening (e)): it is REFUSED with this distinct code.
     * http->https and same-scheme redirects (including cross-host) are still
     * followed within the redirect cap; a pure http->http chain that merely
     * exceeds the cap remains LS_NET_ERROR_TOO_MANY_REDIRECTS, not this. */
    LS_NET_ERROR_INSECURE_REDIRECT = 8,
    /* The server delivered FEWER body bytes than it promised, or a zero-length
     * body where content was expected (a truncated / malformed transfer).
     * Distinct from TIMEOUT (bytes did arrive, just too few) and from IO (that
     * is LOCAL spool failure). Retryable. security-hardening (e) correctness
     * guarantee: a short/zero body NEVER becomes document content — the
     * un-fetched bytes are not marked present and are never served as zero-fill
     * (this corrects the prior silent zero-fill). A POST-OPEN demand (jump /
     * search / scroll) that hit a short range simply did not advance over it and
     * is retried by re-issuing the demand; the document stays open and
     * interactive on its fetched prefix. (This code is reported by the open job
     * when the failing fetch is the head fetch; a post-open short range surfaces
     * as a stalled/unadvanced demand, not as a new document-level error state.) */
    LS_NET_ERROR_SHORT_BODY = 9,
} ls_net_status;

/* State of an ls_open_url_* job (ls_net_open_status.state). */
typedef enum ls_net_open_state {
    /* Probing range support: the initial Range GET is in flight. */
    LS_NET_OPEN_PENDING = 0,
    /* Head bytes are being fetched (range mode) or the resource is being
     * downloaded sequentially (fallback mode). */
    LS_NET_OPEN_FETCHING = 1,
    /* The document is open: `doc` is a valid ls_doc*. Terminal (persists until
     * ls_net_open_release). */
    LS_NET_OPEN_DONE = 2,
    /* The open failed: `error` (and, for LS_NET_ERROR_HTTP_STATUS,
     * `http_status`) say why; `doc` is NULL. Terminal. */
    LS_NET_OPEN_FAILED = 3,
    /* The job was cancelled before reaching DONE; all resources (spool file
     * included) are released and `doc` is NULL. Terminal. */
    LS_NET_OPEN_CANCELLED = 4,
} ls_net_open_state;

/*
 * Opaque async open-job handle. Core-owned; released exactly once by
 * ls_net_open_release. DISTINCT from ls_doc: a DONE job PRODUCES an ls_doc that
 * outlives the job (released/closed independently).
 */
typedef struct ls_net_open_job ls_net_open_job;

/*
 * A network open's progress/result snapshot (ls_net_open_poll). Field validity:
 *   progress      — fraction in [0.0, 1.0] of the head fetch when the total
 *                   length is known; the sentinel LS_NET_PROGRESS_UNKNOWN
 *                   (-1.0) when it is not. Meaningful while PENDING/FETCHING;
 *                   exactly 1.0 at LS_NET_OPEN_DONE.
 *   bytes_fetched — bytes fetched so far (monotone non-decreasing within a job).
 *   bytes_total   — total resource length in bytes, or 0 when unknown.
 *   doc           — a valid ls_doc* ONLY when state == LS_NET_OPEN_DONE; NULL
 *                   otherwise. Usable through every existing accessor; closed
 *                   with ls_close, independently of ls_net_open_release.
 *   state         — the job state (see ls_net_open_state).
 *   error         — an ls_net_status; LS_NET_OK unless state ==
 *                   LS_NET_OPEN_FAILED.
 *   http_status   — the numeric HTTP status when error ==
 *                   LS_NET_ERROR_HTTP_STATUS (e.g. 404); 0 otherwise.
 *   reserved      — zero.
 */
typedef struct ls_net_open_status {
    double progress;
    uint64_t bytes_fetched;
    uint64_t bytes_total;
    ls_doc *doc;
    ls_net_open_state state;
    ls_net_status error;
    int32_t http_status;
    int32_t reserved;
} ls_net_open_status;

/*
 * Start an ASYNCHRONOUS open of the CSV / .csv.gz at `url` (`url_len` bytes; NOT
 * required to be NUL-terminated). `options` is the SAME ls_open_options ls_open
 * takes (forced separator / quote / header / encoding / index_mode); it may be
 * NULL, meaning all-LS_SNIFF + LS_INDEX_AUTO. The struct is copied; the caller
 * keeps ownership of it and of `url`.
 *
 * Returns a job handle immediately, or NULL only if the handle itself could not
 * be allocated. The URL scheme / shape and the options are validated
 * SYNCHRONOUSLY: a scheme other than http/https, a malformed URL, or an
 * out-of-domain ls_open_options field is NOT a NULL return — it is a valid job
 * that immediately polls LS_NET_OPEN_FAILED with LS_NET_ERROR_INVALID_ARGUMENT
 * and touches no network. Every other outcome is reported ASYNCHRONOUSLY via
 * ls_net_open_poll. The caller MUST eventually ls_net_open_release the returned
 * handle (whether or not it reached DONE).
 */
ls_net_open_job *ls_open_url_start(const char *url, size_t url_len, const ls_open_options *options);

/*
 * Current snapshot of `job` (see ls_net_open_status). ZERO allocation; total;
 * never blocks; safe from any thread. After a terminal state
 * (DONE / FAILED / CANCELLED) the snapshot is stable until ls_net_open_release.
 */
ls_net_open_status ls_net_open_poll(const ls_net_open_job *job);

/*
 * Request cancellation of an in-flight open (no-op once terminal). The fetch
 * stops at its next bounded chunk boundary (exactly like ls_close stopping a
 * gzip inflate) and ALL resources — the spool file included — are released; the
 * job then polls LS_NET_OPEN_CANCELLED (with `doc` NULL — no dangling document).
 * Does not block. Safe from any thread (but do not race two control calls on
 * the same job).
 */
void ls_net_open_cancel(ls_net_open_job *job);

/*
 * Release the job handle. Must be called exactly once per handle; the handle is
 * invalid afterward (do not poll or control it again). If the job is still in
 * flight this first cancels and joins the background fetch (like ls_close on a
 * scanning document). This does NOT close the ls_doc a DONE job produced — that
 * doc follows the normal, independent ls_close lifecycle. Releasing the job and
 * closing its doc are independent, in either order.
 */
void ls_net_open_release(ls_net_open_job *job);

/* =========================================================================
 * NEVER-FULL-DOWNLOAD STREAMING (lazy / demand-driven network) EXTENSION
 * =========================================================================
 * (never-full-download-streaming slice — THREE documentation / sentinel
 * amendments; struct/enum/signature LAYOUT was BYTE-IDENTICAL to every prior
 * revision of this header WHEN THIS BLOCK WAS ADDED. (The later search-case-mode
 * v1 amendment then grew ls_search_request by one `case_sensitive` bool under
 * lock-step rebuild — see that struct and the FROZEN-SURFACE AMENDMENT note
 * above.) Two-key root-planner freeze; the author's sign-off relayed 2026-07-15.
 * See docs/architecture/ARCH-never-full-download-streaming.md.)
 *
 * This block adds exactly ONE new sentinel #define (LS_BYTES_TOTAL_UNKNOWN)
 * plus documentation of how the EXISTING network surface (NETWORK SOURCE
 * EXTENSION above — ls_open_url_* / ls_net_* / ls_index_poll / ls_row_count /
 * ls_search_*) behaves under the lazy access model. No enum, struct, or function
 * prototype changes shape or value, so a client compiled against any prior
 * header links and behaves identically.
 *
 * THE MODEL (the spine). A network-sourced document is STRICTLY lazy: it fetches
 * ONLY what a concrete user action needs — the head at open, a viewport plus a
 * small scroll buffer on scroll, up to the next match on search, and a deep jump
 * / wrap-to-start / find-last only on the user's explicit request — and NEVER
 * runs a background network scan of any kind. Inspecting a 100 GB resource's
 * columns fetches a few MB, not the file. Fetch-free accessors (ls_window_set,
 * ls_cell, ls_cell_copy, column inference) serve only bytes already behind the
 * frontier; a read at/beyond the frontier returns the existing not-yet-servable
 * value (empty cell / LS_COPY_PENDING) — the frontend jumps first. The frontier
 * advances ONLY through demand jumps, search navigations, and filter demands —
 * all on the async, progress-polled, cancellable paths (ls_jump_* / ls_search_*
 * / ls_filter_*), never the "never blocks" window lane.
 *
 * BEST-EFFORT NETWORK / STRICT LOCAL. Every LOCAL (mmap / gzip) behavior,
 * timing, and budget is UNCHANGED and regression-guarded — the lazy gate keys on
 * source kind (a local document's AUTO background indexer still advances the
 * frontier to EOF). Network operations carry NO wall-clock / latency guarantee;
 * they are judged only by correctness and fetch-minimality (how few bytes a
 * demand fetches), never speed.
 *
 * (a) UNKNOWN-TOTAL SENTINEL — ls_scan_progress.bytes_total.
 *     LS_BYTES_TOTAL_UNKNOWN (== UINT64_MAX) reported by ls_index_poll means an
 *     unknown-length network stream whose total is not yet known (no
 *     Content-Length, a chunked transfer, or a 206 without a usable
 *     Content-Range total). While it holds, ls_index_poll.complete stays false
 *     and bytes_scanned is the fetched/indexed high-water; at stream EOF
 *     bytes_total becomes the final size and complete follows the normal rule.
 *     It is DISTINCT from a genuinely empty resource, which is the ordinary
 *     empty document {0, 0, true} (a Content-Length: 0, or a stream that drains
 *     to empty). A LOCAL document never reports this sentinel.
 *
 * (b) NETWORK DEMAND-DRIVEN — ls_index_poll / ls_row_count under LS_INDEX_AUTO.
 *     For a network-sourced document LS_INDEX_AUTO does NOT background-advance
 *     the frontier over the wire (unlike a local document, whose AUTO indexer
 *     drives to EOF): the frontier advances only via viewport jumps, searches,
 *     and filters. Consequently ls_row_count is a CONVERGING LOWER BOUND for an
 *     unknown-total stream (count == the rows discovered so far, exact == false)
 *     or a FREE PROJECTION for a known-total resource (the existing byte-ratio
 *     estimate, exact == false) — neither fetches to produce the estimate, and
 *     both firm ONLY as the user navigates. ls_index_poll.complete and
 *     ls_row_count.exact become true ONLY if navigation reaches EOF (or a small
 *     resource was fully fetched at open — the determinism pin, measured against
 *     the fetched head rather than a mapped file).
 *
 * (c) NETWORK SEARCH DEMAND-BOUNDED — ls_search_start / ls_search_nav /
 *     ls_search_status. On a network source the match-scan is demand-bounded:
 *     ls_search_start starts NO background match-scan; each ls_search_nav scans
 *     forward only to the next match (fetching on demand, with progress), then
 *     the search PARKS at LS_SEARCH_CANCELLED (reusing the existing
 *     CANCELLED->resume state machine verbatim — no new states); "Next" resumes
 *     it. ls_search_status.total is the count over the SCANNED PREFIX (exact for
 *     that prefix, monotone) and total_exact becomes true ONLY if a navigation
 *     reaches EOF; the full match total M is never computed in the background.
 *     A network FILTER (ls_filter_*) is likewise demand-bounded: its filter-scan
 *     advances only while serving a demand, then parks LS_FILTER_CANCELLED (the
 *     view stays filtered; counts firm only as the user navigates).
 */

/*
 * Sentinel for ls_scan_progress.bytes_total (ls_index_poll): an unknown-length
 * network stream whose total size is not yet known. See amendment (a) above and
 * the ls_scan_progress documentation. Network-only; a local document never
 * reports it (its bytes_total is always the file size).
 */
#define LS_BYTES_TOTAL_UNKNOWN (UINT64_MAX)

/* =========================================================================
 * MATCH-FLAGS EXTENSION (thin-frontend-shared-core slice, Phase 1) — ADDITIVE
 * =========================================================================
 * (thin-frontend-shared-core slice — ONE additive, read-only entry point;
 * struct / enum / signature / constant LAYOUT above this block was
 * BYTE-IDENTICAL to every prior revision of this header WHEN THIS BLOCK WAS
 * ADDED. (The later search-case-mode v1 amendment grew ls_search_request by
 * one `case_sensitive` bool under lock-step rebuild — see that struct and the
 * FROZEN-SURFACE AMENDMENT note above.) Two-key root-planner freeze; the author's
 * sign-off relayed 2026-07-15. See
 * docs/architecture/ARCH-thin-frontend-shared-core.md, Phase 1. The
 * LS_BYTES_TOTAL_UNKNOWN amendment above is the additive-amendment precedent.)
 *
 * This block adds exactly ONE new function prototype (ls_window_match_flags)
 * and NO new type, enum, struct, or constant. No existing symbol changes shape,
 * value, allocation behavior, threading lane, or borrow lifetime, so a client
 * compiled against any prior header links and behaves identically.
 *
 * WHY. Every frontend that paints find / predicate highlights needs, per
 * visible cell, the SAME verdict the core's matcher already computes for
 * ls_search_* (see SEARCH and ls_search_request). Re-deriving it in each
 * frontend duplicates the case_sensitive substring + exact-decimal grammar
 * byte-for-byte. This call hands the frontend that verdict for the current
 * window as a borrowed byte array, so a frontend paints highlights with ZERO
 * matching logic of its own and NO per-cell round-trip, and every future
 * frontend reuses the one implementation.
 */

/*
 * Per-cell MATCH FLAGS over the current window for the active search request:
 * for the window last set by ls_window_set and the request last passed to
 * ls_search_start, report which visible cells match — the same per-cell verdict
 * the core's matcher computes for ls_search_* (see SEARCH / ls_search_request),
 * so a frontend paints highlights with no matcher of its own.
 *
 * RETURN — a BORROWED buffer of one FLAG BYTE per cell (this is NOT UTF-8
 * text): value 1 = the cell matches the active request, 0 = it does not. The
 * bytes are ROW-MAJOR over the window's materialized data rows x the requested
 * column range [first_col, first_col + col_count): the stride is col_count and
 *     len == window_row_count * col_count,
 * where window_row_count is the row_count field of the ls_row_range the LAST
 * ls_window_set returned (the count of rows actually materialized). The flag for
 * data row `row` (window_first_row <= row < window_first_row + window_row_count)
 * and column `col` (first_col <= col < first_col + col_count) is at
 *     flags[(row - window_first_row) * col_count + (col - first_col)].
 * The buffer is carried in the ls_str {ptr, len}; ptr is never NULL, and an
 * empty result has len 0 with a valid, must-not-be-read ptr, exactly like a
 * ls_cell empty string.
 *
 * COLUMN WINDOW — first_col / col_count are the frontend's VISIBLE column window
 * (the same subset it reads with ls_cell), so the call is O(window rows x
 * col_count), NEVER O(ls_column_count): only the requested columns' cells are
 * evaluated (the column-windowing discipline of ARCH-column-windowing). The
 * requested range must be non-empty AND wholly in range; the EMPTY ls_str
 * (len 0) is returned when col_count == 0, when first_col >= ls_column_count(),
 * or when first_col + col_count > ls_column_count().
 *
 * PREDICATE & SCOPE — the verdict is the ACTIVE ls_search_request's, evaluated
 * per cell exactly as SEARCH defines it, over the cell text AS MATERIALIZED IN
 * THE WINDOW (the same bytes ls_cell serves — display-capped; a match lying past
 * the display cap is not flagged, matching what the frontend can paint):
 *   - LS_SEARCH_TEXT: a byte is 1 iff the column is IN SCOPE (a NULL scope_ptr
 *     means all columns) AND the active request's case_sensitive substring rule
 *     holds for that cell; a cell in an out-of-scope column is always 0.
 *   - LS_SEARCH_PREDICATE: a byte is 1 only on the request's target `column`
 *     (every other column is 0), and there iff the cell satisfies the operator
 *     (EQ / NE per the request's case_sensitive rule; LT / GT / LE / GE the
 *     EXACT-decimal comparison — a non-numeric cell never matches an ordering
 *     op; the empty value is legal).
 * A FILTER changes only WHICH data rows the window holds (filtered coordinates,
 * see FILTERED VIEWS), never the per-cell verdict: a materialized row's flags
 * are computed from that row's cells regardless of the view mode. The effective
 * header record is never a window data row and is never flagged.
 *
 * IDLE — when the search state is LS_SEARCH_IDLE (no search since open, or after
 * a reset — see SEARCH and FILTERED VIEWS RESET) the call returns the EMPTY
 * ls_str (len 0): no active request, no highlights. (The current-match strong
 * highlight needs no flag; the frontend already has found_row / found_col from
 * ls_search_poll.)
 *
 * OWNERSHIP, COST & LANE — BORROWED exactly like ls_cell: the buffer is
 * core-owned and stays valid until the NEXT ls_window_set on this document or
 * ls_close, whichever comes first; nothing else invalidates it. It is computed
 * LAZILY on the first call after a window or search change and MEMOIZED, so
 * repeated calls across repaints reuse it with ZERO further allocation; a call
 * made after a search change recomputes the verdicts into the buffer (read the
 * flags for the current window + request, and re-read after either changes).
 * The call performs ZERO heap allocation beyond that one reused buffer, NEVER
 * fails (out-of-range / no-window / no-search all return the empty ls_str), and
 * NEVER scans — it evaluates only already-materialized window cells and never
 * advances the frontier or touches the file. One byte per cell, NOT packed
 * bits: the window is O(viewport) and bit-packing would only burden a C / GTK
 * consumer. WINDOW LANE — like ls_cell / ls_window_set (it reads the
 * materialized window and returns a window-tied borrow): one caller thread at a
 * time, which the caller serializes with the other window-lane calls; safe
 * concurrently with the core's background scanning. `doc` is const like ls_cell
 * / ls_cell_copy — the memoization is interior state.
 */
ls_str ls_window_match_flags(const ls_doc *doc, uint32_t first_col, uint32_t col_count);

/* =========================================================================
 * STREAMING COPY EXTENSION (thin-frontend-shared-core slice, Phase 2) — ADDITIVE
 * =========================================================================
 * (thin-frontend-shared-core slice — ONE additive, core-framed streaming TSV
 * COPY JOB family; struct / enum / signature / constant / prototype LAYOUT
 * above this block — including the Phase 1 MATCH-FLAGS EXTENSION — was
 * BYTE-IDENTICAL to every prior revision of this header WHEN THIS BLOCK WAS
 * ADDED. (The later search-case-mode v1 amendment grew ls_search_request by
 * one `case_sensitive` bool under lock-step rebuild — see that struct and the
 * FROZEN-SURFACE AMENDMENT note above.) Two-key root-planner freeze; the author's
 * sign-off relayed 2026-07-15. See
 * docs/architecture/ARCH-thin-frontend-shared-core.md, Phase 2. The Phase 1
 * MATCH-FLAGS EXTENSION and the LS_BYTES_TOTAL_UNKNOWN amendment above are the
 * additive-amendment precedents.)
 *
 * This block adds ONE constant (LS_COPY_MAX_CELLS), THREE types (ls_copy_rect,
 * ls_copy_step, ls_copy_progress), ONE opaque handle (ls_copy_job), and THREE
 * function prototypes (ls_copy_open / ls_copy_next / ls_copy_close). It adds NO
 * field to and changes NO existing symbol's shape, value, allocation behavior,
 * threading lane, or borrow lifetime, so a client compiled against any prior
 * header links and behaves identically. (NOTE: the ls_copy_* job family is
 * distinct from the pre-existing ls_copy_result enum of ls_cell_copy — the names
 * share the ls_copy_ prefix but no symbol or enumerator collides.)
 *
 * WHY. Selection copy today is O(document) PER-CELL FFI: a frontend calls
 * ls_cell_copy once per selected cell and frames the TSV (TAB/LF, spreadsheet
 * quoting, the single-cell raw special-case) itself. Because each ls_cell_copy
 * re-locates its row independently, a 100k x 3 copy was measured at ~80 s
 * off-main; and every frontend re-implements the fiddly quoting. This job family
 * hands the frontend a core-framed TSV byte stream over a demand-served
 * rectangle — the core owns the framing (byte-identical to the deleted
 * TSVCopyBuilder EXCEPT for the always-on formula-injection neutralization added
 * by security-hardening (f) — see COPY OUTPUT SAFETY and ls_copy_next), the
 * sweep reuses the O(1) forward copy cursor already behind ls_cell_copy, and
 * every future frontend reuses the one implementation with no per-cell
 * round-trip and no main-thread stall.
 */

/*
 * Overall SAFETY CAP for one streaming copy job: the maximum number of selection
 * CELLS the core will emit before it stops the sweep and reports the copy as
 * capped (LS_COPY_STEP_DONE with budget_capped true — see ls_copy_progress).
 * This bounds a pathological huge selection (e.g. a whole-document Cmd+A over a
 * billion rows) inside the core, INDEPENDENT of how many bytes those cells hold;
 * it mirrors the cell-count safety cap the deleted TSVCopyBuilder enforced
 * (CopyBudget.standard.maxCells). It is the ONE core-side ceiling: the total
 * OUTPUT bytes are bounded by the CALLER (it chooses when to stop pulling and
 * close — see ls_copy_next), never by the core. A selection with at most this
 * many cells is never capped (budget_capped false on DONE).
 */
#define LS_COPY_MAX_CELLS (10000000)

/*
 * The rectangular selection to serialize. Rows are 0-based, 64-bit,
 * VIEW-RELATIVE (FILTERED indices while a filter is active — the same
 * coordinates as ls_window_set / ls_cell); columns are 0-based PHYSICAL column
 * indices. Half-open in both axes: rows [first_row, first_row + row_count),
 * columns [first_col, first_col + col_count). An empty rect (row_count == 0 or
 * col_count == 0) is valid and steps straight to LS_COPY_STEP_DONE with 0 bytes.
 * The struct is copied by ls_copy_open; the caller keeps ownership.
 */
typedef struct ls_copy_rect {
    uint64_t first_row;   /* view-relative, filtered-aware (like ls_window_set) */
    uint64_t row_count;
    uint32_t first_col;   /* physical column index */
    uint32_t col_count;
} ls_copy_rect;

/*
 * The outcome of one ls_copy_next pull. Distinct, stable values.
 */
typedef enum ls_copy_step {
    LS_COPY_STEP_MORE    = 0, /* wrote *written bytes; more chunks remain — call again */
    LS_COPY_STEP_DONE    = 1, /* wrote the final *written bytes; the selection is complete */
    LS_COPY_STEP_STALLED = 2, /* next row is at/beyond the frontier; nothing written — advance the
                               * frontier (ls_jump_start to stalled_row) and retry */
} ls_copy_step;

/*
 * Progress returned by ls_copy_next. `written` is the bytes framed into the
 * caller's buf this call (0 on STALLED, and 0 is also legal on DONE for an empty
 * or fully-capped selection). `rows_done` is the cumulative count of selection
 * rows FULLY emitted so far — monotone non-decreasing across a job's lifetime —
 * so a frontend renders progress as rows_done / rect.row_count. `stalled_row` is
 * meaningful only on STALLED (the VIEW row to advance the frontier to before
 * retrying; 0 otherwise). `budget_capped` is meaningful only on DONE: true iff
 * the core's LS_COPY_MAX_CELLS safety cap cut the selection short (mirrors the
 * deleted TSVCopyBuilder's cap; false for any selection that completed in full).
 */
typedef struct ls_copy_progress {
    ls_copy_step step;
    size_t   written;      /* bytes written into buf this call (<= buf_len) */
    uint64_t rows_done;    /* cumulative selection rows fully emitted (monotone) — progress =
                            * rows_done / rect.row_count */
    uint64_t stalled_row;  /* on STALLED: the view row to jump to; 0 otherwise */
    bool     budget_capped;/* on DONE: true iff the core's safety cap cut the selection short
                            * (mirrors the deleted TSVCopyBuilder cap) */
} ls_copy_progress;

/*
 * Opaque streaming-copy job handle: one in-progress pull-model TSV
 * serialization of an ls_copy_rect. Core-owned; released exactly once by
 * ls_copy_close. Holds NO background thread — it is a cursor driven entirely by
 * the caller's ls_copy_next calls (see THREADING for concurrency).
 */
typedef struct ls_copy_job ls_copy_job;

/*
 * Open a pull-model streaming TSV serialization of `rect` over `doc`. Validates
 * synchronously: an out-of-range column range (first_col + col_count >
 * ls_column_count(doc)) makes the job step DONE with 0 bytes (nothing to
 * serialize), and an empty rect (see ls_copy_rect) is likewise a valid job that
 * steps DONE with 0 bytes. Returns a handle immediately (no scan, no file read),
 * or NULL ONLY if the handle itself could not be allocated. `rect` is COPIED;
 * the caller keeps ownership of it. The caller MUST call ls_copy_close exactly
 * once.
 *
 * The job serializes in the coordinate space in effect at OPEN (the identity
 * view, or the active filter's FILTERED coordinates). Setting/clearing a filter
 * or re-opening the document changes that space; a caller that changes the view
 * mid-copy should close the job and open a fresh one.
 */
ls_copy_job *ls_copy_open(const ls_doc *doc, const ls_copy_rect *rect);

/*
 * Frame the next TSV chunk of the job into the caller's buffer and return
 * progress. Writes at most `buf_len` bytes to `buf`. A chunk normally ends at a
 * field/row BOUNDARY (after a complete field or row); the SOLE exception is a
 * single field longer than `buf_len`, which is split across successive chunks at
 * a UTF-8 CODE-POINT boundary (a code point is NEVER split). Either way the
 * chunks of successive calls CONCATENATE, byte-for-byte, into one well-formed TSV
 * payload. `buf` may be NULL only when `buf_len` is 0. The caller OWNS `buf`:
 * ls_copy_next COPIES into
 * it (this is NOT a borrow — the bytes have no tie to the ls_str eviction rule
 * and survive any later ls_window_set on any thread).
 *
 * THE FRAMING (core-owned; byte-identical to the deleted TSVCopyBuilder EXCEPT
 * for the (f) formula-injection neutralization below, pinned by the copy
 * fixtures):
 *   - Fields in a row are separated by a TAB (0x09); rows are separated by a LF
 *     (0x0A); there is NO trailing separator after the final row.
 *   - SPREADSHEET QUOTING: a cell whose content contains a TAB, CR (0x0D), LF,
 *     or a double-quote (0x22) is wrapped in double-quotes with every interior
 *     double-quote DOUBLED; any other cell is emitted raw.
 *   - SINGLE-CELL RAW: a 1x1 rect (row_count == 1 AND col_count == 1) emits the
 *     cell's raw content verbatim — NEVER quoted, no trailing LF.
 *   - Cells are read in full: the COMPLETE transcoded cell content, WITHOUT
 *     the LS_CELL_MAX_BYTES display cap ls_cell applies (exactly as ls_cell_copy
 *     reads it), with the column-count truncate/pad rule (a missing cell of a
 *     ragged record is the empty string). An OVERSIZED row (source extent past
 *     LS_WINDOW_ROW_SCAN_MAX_BYTES) is served as the same bounded prefix
 *     ls_cell_copy serves.
 *   - FORMULA-INJECTION NEUTRALIZATION (security-hardening (f), always on): each
 *     field's value is neutralized exactly as ls_cell_copy neutralizes it — a
 *     leading '=' or '@' ALWAYS, and a leading '+' or '-' UNLESS the value is a
 *     plain number, gets a single apostrophe (0x27) prefix (see COPY OUTPUT
 *     SAFETY for the number-aware grammar). It is applied to the VALUE and is
 *     ORTHOGONAL to the spreadsheet quoting above (the apostrophe is inside the
 *     quotes when the value is quoted), and the single-cell raw 1x1 case still
 *     neutralizes. When added, the prefix counts toward `written`; it is the
 *     ONLY difference from the byte-identical-to-TSVCopyBuilder framing.
 *
 * PROGRESS & STEP (see ls_copy_progress):
 *   - LS_COPY_STEP_MORE: `written` bytes were framed; more chunks remain — call
 *     again. `rows_done` reflects rows fully emitted so far.
 *   - LS_COPY_STEP_DONE: the final `written` bytes were framed and the selection
 *     is complete (or was cut by the LS_COPY_MAX_CELLS cap — then `budget_capped`
 *     is true). Do not call ls_copy_next again; call ls_copy_close.
 *   - LS_COPY_STEP_STALLED: the next selection row is AT/BEYOND the scan frontier
 *     (not yet servable), so NOTHING was written this call and `stalled_row` is
 *     that row. Advance the frontier over it (ls_jump_start(doc, stalled_row),
 *     await LS_JUMP_DONE) and call ls_copy_next again to resume — the same
 *     servability model as ls_cell_copy's LS_COPY_PENDING. The job reads the
 *     document's shared frontier; the job itself NEVER scans and never advances
 *     the frontier.
 *
 * SINGLE-CONSUMER: do not call ls_copy_next concurrently on one job. See
 * THREADING (ls_copy_close) for cross-job / cross-lane concurrency.
 */
ls_copy_progress ls_copy_next(ls_copy_job *job, uint8_t *buf, size_t buf_len);

/*
 * Release the job (call EXACTLY ONCE; the handle is invalid afterwards). CANCEL
 * is simply "stop calling ls_copy_next, then ls_copy_close": the job holds no
 * background thread, so there is nothing to join and a cancel costs nothing. It
 * is safe against a concurrent ls_close on the same document under the same
 * poll/control-lane discipline as ls_cell_copy / the jump lane.
 *
 * THREADING: the whole job family is poll/control lane — safe from ANY thread at
 * any time (a large copy runs on a background worker while the window lane
 * scrolls on another thread and background scans advance), EXCEPT concurrently
 * with ls_open / ls_close on the same document. ls_copy_next COPIES into the
 * caller's buffer (no borrow), which is what frees a copy from the window-lane
 * eviction rule. A job is SINGLE-CONSUMER (one thread drives its ls_copy_next /
 * ls_copy_close at a time).
 */
void ls_copy_close(ls_copy_job *job);

#ifdef __cplusplus
}
#endif

#endif /* LESSSHEET_H */
