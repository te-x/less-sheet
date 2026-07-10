import Contracts

// RED SEED (planner freeze) — the pure select-copy logic (ARCH-select-copy),
// implementer-owned and NON-frozen (Sources/LessSheetKit). Each type CONFORMS to
// its frozen Contracts protocol (so the conformance pins compile) but returns
// TRIVIAL results, so the frozen AC tests fail on BEHAVIOR, never on compile /
// import — exactly the pattern of ColumnLayoutLogic.swift's original seed.
//
// RED → GREEN (implementer): replace each stub body with the real algebra the
// contract doc-comments specify, and route the App (NativeGrid event handling +
// ViewerModel selection/copy/width state) through these. None of that touches a
// frozen path.

// MARK: - Selecting (AC1)

/// RED: every producing op returns nil and every transition returns its input
/// unchanged, so NO interaction yields the expected rect. GREEN: normalize
/// anchor+active into the rect, clamp to the extent, and place the corners for
/// whole-row / whole-column / select-all per `Selecting`'s pinned semantics —
/// all O(1) in the extent (Cmd+A on 100M×100k is free).
public struct SelectionModel: Selecting {
    public init() {}

    public func select(_ cell: GridCell, in extent: GridExtent) -> Selection? {
        nil
    }

    public func extend(_ selection: Selection, to cell: GridCell, in extent: GridExtent) -> Selection {
        selection
    }

    public func move(_ selection: Selection, _ direction: SelectionDirection, in extent: GridExtent) -> Selection {
        selection
    }

    public func extend(_ selection: Selection, _ direction: SelectionDirection, in extent: GridExtent) -> Selection {
        selection
    }

    public func wholeRow(_ row: UInt64, in extent: GridExtent) -> Selection? {
        nil
    }

    public func wholeColumn(_ column: Int, in extent: GridExtent) -> Selection? {
        nil
    }

    public func selectAll(in extent: GridExtent) -> Selection? {
        nil
    }
}

// MARK: - CopyBuilding (AC2 / AC3)

/// RED: returns an EMPTY report for any rect — nothing built, nothing bounded,
/// no quoting, no ordering. GREEN: iterate the rect row-major calling `fetch`,
/// apply the single-cell / TSV / Excel-quoting rules, and stop at the byte
/// budget OR the cell-count safety cap OR a `.pending` frontier row, reporting
/// bytes / rows / outcome / lossiness per `CopyBuilding.build`'s spec.
public struct TSVCopyBuilder: CopyBuilding {
    public init() {}

    public func build(_ rect: SelectionRect, budget: CopyBudget, fetch: CopyCellFetch) -> CopyReport {
        CopyReport(text: "", byteCount: 0, rowCount: 0, outcome: .complete, lossyCells: false)
    }
}

// MARK: - ColumnSizing (AC5)

/// RED: `effectiveWidths` ignores the manual map (returns the auto baseline), the
/// map transitions return the map unchanged, and `autoFit` always returns the
/// floor — so a manual width never sticks/overrides, clearing does nothing, and
/// auto-fit never computes the content fit. GREEN: overlay manual over auto
/// (manual wins), set/clear the absolute-keyed override, and compute the exact
/// clamped max-content fit per `ColumnSizing`'s pinned semantics.
public struct ColumnSizer: ColumnSizing {
    public init() {}

    public func effectiveWidths(auto: [Double], manual: [Int: Double]) -> [Double] {
        auto
    }

    public func resized(manual: [Int: Double], column: Int, to width: Double, minWidth: Double) -> [Int: Double] {
        manual
    }

    public func cleared(manual: [Int: Double], column: Int) -> [Int: Double] {
        manual
    }

    public func autoFit(contentWidths: [Double], minWidth: Double, maxWidth: Double) -> Double {
        minWidth
    }
}
