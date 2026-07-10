import CLessSheet
import Contracts
import Foundation

/// Swift bridge over the core C ABI (`api/lesssheet.h` via CLessSheet):
/// opens live windowed sessions, maps the option/report/progress/jump/search
/// types, and copies every borrowed cell out of the core before returning
/// (respecting the eviction-safe borrow rule; invalid UTF-8 becomes U+FFFD).
///
/// Threading: the C contract makes the poll/control lane internally
/// synchronized; the window lane (ls_window_set + cell reads) must be
/// serialized by the caller — `CoreDocumentSession` owns a lock around it
/// (and around close), which is what makes the class honestly Sendable.
public struct CoreSessionOpener: DocumentSessionOpening {
    public init() {}

    /// A dedicated background queue for the core's O(head) open. Keeps the
    /// blocking `ls_open` (up to LS_OPEN_HEAD_MAX_BYTES of file I/O) off the
    /// calling actor so a main-actor caller's run loop is never blocked during
    /// cold start — structurally, not by relying on a nonisolated-async
    /// executor default that a future language mode could change.
    private static let openQueue = DispatchQueue(label: "less-sheet.core-open", qos: .userInitiated)

    public func open(path: String, forcing override: DialectOverride) async throws(DocumentOpenError) -> any DocumentSession {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CoreDocumentSession, any Error>) in
                Self.openQueue.async {
                    do {
                        continuation.resume(returning: try CoreDocumentSession(path: path, forcing: override))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch let error as DocumentOpenError {
            throw error
        } catch {
            // Unreachable: CoreDocumentSession.init throws only DocumentOpenError.
            throw DocumentOpenError.io
        }
    }
}

/// One live core document. See `DocumentSession` for the full contract.
public final class CoreDocumentSession: DocumentSession, @unchecked Sendable {
    private let doc: OpaquePointer
    private let lock = NSLock()
    private var isClosed = false

    public let columnCount: Int
    public let dialect: DialectReport
    public let headerCells: [String]?

    init(path: String, forcing override: DialectOverride) throws(DocumentOpenError) {
        var options = ls_open_options(
            separator: Self.abiSeparator(override.separator),
            quote: Self.abiQuote(override.quote),
            header: Self.abiHeader(override.header),
            index_mode: Int32(LS_INDEX_AUTO),
            encoding: Self.abiEncodingOption(override.encoding)
        )
        var handle: OpaquePointer?
        let status = path.withCString { ls_open($0, &options, &handle) }
        if let error = DocumentOpenError(abiCode: Int32(status.rawValue)) {
            throw error
        }
        guard let doc = handle else { throw DocumentOpenError.io }
        self.doc = doc

        columnCount = Int(ls_column_count(doc))
        let d = ls_dialect_get(doc)
        dialect = DialectReport(
            separator: d.separator,
            quote: d.has_quote ? d.quote : nil,
            hasHeader: d.header,
            separatorForced: d.separator_forced,
            quoteForced: d.quote_forced,
            headerForced: d.header_forced,
            encoding: Self.abiEncoding(d.encoding),
            encodingForced: d.encoding_forced
        )
        if d.header {
            headerCells = (0..<columnCount).map { Self.copyCell(ls_header_cell(doc, UInt32($0))) }
        } else {
            headerCells = nil
        }
    }

    deinit { close() }

    public func rowCount() -> RowCountInfo {
        let rc = ls_row_count_get(doc)
        return RowCountInfo(count: rc.count, isExact: rc.exact)
    }

    public func indexProgress() -> ScanProgress {
        let p = ls_index_poll(doc)
        return ScanProgress(bytesScanned: p.bytes_scanned, bytesTotal: p.bytes_total, isComplete: p.complete)
    }

    public func setWindow(firstRow: UInt64, rowCount: Int) -> RowWindow {
        lock.lock()
        defer { lock.unlock() }
        let clamped = UInt32(clamping: max(rowCount, 0))
        let range = ls_window_set(doc, firstRow, clamped)
        // The dense overload always asks for every column — no clamp needed,
        // `0..<columnCount` is already exactly the valid domain.
        return fetchWindow(range, columns: 0..<columnCount)
    }

    /// COLUMN-WINDOWED override (ARCH-column-windowing AC7 — the round-2
    /// amendment): identical ROW handling to the dense overload above, but
    /// reads cells/flags for ONLY `columns` (clamped to `0..<columnCount`)
    /// instead of every column, so the fetch is O(rows x columns.count) FFI
    /// calls, never O(rows x columnCount). `ViewerModel.materialize` routes
    /// through this with the live horizontal column window as `columns`,
    /// which is what carries a wide document's cold-open (and every
    /// scroll-materialize) back under budget — the dense overload's own
    /// `ls_cell`/`ls_cell_truncated` fetch of ALL columns, on EVERY
    /// materialize, was measured (round-1 hand-off) at ~180 ms for
    /// wide_100k_cols alone. Overriding the PROTOCOL REQUIREMENT (not just the
    /// default extension) means this is what `any DocumentSession` dispatches
    /// to — exactly what flips AC7 from the frozen RED seed (the dense
    /// fallback) to GREEN.
    public func setWindow(firstRow: UInt64, rowCount: Int, columns: Range<Int>) -> RowWindow {
        lock.lock()
        defer { lock.unlock() }
        let clamped = UInt32(clamping: max(rowCount, 0))
        let range = ls_window_set(doc, firstRow, clamped)
        return fetchWindow(range, columns: columns.clamped(to: 0..<columnCount))
    }

    /// Shared row+column materialize (window lane; caller already holds
    /// `lock`): copies cells/truncation/oversized flags for exactly `columns`
    /// (already clamped to `0..<columnCount` by the caller) over the row
    /// range `ls_window_set` just served, producing a `RowWindow` whose
    /// `firstColumn` is `columns.lowerBound` and whose rows are exactly
    /// `columns.count` wide — `columns == 0..<columnCount` (the dense
    /// overload's call) yields `firstColumn == 0` and full-width rows,
    /// byte-identical to what `setWindow(firstRow:rowCount:)` served before
    /// this override existed.
    private func fetchWindow(_ range: ls_row_range, columns: Range<Int>) -> RowWindow {
        var rows = [[String]]()
        var truncated = [[Bool]]()
        var oversized = [Bool]()
        rows.reserveCapacity(Int(range.row_count))
        truncated.reserveCapacity(Int(range.row_count))
        oversized.reserveCapacity(Int(range.row_count))
        for row in range.first_row..<(range.first_row + range.row_count) {
            rows.append(columns.map { Self.copyCell(ls_cell(doc, row, UInt32($0))) })
            truncated.append(columns.map { ls_cell_truncated(doc, row, UInt32($0)) })
            // Per-row OVERSIZED flag (ls_row_oversized): true iff the row's
            // source extent exceeded LS_WINDOW_ROW_SCAN_MAX_BYTES and it was
            // served as a bounded prefix. Window lane, so under the same lock.
            oversized.append(ls_row_oversized(doc, row))
        }
        return RowWindow(firstRow: range.first_row, firstColumn: columns.lowerBound, rows: rows, truncated: truncated, oversized: oversized)
    }

    public func startJump(to targetRow: UInt64) {
        ls_jump_start(doc, targetRow)
    }

    public func cancelJump() {
        ls_jump_cancel(doc)
    }

    public func jumpStatus() -> JumpStatus {
        let s = ls_jump_poll(doc)
        switch s.state.rawValue {
        case ls_jump_state.RawValue(LS_JUMP_SCANNING.rawValue):
            return .scanning(progress: s.progress)
        case ls_jump_state.RawValue(LS_JUMP_DONE.rawValue):
            return .done(landedRow: s.landed_row)
        default:
            return .idle
        }
    }

    // MARK: - Search + filter request marshaling (shared) — ls_search_start
    // (Find) and ls_filter_set (filtered-views) both take a freshly built
    // ls_search_request, validated identically by the core (api/lesssheet.h).
    // Both sit on the poll/control lane (internally synchronized, safe from any
    // thread except concurrently with ls_close — the app stops polling before
    // close), so neither needs the window-lane lock, exactly like the jump
    // bridge. The request struct + its value/scope buffers are borrowed only
    // for the duration of the one call (the core copies what it keeps), so the
    // withUnsafeBufferPointer scopes cover exactly that call.
    //
    // NOTE: an earlier integration "rejection" on this path was mistaken for a
    // marshaling bug — it was actually a STALE LINK. SwiftPM does not track
    // liblesssheet.a as a build input (it is linked via -L / linkedLibrary in
    // Package.swift), so the test binary stayed linked against the seed
    // archive until a source edit forced a relink against the rebuilt core
    // (see the STALE-LINK GUARD in .aidev/profile.sh).

    /// Builds the `ls_search_request` for `request` and hands it to `body`
    /// (either `ls_search_start` or `ls_filter_set`) with its buffers alive
    /// for the call. A scope/column index outside UInt32 can never be a valid
    /// column — reject gracefully (false) rather than trap converting it; the
    /// core rejects genuinely out-of-range indices itself.
    private func withSearchRequest(_ request: SearchRequest, _ body: (inout ls_search_request) -> Bool) -> Bool {
        switch request {
        case let .text(query, scope):
            let value = Array(query.utf8)
            return value.withUnsafeBufferPointer { valueBuffer in
                func run(scopePtr: UnsafePointer<UInt32>?, scopeLen: Int) -> Bool {
                    var req = ls_search_request(
                        kind: LS_SEARCH_TEXT,
                        op: LS_SEARCH_OP_EQ,          // ignored for TEXT
                        column: 0,                    // ignored for TEXT
                        value_ptr: valueBuffer.baseAddress,
                        value_len: valueBuffer.count,
                        scope_ptr: scopePtr,
                        scope_len: scopeLen
                    )
                    return body(&req)
                }
                if let scope {
                    // nil scope means ALL columns; a concrete scope is fixed for
                    // the search's lifetime (visibility changes re-scope next run).
                    var columns = [UInt32]()
                    columns.reserveCapacity(scope.count)
                    for index in scope {
                        guard let column = UInt32(exactly: index) else { return false }
                        columns.append(column)
                    }
                    return columns.withUnsafeBufferPointer { run(scopePtr: $0.baseAddress, scopeLen: $0.count) }
                }
                return run(scopePtr: nil, scopeLen: 0)
            }
        case let .predicate(column, op, value):
            guard let abiColumn = UInt32(exactly: column) else { return false }
            let value = Array(value.utf8)
            return value.withUnsafeBufferPointer { valueBuffer in
                var req = ls_search_request(
                    kind: LS_SEARCH_PREDICATE,
                    op: Self.abiOp(op),
                    column: abiColumn,
                    value_ptr: valueBuffer.baseAddress,
                    value_len: valueBuffer.count,
                    scope_ptr: nil,                   // ignored for PREDICATE
                    scope_len: 0
                )
                return body(&req)
            }
        }
    }

    public func startSearch(_ request: SearchRequest) -> Bool {
        withSearchRequest(request) { req in ls_search_start(doc, &req) }
    }

    public func navigateSearch(_ nav: SearchNav) {
        ls_search_nav(doc, nav.anchor, Self.abiDir(nav.direction))
    }

    public func cancelSearch() {
        ls_search_cancel(doc)
    }

    public func searchStatus() -> SearchSnapshot? {
        let s = ls_search_poll(doc)
        let phase: SearchScanPhase
        switch s.state.rawValue {
        case ls_search_state.RawValue(LS_SEARCH_SCANNING.rawValue):
            phase = .scanning(progress: s.progress)
        case ls_search_state.RawValue(LS_SEARCH_DONE.rawValue):
            phase = .done
        case ls_search_state.RawValue(LS_SEARCH_CANCELLED.rawValue):
            phase = .cancelled(progress: s.progress)
        default:
            // LS_SEARCH_IDLE (no search started on this handle) -> nil snapshot;
            // a fresh session, including a dialect re-open, reports this.
            return nil
        }
        let nav: SearchNavStatus
        switch s.nav.rawValue {
        case ls_search_nav_state.RawValue(LS_SEARCH_NAV_SEARCHING.rawValue):
            nav = .searching
        case ls_search_nav_state.RawValue(LS_SEARCH_NAV_FOUND.rawValue):
            nav = .found(SearchMatch(row: s.found_row, column: Int(s.found_col)), position: s.position)
        case ls_search_nav_state.RawValue(LS_SEARCH_NAV_EXHAUSTED.rawValue):
            nav = .exhausted
        default:
            nav = .none   // LS_SEARCH_NAV_NONE
        }
        return SearchSnapshot(phase: phase, nav: nav, total: s.total, totalIsFinal: s.total_exact)
    }

    // MARK: - Filter bridge (filtered-views) — over ls_filter_* / ls_source_row
    // in api/lesssheet.h. ls_filter_set / ls_filter_clear / ls_filter_poll sit
    // on the poll/control lane, exactly like the search bridge above (no
    // window-lane lock). ls_source_row, though, is grouped with ls_window_set /
    // ls_cell / ls_header_cell in the THREADING section — the WINDOW lane — so
    // it takes the same `lock` as `setWindow`.

    public func setFilter(_ request: SearchRequest) -> Bool {
        withSearchRequest(request) { req in ls_filter_set(doc, &req) }
    }

    public func clearFilter() {
        ls_filter_clear(doc)
    }

    public func filterStatus() -> FilterSnapshot? {
        let s = ls_filter_poll(doc)
        let phase: FilterScanPhase
        switch s.state.rawValue {
        case ls_filter_state.RawValue(LS_FILTER_SCANNING.rawValue):
            phase = .scanning(progress: s.progress)
        case ls_filter_state.RawValue(LS_FILTER_DONE.rawValue):
            phase = .done
        case ls_filter_state.RawValue(LS_FILTER_CANCELLED.rawValue):
            phase = .cancelled(progress: s.progress)
        default:
            // LS_FILTER_IDLE -> nil snapshot; no filter active (identity view),
            // exactly like a fresh/re-opened handle's search state.
            return nil
        }
        return FilterSnapshot(phase: phase, total: s.total, totalIsFinal: s.total_exact)
    }

    public func sourceRow(_ viewRow: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        let row = ls_source_row(doc, viewRow)
        return row == UInt64(LS_NO_ROW) ? nil : row
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        ls_close(doc)
    }

    // MARK: - ABI mapping

    private static func abiSeparator(_ s: SeparatorOverride) -> Int32 {
        switch s {
        case .sniff: Int32(LS_SNIFF)
        case let .forced(byte): Int32(byte)
        }
    }

    private static func abiQuote(_ q: QuoteOverride) -> Int32 {
        switch q {
        case .sniff: Int32(LS_SNIFF)
        case .none: Int32(LS_QUOTE_NONE)
        case let .forced(byte): Int32(byte)
        }
    }

    private static func abiHeader(_ h: HeaderOverride) -> Int32 {
        switch h {
        case .sniff: Int32(LS_SNIFF)
        case .on: Int32(LS_HEADER_ON)
        case .off: Int32(LS_HEADER_OFF)
        }
    }

    /// The encoding override as its ABI value (LS_ENCODING_AUTO + concretes).
    private static func abiEncodingOption(_ e: EncodingOverride) -> Int32 {
        switch e {
        case .automatic: Int32(LS_ENCODING_AUTO)
        case .utf8: Int32(LS_ENCODING_UTF8)
        case .utf16LE: Int32(LS_ENCODING_UTF16LE)
        case .utf16BE: Int32(LS_ENCODING_UTF16BE)
        case .latin1: Int32(LS_ENCODING_LATIN1)
        case .windows1252: Int32(LS_ENCODING_WINDOWS1252)
        }
    }

    /// The reported resolved encoding (ls_dialect.encoding: a concrete uint8
    /// enum value, never LS_ENCODING_AUTO) as its Swift `TextEncoding`.
    private static func abiEncoding(_ raw: UInt8) -> TextEncoding {
        TextEncoding(rawValue: raw) ?? .utf8
    }

    /// The predicate operator as its ABI enum (raw values pinned in the header).
    private static func abiOp(_ op: SearchOperator) -> ls_search_op {
        switch op {
        case .equals: LS_SEARCH_OP_EQ
        case .notEquals: LS_SEARCH_OP_NE
        case .lessThan: LS_SEARCH_OP_LT
        case .greaterThan: LS_SEARCH_OP_GT
        case .lessOrEqual: LS_SEARCH_OP_LE
        case .greaterOrEqual: LS_SEARCH_OP_GE
        }
    }

    private static func abiDir(_ dir: SearchDirection) -> ls_search_dir {
        switch dir {
        case .forward: LS_SEARCH_FORWARD
        case .backward: LS_SEARCH_BACKWARD
        }
    }

    /// Copies borrowed UTF-8 bytes into an owned String, replacing invalid
    /// sequences with U+FFFD. The empty borrow (`len == 0`) copies to "".
    private static func copyCell(_ str: ls_str) -> String {
        guard str.len > 0, let ptr = str.ptr else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: str.len), as: UTF8.self)
    }
}
