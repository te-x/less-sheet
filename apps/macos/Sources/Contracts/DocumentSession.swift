/// The live windowed document session — the ONLY way the app reads document
/// data in the viewer-ui slice (supersedes the walking skeleton's
/// copy-and-close head snapshot). A session wraps one open core handle
/// (`ls_doc`) for its whole lifetime; rows are paged through `setWindow` as
/// the user scrolls, and background indexing / jump scans / match-scans are
/// observed by polling. A FILTER (setFilter / clearFilter / filterStatus /
/// sourceRow) is an in-place VIEW MODE: while active, the same accessors serve
/// only the matching rows in filtered coordinates, with each row's original
/// number retrievable — see api/lesssheet.h FILTERED VIEWS.
///
/// Contract (mirrors api/lesssheet.h; see it for full semantics):
/// - All strings returned by a session OWN their storage: implementations
///   copy the core's borrowed bytes before returning (respecting the
///   eviction-safe borrow rule). The core serves UTF-8 (transcoded from the
///   resolved encoding; the UTF-8 path is pass-through), and per-cell display
///   is byte-capped by the core — `RowWindow.truncated` flags a cut cell
///   (search still sees the FULL cell — the cap is display-only). Any invalid
///   UTF-8 on the pass-through path is rendered as U+FFFD at the display.
/// - `Sendable`: every member is safe to call from any actor/thread;
///   implementations internally serialize the window lane per the C
///   threading rules. Poll methods never block; `setWindow` is the
///   synchronous-fast path (O(window), never scans, never blocks on I/O
///   proportional to file size).
/// - `close()` releases the core handle (cancelling/joining core threads —
///   safe during jump-scans and match-scans); it is idempotent. No other
///   member may be called after `close()`. Implementations also close on
///   deinit as a safety net.

/// Row-count knowledge (mirrors `ls_row_count`): `count` is exact when
/// `isExact`, otherwise the core's converging estimate (> 0 for any
/// non-empty document from the moment the session exists). The UI marks
/// estimates (e.g. "~12.4M rows, estimating…") until `isExact`.
public struct RowCountInfo: Equatable, Sendable {
    public let count: UInt64
    public let isExact: Bool

    public init(count: UInt64, isExact: Bool) {
        self.count = count
        self.isExact = isExact
    }
}

/// Background-index progress (mirrors `ls_scan_progress`). `bytesScanned` is
/// monotone non-decreasing; `isComplete` iff every record is indexed (the
/// row count is exact from then on).
public struct ScanProgress: Equatable, Sendable {
    public let bytesScanned: UInt64
    public let bytesTotal: UInt64
    public let isComplete: Bool

    public init(bytesScanned: UInt64, bytesTotal: UInt64, isComplete: Bool) {
        self.bytesScanned = bytesScanned
        self.bytesTotal = bytesTotal
        self.isComplete = isComplete
    }

    /// Fraction in [0, 1] for progress UI; 1 for an empty file.
    public var fraction: Double {
        guard bytesTotal > 0 else { return 1 }
        return Double(bytesScanned) / Double(bytesTotal)
    }
}

/// One materialized row+column window (mirrors the result of `ls_window_set`
/// plus the copied cells): `rows[i]` is data row `firstRow + i`, carrying the
/// cells for the ABSOLUTE column range `[firstColumn, firstColumn + rows[i].count)`.
/// The DEFAULT `firstColumn == 0` with each row `columnCount` cells wide is the
/// original DENSE whole-row window (truncate/pad applied by the core) that
/// `setWindow(firstRow:rowCount:)` returns — so every pre-column-window caller
/// is unaffected. A COLUMN-WINDOWED fetch (`setWindow(firstRow:rowCount:columns:)`)
/// instead sets `firstColumn` to the requested range's lower bound and makes each
/// row exactly that range wide, so a wide document's per-window fetch is
/// O(visible columns), NOT O(columnCount) — the horizontal analog of the row
/// window (ARCH-column-windowing AC7). `rows` may be shorter than requested — or
/// empty — when the requested range extends beyond the scan frontier or the
/// document; the missing rows become available by re-requesting after the
/// frontier advances (poll-driven).
public struct RowWindow: Equatable, Sendable {
    public let firstRow: UInt64
    /// The 0-based ABSOLUTE index of the first column carried by every row:
    /// `rows[i][j]` is the cell at absolute column `firstColumn + j` (and the
    /// parallel `truncated[i][j]` its flag). DEFAULTS to 0 — the dense
    /// full-width window (`rows[i]` spans `[0, columnCount)`) that
    /// `setWindow(firstRow:rowCount:)` and every pre-column-window caller
    /// produces. A column-windowed fetch sets it to the requested range's lower
    /// bound; a column-relative consumer maps an absolute column `c` to its slot
    /// `c - firstColumn` in the row (in range iff
    /// `firstColumn <= c < firstColumn + rows[i].count`).
    public let firstColumn: Int
    public let rows: [[String]]
    /// Per-cell display-truncation flags, PARALLEL to `rows` over the SAME
    /// `[firstColumn, …)` column window: `truncated[i][j]` is true iff the cell
    /// at absolute column `firstColumn + j` in row `firstRow + i` was cut by the
    /// core's per-cell display cap (`ls_cell_truncated`). Same shape as `rows`
    /// (each row's flags count == that row's cell count); empty only when `rows`
    /// is empty. The cut is DISPLAY-ONLY — the full cell is still searchable
    /// (grids render a truncation indicator from this flag, ARCH req. 13/20).
    public let truncated: [[Bool]]
    /// Per-ROW OVERSIZED flags, PARALLEL to `rows`: `oversized[i]` is true iff
    /// row `firstRow + i`'s SOURCE extent exceeded the core's per-row window
    /// scan cap (`LS_WINDOW_ROW_SCAN_MAX_BYTES`, `ls_row_oversized`), so the row
    /// was served as a bounded PREFIX — more source exists past the served
    /// cells and the row's true end may lie past this window. ONE flag per row
    /// (NOT per cell): same length as `rows`, empty only when `rows` is empty.
    /// DISTINCT from `truncated` (the per-cell OUTPUT display cap): this is the
    /// whole-row SOURCE scan cap. Grids draw a per-row gutter marker from this,
    /// distinct from the per-cell "…" truncation indicator (ARCH-huge-row-budget
    /// req. 7); the live visual is a human-eyes check.
    public let oversized: [Bool]

    public init(
        firstRow: UInt64,
        firstColumn: Int = 0,
        rows: [[String]],
        truncated: [[Bool]] = [],
        oversized: [Bool] = []
    ) {
        self.firstRow = firstRow
        self.firstColumn = firstColumn
        self.rows = rows
        self.truncated = truncated
        self.oversized = oversized
    }
}

/// Jump-slot snapshot (mirrors `ls_jump_status`). `progress` is in [0, 1],
/// monotone within one jump; `done.landedRow` is the target clamped to the
/// last data row (0 for an empty document).
public enum JumpStatus: Equatable, Sendable {
    case idle
    case scanning(progress: Double)
    case done(landedRow: UInt64)
}

/// A live windowed document. See the file header for the full contract.
public protocol DocumentSession: AnyObject, Sendable {
    /// Column count (fixed at open; 0 for an empty document).
    var columnCount: Int { get }
    /// The effective dialect report (fixed at open) — feeds the pills.
    var dialect: DialectReport { get }
    /// The effective header record's cells (exactly `columnCount` of them),
    /// or nil when the effective header is off. Fixed at open.
    var headerCells: [String]? { get }

    /// Current row-count knowledge (poll; never blocks).
    func rowCount() -> RowCountInfo
    /// Current index progress (poll; never blocks). The UI polls at
    /// <= 100 ms granularity while progress is displayed.
    func indexProgress() -> ScanProgress

    /// Declare the viewport (+ scroll buffer) and materialize it: returns
    /// the rows of [firstRow, firstRow + rowCount) that are behind the scan
    /// frontier, copied. `rowCount` is clamped to the core's window cap.
    /// Never scans; synchronous-fast. Returns a DENSE window: `firstColumn == 0`
    /// and each row `columnCount` cells wide.
    func setWindow(firstRow: UInt64, rowCount: Int) -> RowWindow

    /// COLUMN-WINDOWED materialize (ARCH-column-windowing AC7) — the horizontal
    /// analog of the row window. Identical to `setWindow(firstRow:rowCount:)` in
    /// the ROW dimension, but fetches ONLY the columns in `columns` (a half-open
    /// ABSOLUTE column-index range — a `ColumnWindow.range`). The result's
    /// `firstColumn` is `columns.lowerBound` (clamped to `0 ..< columnCount`) and
    /// each returned row is exactly that range wide, so a wide document's
    /// per-window fetch touches O(visible columns) cells, NOT O(columnCount) — a
    /// column-relative consumer indexes absolute column `c` at `c - firstColumn`.
    /// `columns` is clamped to `0 ..< columnCount`; an empty intersection yields
    /// empty rows. Same window/borrow domain, row clamping, frontier, and
    /// never-scans / synchronous-fast guarantees as the dense overload. A DEFAULT
    /// protocol-extension implementation falls back to the dense
    /// `setWindow(firstRow:rowCount:)` (a full-width window, `firstColumn == 0`)
    /// so a conformer need not implement this to compile; a conformer that cares
    /// about wide-document cost OVERRIDES it to make the fetch truly O(window).
    func setWindow(firstRow: UInt64, rowCount: Int, columns: Range<Int>) -> RowWindow

    /// Start (or retarget) the async jump-scan toward a 0-based data row.
    /// Never blocks; if the target is behind the frontier the jump is
    /// already `.done` when this returns (and does not disturb a running
    /// search — only a jump that must scan takes the core's single scan
    /// slot, cancelling the search's scan).
    func startJump(to targetRow: UInt64)
    /// Cancel the active jump (no-op otherwise). Frontier gains are kept;
    /// restoring the viewport is the caller's affair (see `JumpControlling`).
    func cancelJump()
    /// Current jump status (poll; never blocks).
    func jumpStatus() -> JumpStatus

    /// Start a new search for `request` (mirrors `ls_search_start`),
    /// REPLACING any previous search (counts reset) and cancelling a
    /// scanning jump (the single scan slot). Returns false iff the core
    /// rejects the request — empty text query, invalid scope, out-of-range
    /// column, or an ordering operator with a non-numeric value — in which
    /// case NOTHING changes (`FindControlling.submit` validates first; the
    /// core enforces). Performs NO navigation: issue `.fromTop` for "first
    /// match in the file". Never blocks (the match-scan is asynchronous;
    /// poll `searchStatus`).
    func startSearch(_ request: SearchRequest) -> Bool
    /// Request the nearest match per `nav` (mirrors `ls_search_nav`; anchor
    /// semantics pinned at `SearchNav`). Completes synchronously when the
    /// counted region already determines the answer — always, once the scan
    /// is done — and otherwise is served by the scan (resuming a cancelled
    /// one if needed). Replaces any pending navigation. Never blocks.
    func navigateSearch(_ nav: SearchNav)
    /// Stop the match-scan (mirrors `ls_search_cancel`): counts, landings,
    /// and progress freeze at their last values (kept, exact for the
    /// counted region). No-op when idle or done. Never blocks.
    func cancelSearch()
    /// Current search snapshot, or nil when no search was started on this
    /// session — a fresh session, including a dialect RE-OPEN, is nil (all
    /// search state dies with the old handle). Poll; never blocks.
    func searchStatus() -> SearchSnapshot?

    /// Set (or replace) the active FILTER from `request` (mirrors
    /// `ls_filter_set`), entering FILTERED MODE: every row accessor, jump, and
    /// search then operates in filtered coordinates (row i = the i-th matching
    /// row in file order). REPLACES any previous filter, takes the core's
    /// single scan slot (cancelling a scanning jump), and RESETS any active
    /// search (the coordinate space changed — `searchStatus()` returns nil
    /// afterwards). Returns false iff the core REJECTS the request (same rules
    /// as `startSearch`: empty text query, invalid scope, out-of-range column,
    /// an ordering operator with a non-numeric value); NOTHING changes then.
    /// Never blocks (the filter-scan is asynchronous — poll `filterStatus`).
    func setFilter(_ request: SearchRequest) -> Bool
    /// Clear the active filter, restoring the IDENTITY view (mirrors
    /// `ls_filter_clear`; no-op when no filter is active). Resets any active
    /// search. Re-anchoring the viewport near the row you were viewing is the
    /// caller's affair (capture `sourceRow` of the top visible row BEFORE
    /// clearing — ARCH criterion 13). Never blocks.
    func clearFilter()
    /// Current filter snapshot (mirrors `ls_filter_poll`), or nil when no
    /// filter is active — a fresh session or a dialect RE-OPEN is nil (the
    /// filter dies with the old handle). Poll; never blocks.
    func filterStatus() -> FilterSnapshot?
    /// The ORIGINAL (unfiltered) 0-based data-row number of view row `viewRow`
    /// — the gutter value (mirrors `ls_source_row`). `viewRow` is a
    /// view-relative index (a FILTERED index while a filter is active; a
    /// physical data row otherwise). Returns nil (the core's LS_NO_ROW
    /// sentinel) for a row outside the currently materialized window or the
    /// view's range — identical window/borrow domain to a cell read. Without a
    /// filter it is the identity on servable rows. Never blocks; never scans.
    func sourceRow(_ viewRow: UInt64) -> UInt64?

    /// LOSSLESS full-cell read for CLIPBOARD COPY (ARCH-select-copy; mirrors
    /// `ls_cell_copy`) — the display-capped `setWindow`/`ls_cell` path cannot
    /// serve a cell longer than the 4 KiB display cap, so copy uses THIS. Reads
    /// the COMPLETE content of the cell at (`row`, `column`) — same addressing as
    /// a windowed cell (0-based, view-relative; a FILTERED index while a filter is
    /// active) — up to `maxBytes` of UTF-8 (cut at a code-point boundary), WITHOUT
    /// the display cap. ADDITIVE: existing conformers are unaffected (the RED
    /// default below), and it is WINDOW-INDEPENDENT — it neither requires nor
    /// disturbs `setWindow`'s window, so copy runs without moving the viewport.
    ///
    /// Returns a `CopiedCell` mapping `ls_copy_result`: `.served` with the (possibly
    /// per-cell-`truncated`) `text`; `.pending` when `row` is past the scan
    /// frontier (advance it — a jump — and retry); `.noCell` when no such cell
    /// exists (`column >= columnCount`, or `row` past an EXACT row count). Poll/
    /// control lane in the core: SAFE from any thread, so the frontend calls it
    /// off the main thread to build a large copy (AC4). `maxBytes` is the caller's
    /// per-cell cap (`CopyBudget.perCellMaxBytes`, ~1 MiB).
    func copyCell(row: UInt64, column: Int, maxBytes: Int) -> CopiedCell

    /// Per-cell FIND / PREDICATE MATCH FLAGS over the current window for the
    /// active search (ARCH-thin-frontend-shared-core Phase 1; mirrors
    /// `ls_window_match_flags`). Returns ONE flag byte per visible cell —
    /// 1 = the cell matches the active `startSearch` request, 0 = it does not —
    /// ROW-MAJOR over the window last set by `setWindow` x the column range
    /// `[firstColumn, firstColumn + columnCount)` (stride `columnCount`,
    /// `count == windowRowCount * columnCount`), COPIED out of the core's
    /// borrow immediately (the UTF-8-copy-out discipline). The verdict is the
    /// SAME one the core's matcher computes for `startSearch`: TEXT substring
    /// and PREDICATE eq/ne fold ASCII case per the active request's
    /// `caseSensitive` (insensitive by default, byte-exact when set) over
    /// IN-SCOPE columns, plus exact-decimal ordering on the target column;
    /// a FILTER changes only which rows the window holds, not the verdict.
    /// Returns `[]` when no search is active, no window is
    /// materialized, or the column range is empty / out of range. ADDITIVE:
    /// the RED default below returns `[]` (no highlights) so existing
    /// conformers compile; the real conformer OVERRIDES it to call
    /// `ls_window_match_flags`. A frontend paints highlights by indexing this
    /// array — with NO matcher of its own.
    func windowMatchFlags(firstColumn: Int, columnCount: Int) -> [UInt8]

    /// Open a pull-model STREAMING TSV COPY of the rectangular selection `rect`
    /// (ARCH-thin-frontend-shared-core Phase 2; mirrors `ls_copy_open`). The CORE
    /// frames the TSV — TAB/LF separators, spreadsheet quoting, the single-cell raw
    /// special-case, lossless cells — BYTE-IDENTICAL to the former per-cell builder,
    /// so the frontend copies a selection with NO per-cell FFI, NO main-thread stall,
    /// and NO TSV logic of its own. The frontend drives the returned `CopyStreaming`
    /// OFF the main thread (append `step.bytes`, handle `.stalled` via
    /// `startJump(to:)`, report progress from `rowsDone`, read `budgetCapped` on
    /// `.done`) and `close`s it EXACTLY ONCE (cancel = stop + close). `rect` rows are
    /// VIEW-relative (FILTERED indices while a filter is active); columns are physical
    /// indices. Returns nil ONLY if the job handle couldn't be allocated. ADDITIVE:
    /// the RED default below returns nil (nothing copies) so existing conformers
    /// compile; the real conformer OVERRIDES it to open an `ls_copy_*` job wrapped as
    /// a `CopyStreaming`.
    func openCopy(_ rect: SelectionRect) -> (any CopyStreaming)?

    /// Release the core handle. Idempotent; nothing else may be called
    /// afterwards.
    func close()
}

public extension DocumentSession {
    /// DEFAULT (dense fallback) for the column-windowed `setWindow`: ignores
    /// `columns` and returns the full-width window from the dense
    /// `setWindow(firstRow:rowCount:)` (`firstColumn == 0`, every row
    /// `columnCount` cells wide). This keeps a conformer compiling before the
    /// column-fetch impl lands — but it fetches ALL columns, so a conformer that
    /// cares about wide-document cost MUST override this to fetch only `columns`
    /// (ARCH-column-windowing AC7). The column overload is a PROTOCOL REQUIREMENT
    /// (declared in the protocol body, not only here), so such an override is
    /// dispatched through `any DocumentSession` via the witness table — which is
    /// exactly what flips the AC7 fetch test from RED (this dense default) to
    /// GREEN (a real column-windowed fetch).
    func setWindow(firstRow: UInt64, rowCount: Int, columns: Range<Int>) -> RowWindow {
        setWindow(firstRow: firstRow, rowCount: rowCount)
    }

    /// DEFAULT (RED seed) for the lossless full-cell copy read: reports `.noCell`
    /// for every cell, so NOTHING copies through it. Keeps existing conformers
    /// compiling before the bridge lands (`copyCell` is a PROTOCOL REQUIREMENT —
    /// declared in the body above, not only here — so a real override is
    /// dispatched through `any DocumentSession` via the witness table). A
    /// conformer wires copy to the core by OVERRIDING this to call `ls_cell_copy`
    /// (fill a `maxBytes` buffer, map `ls_copy_result` → `CopiedCell`), which is
    /// exactly what flips the copy-bridge test from RED (this default: `.noCell`)
    /// to GREEN (the real lossless read, including a > 4 KiB cell copied whole).
    func copyCell(row: UInt64, column: Int, maxBytes: Int) -> CopiedCell {
        CopiedCell(status: .noCell, text: "", truncated: false)
    }

    /// DEFAULT (RED seed) for the per-window match flags: returns `[]` — no
    /// cell matches, so NOTHING highlights through it. Keeps existing conformers
    /// compiling before the bridge lands (`windowMatchFlags` is a PROTOCOL
    /// REQUIREMENT — declared in the body above, not only here — so a real
    /// override is dispatched through `any DocumentSession` via the witness
    /// table). A conformer wires highlights to the core by OVERRIDING this to
    /// call `ls_window_match_flags` (copy the borrowed flag bytes into a
    /// `[UInt8]`), which flips the golden bridge test from RED (this default:
    /// `[]`) to GREEN (the real per-cell verdicts, byte-identical to the
    /// former frontend-side matcher).
    func windowMatchFlags(firstColumn: Int, columnCount: Int) -> [UInt8] { [] }

    /// DEFAULT (RED seed) for the streaming copy: returns nil, so NOTHING copies
    /// through it. Keeps existing conformers compiling before the bridge lands
    /// (`openCopy` is a PROTOCOL REQUIREMENT — declared in the body above, not only
    /// here — so a real override is dispatched through `any DocumentSession` via the
    /// witness table). A conformer wires copy to the core by OVERRIDING this to open
    /// an `ls_copy_open` job wrapped as a `CopyStreaming` (driving `ls_copy_next` /
    /// `ls_copy_close`), which flips the golden streaming-copy bridge test from RED
    /// (this default: nil) to GREEN (the real core-framed TSV, byte-identical to the
    /// former per-cell builder).
    func openCopy(_ rect: SelectionRect) -> (any CopyStreaming)? { nil }
}
