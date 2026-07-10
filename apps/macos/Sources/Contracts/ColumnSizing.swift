/// The column WIDTH model for manual resize + auto-fit (ARCH-select-copy AC5),
/// layered ON TOP of the monotone auto-grow already owned by `ColumnLayouting`
/// (ARCH-column-windowing). Same purity as the rest of Contracts: plain `Double`
/// point values, no AppKit — the font-dependent pixel MEASUREMENT of a cell stays
/// in the frontend; THIS owns the deterministic width ALGEBRA (how a manual
/// override, the auto baseline, and an auto-fit combine).
///
/// TWO WIDTH SOURCES, one rule (ARCH "Columns = resize + auto-fit"):
/// - the AUTO baseline — the per-column widths grown monotonically as longer
///   content scrolls into view (`ColumnLayouting.grown`); the frontend's
///   `columnWidths` array, indexed by ABSOLUTE column.
/// - a MANUAL override — an explicit width the user dragged, keyed by ABSOLUTE
///   column (a session map). A manual width OVERRIDES the auto baseline at draw
///   (`effectiveWidths`) — larger OR smaller — and auto-grow never changes it.
///
/// INDEX SPACE. `auto` is indexed by absolute column (like `ViewerModel.
/// columnWidths`, "per ORIGINAL column index"); `manual` keys are absolute column
/// indices (ARCH: "keyed by absolute column index"). The frontend maps between a
/// visible/window position and an absolute column itself (it already does, for
/// `ColumnLayouting.window`), then routes width RESOLUTION through this contract.
public protocol ColumnSizing: Sendable {
    /// The widths the grid actually draws: for each absolute column `c`, the
    /// MANUAL override `manual[c]` if present, else the AUTO baseline `auto[c]`.
    /// This one function is the whole "manual overrides auto-grow" guarantee — a
    /// manual width wins REGARDLESS of how far auto-grow raised `auto[c]` (AC5).
    /// Result has the same shape/indexing as `auto`; `manual` keys outside
    /// `auto.indices` are ignored.
    func effectiveWidths(auto: [Double], manual: [Int: Double]) -> [Double]

    /// Drag-resize (AC5): the manual map with absolute `column` set to `width`,
    /// clamped UP to `minWidth` (a drag can never make a column thinner than the
    /// floor). No upper clamp — an explicit drag is honored. The override then
    /// STICKS: auto-grow leaves it alone (`effectiveWidths` keeps returning it)
    /// until it is cleared.
    func resized(manual: [Int: Double], column: Int, to width: Double, minWidth: Double) -> [Int: Double]

    /// Clear the manual override for absolute `column` (double-click, or a reset):
    /// the map without that key, so the column REVERTS to auto-grow — the next
    /// `effectiveWidths` returns its `auto` baseline and `ColumnLayouting.grown`
    /// governs it again (AC5). A no-op when `column` had no override.
    func cleared(manual: [Int: Double], column: Int) -> [Int: Double]

    /// Double-click AUTO-FIT (AC5): the EXACT fit for a column from its VISIBLE
    /// window's measured content — `max(contentWidths)`, clamped to
    /// `[minWidth, maxWidth]`; `minWidth` when `contentWidths` is empty. UNLIKE
    /// monotone auto-grow this may be SMALLER than the current width (a shrink to
    /// fit). The frontend measures only the visible rows (O(visible), never
    /// O(rows)); it includes the header cell's width in `contentWidths` if the
    /// header should count, and pre-adds cell padding. Auto-fit is applied by the
    /// frontend as: clear the manual override (`cleared`) AND reset the column's
    /// `auto` baseline to this value — so the column is back in auto mode at the
    /// fitted width and can grow again as new content appears.
    func autoFit(contentWidths: [Double], minWidth: Double, maxWidth: Double) -> Double
}
