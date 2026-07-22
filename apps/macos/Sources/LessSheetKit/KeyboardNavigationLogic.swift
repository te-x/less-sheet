import Contracts

// GREEN (implementer) — the pure keyboard-navigation logic (ARCH-macos-kbdnav).
// Implementer-owned and NON-frozen (Sources/LessSheetKit); each type CONFORMS
// to its frozen `Contracts` protocol and implements the real algebra the
// doc-comments specify. The App (SheetTableView key routing, NativeGridController
// clip scroll, SheetRowView outline paint, handleEscape dispatch) routes through
// these; none of this touches a frozen path.
//
//   KeyboardNavigator ... the target-cell reducer over the ONE shared selection,
//     COMPOSING the injected `Selecting` (`select` / `extend(_:to:in:)`) — it
//     never re-implements the clamp or the anchor/active algebra.
//   RevealScroller ...... the byte-exact minimal-reveal clamp on each axis.
//   EscapeResolver ...... the Esc precedence truth table (dismiss > cancel >
//     clear > none).

// MARK: - KeyboardNavigating (FR1)

/// The target-cell reducer over the ONE shared selection. Holds a `Selecting`
/// (default `SelectionModel`) and produces every result through it, so there is
/// a single source of selection geometry.
public struct KeyboardNavigator: KeyboardNavigating {
    private let selecting: any Selecting

    public init(selecting: any Selecting = SelectionModel()) {
        self.selecting = selecting
    }

    public func navigate(from selection: Selection?, _ motion: NavigationMotion,
                         extending: Bool, in context: NavigationContext) -> Selection? {
        // Empty extent OR no visible columns → nothing is selectable, so every
        // command (plain or extending, from nil or a stale selection) is a
        // no-op, matching the frozen `Selecting` producing-ops.
        guard !context.extent.isEmpty, !context.visibleColumns.isEmpty else { return nil }

        // SEED (no step): the first command with nothing selected places a 1×1
        // cursor at the top-left visible cell and applies NO step (Q1) — the
        // extending variants seed too (there is no anchor to extend from yet).
        guard let current = selection else {
            return selecting.select(
                GridCell(row: context.topVisibleRow, column: context.firstVisibleColumn),
                in: context.extent)
        }

        // Resolve the active corner onto a VISIBLE column FIRST, so the result
        // always has a visible active column (never an invisible cursor); a
        // hidden active column — reachable only via Cmd+A / whole-row select —
        // snaps to the nearest visible column at or below it, else the first.
        let activeRow = min(current.active.row, context.extent.lastRow)
        let activeColumn = Self.resolvedVisibleColumn(current.active.column, in: context.visibleColumns)
        let target = Self.target(motion, row: activeRow, column: activeColumn, in: context)

        return extending ? selecting.extend(current, to: target, in: context.extent)
                         : selecting.select(target, in: context.extent) ?? current
    }

    /// The target cell for `motion` from the (already visible-resolved) active
    /// corner. Row commands keep `column`; column commands keep `row` and step
    /// over the visible-columns list. Clamping to the extent is left to the
    /// frozen `Selecting`; only the visible-column walk and the saturating row
    /// arithmetic live here.
    private static func target(_ motion: NavigationMotion, row: UInt64, column: Int,
                               in context: NavigationContext) -> GridCell {
        let lastRow = context.extent.lastRow
        let visible = context.visibleColumns
        switch motion {
        case .upward:
            return GridCell(row: row == 0 ? 0 : row - 1, column: column)
        case .down:
            return GridCell(row: row >= lastRow ? lastRow : row + 1, column: column)
        case .pageUp:
            return GridCell(row: row > context.pageRows ? row - context.pageRows : 0, column: column)
        case .pageDown:
            let remaining = lastRow - row
            return GridCell(row: context.pageRows >= remaining ? lastRow : row + context.pageRows, column: column)
        case .documentStart:
            return GridCell(row: 0, column: column)
        case .documentEnd:
            return GridCell(row: lastRow, column: column)
        case .left:
            return GridCell(row: row, column: Self.step(column, by: -1, in: visible))
        case .right:
            return GridCell(row: row, column: Self.step(column, by: 1, in: visible))
        case .lineStart:
            return GridCell(row: row, column: visible.first ?? column)
        case .lineEnd:
            return GridCell(row: row, column: visible.last ?? column)
        }
    }

    /// The visible column one step (`±1`) from `column` in the ordered
    /// `visible` list, clamped at the ends (a step past an edge stays on the
    /// edge). `column` is assumed already resolved into `visible`.
    private static func step(_ column: Int, by delta: Int, in visible: [Int]) -> Int {
        guard let index = visible.firstIndex(of: column) else { return column }
        let next = index + delta
        guard visible.indices.contains(next) else { return column }
        return visible[next]
    }

    /// `column` snapped into `visible` (ascending): itself if already visible;
    /// otherwise the nearest visible column AT OR BELOW it, else the first
    /// visible column. `visible` is non-empty by the caller's guard.
    private static func resolvedVisibleColumn(_ column: Int, in visible: [Int]) -> Int {
        if let atOrBelow = visible.last(where: { $0 <= column }) { return atOrBelow }
        return visible[0]
    }
}

// MARK: - RevealScrolling (FR2)

/// The minimal-reveal auto-scroll math — one 1-D `landOn`-style clamp per axis,
/// each independent, no move when the cell is already fully visible.
public struct RevealScroller: RevealScrolling {
    public init() {}

    public func reveal(vertical: VerticalReveal, horizontal: HorizontalReveal) -> RevealScroll {
        let top = Double(vertical.activeRow) * vertical.rowHeight
        let originY = Self.reveal(
            cell: (top, top + vertical.rowHeight), origin: vertical.originY,
            insetLeading: vertical.contentInsetTop, extent: vertical.viewportHeight,
            bounds: (-vertical.contentInsetTop, vertical.maxY))
        let originX = Self.reveal(
            cell: (horizontal.leftX, horizontal.leftX + horizontal.width), origin: horizontal.originX,
            insetLeading: 0, extent: horizontal.viewportWidth, bounds: (0, horizontal.maxX))
        return RevealScroll(originX: originX, originY: originY,
                            movedX: originX != horizontal.originX, movedY: originY != vertical.originY)
    }

    /// The minimal new clip origin on one axis. `cell` occupies
    /// `[leading, trailing)`; the UNOBSCURED viewport region is
    /// `[origin + insetLeading, origin + extent)`. If the cell is above/left of
    /// it, reveal its leading edge past the inset; if below/right, reveal its
    /// trailing edge to the viewport edge; otherwise keep the origin. Clamped to
    /// `bounds` (`[min, max]`).
    private static func reveal(cell: (leading: Double, trailing: Double), origin: Double,
                               insetLeading: Double, extent: Double,
                               bounds: (min: Double, max: Double)) -> Double {
        let visibleLeading = origin + insetLeading
        let visibleTrailing = origin + extent
        let target: Double
        if cell.leading < visibleLeading {
            target = cell.leading - insetLeading
        } else if cell.trailing > visibleTrailing {
            target = cell.trailing - extent
        } else {
            target = origin
        }
        return min(max(target, bounds.min), bounds.max)
    }
}

// MARK: - EscapeResolving (FR3)

/// The Esc-precedence resolver — one pure truth table in strict priority order.
public struct EscapeResolver: EscapeResolving {
    public init() {}

    public func resolve(_ context: EscapeContext) -> EscapeAction {
        if context.popupOrSearchActive { return .dismissPopups }
        if context.copyInFlight { return .cancelCopy }
        if context.hasSelection { return .clearSelection }
        return .none
    }
}
