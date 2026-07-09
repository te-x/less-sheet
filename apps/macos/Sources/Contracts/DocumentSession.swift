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

/// One materialized row window (mirrors the result of `ls_window_set` plus
/// the copied cells): `rows[i]` is data row `firstRow + i`, each exactly
/// `columnCount` cells wide (truncate/pad applied by the core). `rows` may
/// be shorter than requested — or empty — when the requested range extends
/// beyond the scan frontier or the document; the missing rows become
/// available by re-requesting after the frontier advances (poll-driven).
public struct RowWindow: Equatable, Sendable {
    public let firstRow: UInt64
    public let rows: [[String]]
    /// Per-cell display-truncation flags, PARALLEL to `rows`: `truncated[i][j]`
    /// is true iff cell (i, j) was cut by the core's per-cell display cap
    /// (`ls_cell_truncated`). Same shape as `rows` (each row's flags count ==
    /// that row's cell count); empty only when `rows` is empty. The cut is
    /// DISPLAY-ONLY — the full cell is still searchable (grids render a
    /// truncation indicator from this flag, ARCH req. 13/20).
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

    public init(firstRow: UInt64, rows: [[String]], truncated: [[Bool]] = [], oversized: [Bool] = []) {
        self.firstRow = firstRow
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
    /// Never scans; synchronous-fast.
    func setWindow(firstRow: UInt64, rowCount: Int) -> RowWindow

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

    /// Release the core handle. Idempotent; nothing else may be called
    /// afterwards.
    func close()
}

/// Opens document sessions through the core's C ABI. This is the ONLY entry
/// to document data; all user-facing opens (panel, launch-with-file, CLI,
/// drag & drop, dialect re-open) funnel into one call of this.
///
/// Contract:
/// - `async` and safe to call from any actor, INCLUDING the main actor: the
///   implementation never blocks the main thread (the core's O(head) open
///   runs off it).
/// - The session's background index runs in AUTO mode (starts at open).
/// - An empty file is NOT an error: it yields a session with 0 columns and
///   an exact row count of 0.
/// - Failures throw the distinct `DocumentOpenError` mapped from the ABI
///   code (including `.invalidArgument` for an out-of-domain override).
/// - A dialect change is a RE-OPEN: open the same path again with the
///   composed override and close the old session (ARCH req. 10 — the index
///   restarts; hidden-column state is handled per `ColumnVisibilityManaging`,
///   and find state per `FindControlling.invalidated` — results clear, the
///   typed query survives).
public protocol DocumentSessionOpening: Sendable {
    func open(path: String, forcing override: DialectOverride) async throws(DocumentOpenError) -> any DocumentSession
}
