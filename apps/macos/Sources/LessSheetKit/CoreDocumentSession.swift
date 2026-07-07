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
            index_mode: Int32(LS_INDEX_AUTO)
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
            headerForced: d.header_forced
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
        var rows = [[String]]()
        rows.reserveCapacity(Int(range.row_count))
        for row in range.first_row..<(range.first_row + range.row_count) {
            rows.append((0..<columnCount).map { Self.copyCell(ls_cell(doc, row, UInt32($0))) })
        }
        return RowWindow(firstRow: range.first_row, rows: rows)
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

    // MARK: - Search bridge (find-seek) — over ls_search_* in api/lesssheet.h.
    // These sit on the poll/control lane (internally synchronized, safe from any
    // thread except concurrently with ls_close — the app stops polling before
    // close), so they need no window-lane lock, exactly like the jump bridge.
    // The request struct + its value/scope buffers are borrowed only for the
    // duration of ls_search_start (the core copies what it keeps), so the
    // withUnsafeBufferPointer scopes cover the whole call.

    public func startSearch(_ request: SearchRequest) -> Bool {
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
                    // The local binding is for readability only — NOT
                    // load-bearing (a direct `return ls_search_start(...)` is
                    // equivalent). An earlier integration "rejection" here was a
                    // STALE LINK, not a marshaling bug: SwiftPM does not track
                    // liblesssheet.a as a build input (it is linked via -L /
                    // linkedLibrary in Package.swift), so the test binary stayed
                    // linked against the seed archive until a source edit forced
                    // a relink against the rebuilt core.
                    let started = ls_search_start(doc, &req)
                    return started
                }
                if let scope {
                    // nil scope means ALL columns; a concrete scope is fixed for
                    // the search's lifetime (visibility changes re-scope next run).
                    // A scope index outside UInt32 can never be a valid column —
                    // reject gracefully rather than trap on the conversion.
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
            // A column outside UInt32 can never be in-range — reject gracefully
            // rather than trap converting it (the core rejects out-of-range too).
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
                // Local binding for readability only (see the TEXT case).
                let started = ls_search_start(doc, &req)
                return started
            }
        }
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
