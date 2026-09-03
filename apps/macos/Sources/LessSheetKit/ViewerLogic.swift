import Contracts

// Pure view-model transforms the UI drives: no I/O, no core calls, no
// main-actor assumptions. Semantics live in the `Contracts` protocols.

/// Column hiding, pure presentation over the core's fixed column set: a column
/// count plus the hidden indices, with the invariant that at least one column
/// stays visible whenever there is any column at all.
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

/// Parses the 1-based digits-only row field and folds `jumpStatus()` polls into
/// what the control shows, remembering the pre-jump viewport for cancel-restore.
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
            // Displayed progress never regresses.
            return .scanning(target: target, preJumpFirstRow: preJumpFirstRow, progress: max(progress, polled))
        case let .done(landedRow):
            return .landed(row: landedRow)
        case .idle:
            // An idle poll never resets a live scan by itself; cancel does.
            return flow
        }
    }

    public func cancelled(_ flow: JumpFlow) -> JumpFlow {
        guard case let .scanning(_, preJumpFirstRow, _) = flow else { return flow }
        return .cancelled(restoreToFirstRow: preJumpFirstRow)
    }
}

/// Turns one dialect selection into the next open's override: carry every
/// already-forced parameter forward as forced, leave sniffed parameters to be
/// re-sniffed, then force the changed one — rejecting bytes outside the ASCII
/// domain or colliding with a *carried forced* value of the other.
public struct DialectComposer: DialectComposing {
    public init() {}

    public func compose(from current: DialectReport, changing change: DialectChange) -> DialectOverride? {
        let carried = carriedOverrides(from: current)

        switch change {
        case let .separator(byte):
            guard Self.isValidDialectByte(byte) else { return nil }
            // Collision only against a byte the caller is CARRYING as forced.
            if case let .forced(quoteByte) = carried.quote, quoteByte == byte { return nil }
            return DialectOverride(separator: .forced(byte), quote: carried.quote,
                                   header: carried.header, encoding: carried.encoding)

        case let .quote(maybeByte):
            guard let byte = maybeByte else {
                // NONE disables quoting; it can never collide with a separator.
                return DialectOverride(separator: carried.separator, quote: .none,
                                       header: carried.header, encoding: carried.encoding)
            }
            guard Self.isValidDialectByte(byte) else { return nil }
            if case let .forced(separatorByte) = carried.separator, separatorByte == byte { return nil }
            return DialectOverride(separator: carried.separator, quote: .forced(byte),
                                   header: carried.header, encoding: carried.encoding)

        case let .header(isOn):
            // Header changes are always valid.
            return DialectOverride(separator: carried.separator, quote: carried.quote,
                                   header: isOn ? .forcedOn : .forcedOff, encoding: carried.encoding)

        case let .encoding(chosen):
            // Never fails and never touches the dialect bytes; `.automatic`
            // re-detects on the re-open.
            return DialectOverride(separator: carried.separator, quote: carried.quote,
                                   header: carried.header, encoding: chosen)
        }
    }

    private struct CarriedOverrides {
        let separator: SeparatorOverride
        let quote: QuoteOverride
        let header: HeaderOverride
        let encoding: EncodingOverride
    }

    private func carriedOverrides(from current: DialectReport) -> CarriedOverrides {
        let separator: SeparatorOverride =
            current.separatorForced ? .forced(current.separator) : .sniff
        let quote: QuoteOverride = {
            guard current.quoteForced else { return .sniff }
            if let quoteByte = current.quote { return .forced(quoteByte) }
            return .none
        }()
        let header: HeaderOverride =
            current.headerForced ? (current.hasHeader ? .forcedOn : .forcedOff) : .sniff
        let encoding: EncodingOverride =
            current.encodingForced ? EncodingOverride(current.encoding) : .automatic
        return CarriedOverrides(separator: separator, quote: quote, header: header, encoding: encoding)
    }

    /// A single ASCII byte in 0x01...0x7F that is neither CR nor LF — the
    /// separator/quote domain `api/lesssheet.h` pins.
    static func isValidDialectByte(_ byte: UInt8) -> Bool {
        (0x01...0x7F).contains(byte) && byte != 0x0A && byte != 0x0D
    }
}
