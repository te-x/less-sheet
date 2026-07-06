import CLessSheet
import Contracts
import Foundation

/// Swift bridge over the core C ABI (`api/lesssheet.h` via CLessSheet):
/// opens live windowed sessions, maps the option/report/progress/jump types,
/// and copies every borrowed cell out of the core before returning
/// (respecting the eviction-safe borrow rule; invalid UTF-8 becomes U+FFFD).
///
/// Threading: the C contract makes the poll/control lane internally
/// synchronized; the window lane (ls_window_set + cell reads) must be
/// serialized by the caller — `CoreDocumentSession` owns a lock around it
/// (and around close), which is what makes the class honestly Sendable.
public struct CoreSessionOpener: DocumentSessionOpening {
    public init() {}

    public func open(path: String, forcing override: DialectOverride) async throws(DocumentOpenError) -> any DocumentSession {
        try CoreDocumentSession(path: path, forcing: override)
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

    /// Copies borrowed UTF-8 bytes into an owned String, replacing invalid
    /// sequences with U+FFFD. The empty borrow (`len == 0`) copies to "".
    private static func copyCell(_ str: ls_str) -> String {
        guard str.len > 0, let ptr = str.ptr else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: str.len), as: UTF8.self)
    }
}
