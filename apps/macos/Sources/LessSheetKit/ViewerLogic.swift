import Contracts

// Viewer-ui pure view-model logic (implementer-owned; conformances pinned by
// the frozen tests, semantics pinned in Sources/Contracts). No I/O, no core
// calls, no main-actor assumptions — these are value transforms the UI drives.

/// Implements `ColumnVisibilityManaging` (see its pinned semantics).
///
/// Hiding is pure presentation over the core's fixed column set: a value is a
/// column count plus the set of hidden indices, with the invariant that at
/// least one column stays visible whenever there is any column at all.
public struct ColumnVisibilityManager: ColumnVisibilityManaging {
    public init() {}

    public func allVisible(columnCount: Int) -> ColumnVisibility {
        ColumnVisibility(columnCount: max(columnCount, 0), hiddenColumns: [])
    }

    public func toggling(_ visibility: ColumnVisibility, column: Int) -> ColumnVisibility {
        guard (0..<visibility.columnCount).contains(column) else { return visibility }
        if visibility.isHidden(column) {
            // Unhiding is always allowed (it only ever increases the visible set).
            var hidden = visibility.hiddenColumns
            hidden.remove(column)
            return ColumnVisibility(columnCount: visibility.columnCount, hiddenColumns: hidden)
        }
        // Hiding a visible column is gated by the last-visible-column rule.
        guard canHide(visibility, column: column) else { return visibility }
        var hidden = visibility.hiddenColumns
        hidden.insert(column)
        return ColumnVisibility(columnCount: visibility.columnCount, hiddenColumns: hidden)
    }

    public func canHide(_ visibility: ColumnVisibility, column: Int) -> Bool {
        guard (0..<visibility.columnCount).contains(column) else { return false }
        guard !visibility.isHidden(column) else { return false }
        // At least one column must remain visible after hiding this one.
        let visibleCount = visibility.columnCount - visibility.hiddenColumns.count
        return visibleCount > 1
    }

    public func carriedOver(_ visibility: ColumnVisibility, toColumnCount newCount: Int) -> ColumnVisibility {
        // Same shape survives a dialect re-open; a changed column count resets.
        newCount == visibility.columnCount ? visibility : allVisible(columnCount: newCount)
    }

    public func visibleColumns(_ visibility: ColumnVisibility) -> [Int] {
        (0..<visibility.columnCount).filter { !visibility.isHidden($0) }
    }
}

/// Implements `JumpControlling` (see its pinned semantics).
///
/// Pure parsing of the 1-based digits-only row field plus the state machine
/// that folds `DocumentSession.jumpStatus()` polls into what the control shows
/// and remembers the pre-jump viewport for cancel-restore.
public struct JumpControl: JumpControlling {
    public init() {}

    public func parseTarget(_ input: String) -> UInt64? {
        guard !input.isEmpty else { return nil }
        // ASCII digits only — reject spaces, signs, dots, and non-ASCII numerals.
        guard input.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else { return nil }
        // Decimal parse; nil on overflow past UInt64.max.
        guard let oneBased = UInt64(input), oneBased >= 1 else { return nil }
        // UI copy is 1-based; the core addresses data rows 0-based.
        return oneBased - 1
    }

    public func begin(target: UInt64, preJumpFirstRow: UInt64) -> JumpFlow {
        .scanning(target: target, preJumpFirstRow: preJumpFirstRow, progress: 0)
    }

    public func resolve(_ flow: JumpFlow, with status: JumpStatus) -> JumpFlow {
        // Only an in-flight scan folds a poll; every other flow is stable.
        guard case let .scanning(target, preJumpFirstRow, progress) = flow else { return flow }
        switch status {
        case let .scanning(polled):
            // Display progress never regresses.
            return .scanning(target: target, preJumpFirstRow: preJumpFirstRow, progress: max(progress, polled))
        case let .done(landedRow):
            return .landed(row: landedRow)
        case .idle:
            // An idle poll never resets a live scan by itself (cancel does).
            return flow
        }
    }

    public func cancelled(_ flow: JumpFlow) -> JumpFlow {
        guard case let .scanning(_, preJumpFirstRow, _) = flow else { return flow }
        return .cancelled(restoreToFirstRow: preJumpFirstRow)
    }
}

/// Implements `DialectComposing` (see its pinned semantics).
///
/// Turns one overlay-control / Settings selection into the next open's override: carry
/// forward every already-forced parameter as forced, leave sniffed parameters
/// to be re-sniffed, then force the changed parameter — rejecting bytes out of
/// the ASCII domain or colliding with a *carried forced* value of the other.
public struct DialectComposer: DialectComposing {
    public init() {}

    public func compose(from current: DialectReport, changing change: DialectChange) -> DialectOverride? {
        let carriedSeparator: SeparatorOverride =
            current.separatorForced ? .forced(current.separator) : .sniff
        let carriedQuote: QuoteOverride = {
            guard current.quoteForced else { return .sniff }
            if let q = current.quote { return .forced(q) }
            return .none
        }()
        let carriedHeader: HeaderOverride =
            current.headerForced ? (current.hasHeader ? .on : .off) : .sniff

        switch change {
        case let .separator(byte):
            guard Self.isValidDialectByte(byte) else { return nil }
            // Collision only against a byte the caller is CARRYING as forced.
            if case let .forced(q) = carriedQuote, q == byte { return nil }
            return DialectOverride(separator: .forced(byte), quote: carriedQuote, header: carriedHeader)

        case let .quote(maybeByte):
            guard let byte = maybeByte else {
                // NONE disables quoting; it can never collide with a separator.
                return DialectOverride(separator: carriedSeparator, quote: .none, header: carriedHeader)
            }
            guard Self.isValidDialectByte(byte) else { return nil }
            if case let .forced(s) = carriedSeparator, s == byte { return nil }
            return DialectOverride(separator: carriedSeparator, quote: .forced(byte), header: carriedHeader)

        case let .header(isOn):
            // Header changes are always valid.
            return DialectOverride(separator: carriedSeparator, quote: carriedQuote, header: isOn ? .on : .off)
        }
    }

    /// A separator/quote byte is a single ASCII byte in 0x01...0x7F that is
    /// neither CR nor LF (mirrors the `api/lesssheet.h` field domain).
    static func isValidDialectByte(_ byte: UInt8) -> Bool {
        (0x01...0x7F).contains(byte) && byte != 0x0A && byte != 0x0D
    }
}
