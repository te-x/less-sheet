/// The horizontal COLUMN WINDOW — the column analog of `RowWindow`
/// (DocumentSession.swift) — plus the pure width algebra behind it
/// (ARCH-column-windowing). The frontend already windows ROWS so cold-open and
/// scroll are O(viewport-rows); this is the missing horizontal half, so they are
/// also O(viewport-COLUMNS) and never O(total columns).
///
/// LAYERING (why this is pure, no AppKit). The font-dependent pixel measurement
/// of a single cell stays in the frontend — the data font is monospaced, so a
/// column's content width is cheap char-metric arithmetic over the head sample,
/// and exotic-glyph columns get an `NSString.size` correction only while visible.
/// THIS contract owns only what must be deterministic and unit-pinnable with no
/// GUI: the GEOMETRY (which columns a paint must touch, and where they sit) and
/// the width ALGEBRA (how an established width is allowed to grow). Widths are
/// plain `Double` point values (whatever the frontend measured), so nothing here
/// imports AppKit — matching the rest of `Contracts` / `LessSheetKit`.

/// One materialized column window: the contiguous run of columns a single paint
/// (cold-open or scroll tick) must fetch cells for, measure exotic glyphs for,
/// and draw. Mirrors `RowWindow`'s role for rows.
public struct ColumnWindow: Equatable, Sendable {
    /// First in-window column, 0-based inclusive. 0 when `count == 0`.
    public let first: Int
    /// Number of columns in the window; 0 when the layout has no columns or the
    /// viewport intersects none. Always `first + count <= widths.count`.
    public let count: Int
    /// The x-offset of column `first` — exactly Σ widths[0..<first]. The left edge
    /// at which the frontend starts drawing the window, so every in-window column
    /// lands at the SAME x as a naive full prefix-sum draw (no positional drift;
    /// ARCH AC4/AC5). 0 when `count == 0`.
    public let firstX: Double

    public init(first: Int, count: Int, firstX: Double) {
        self.first = first
        self.count = count
        self.firstX = firstX
    }

    /// Half-open column-index range `first ..< first + count`.
    public var range: Range<Int> { first ..< (first + count) }
    /// One past the last in-window column (`first + count`).
    public var upperBound: Int { first + count }
    /// Whether the window holds no columns.
    public var isEmpty: Bool { count == 0 }
}

/// Pure column geometry + width algebra for the frontend's horizontal column
/// window. Implemented in `LessSheetKit` and pinned by a frozen conformance test
/// (`let _: any ColumnLayouting = ColumnLayout()`), exactly like the other
/// view-model logic contracts (`ColumnVisibilityManaging`, `JumpControlling`, …).
///
/// Pinned semantics:
///
/// - `window(widths:viewportX:viewportWidth:overscan:)` — the columns whose
///   x-extent intersects `[viewportX, viewportX + viewportWidth)`, PLUS `overscan`
///   extra columns on EACH side, clamped to `0 ..< widths.count`. It MUST cover
///   the viewport: every column overlapping the range is in the window, so a
///   paint never misses a visible cell. Found by prefix-sum + binary search:
///   O(log widths.count) time, and a `count` bounded by
///   `⌈viewportWidth / (smallest column width)⌉ + 2·overscan + 1` — INDEPENDENT
///   of `widths.count` (the O(viewport)-not-O(total) guarantee, ARCH AC2/AC3).
///   `firstX` is the exact prefix-sum x-offset of `first`. A viewport that spans
///   every column (they all fit on screen — the common case) yields the whole
///   range `0 ..< widths.count` at `firstX == 0`: layout identical to a
///   non-windowed draw (ARCH AC4, no regression). `overscan` is clamped at 0;
///   an empty `widths` (or a viewport intersecting no column) yields an empty
///   window at `firstX == 0`. Negative or non-finite widths are not expected;
///   a negative width contributes 0 to the running offset.
///
/// - `grown(_:mergingCandidates:)` — the monotone, per-column width growth that
///   realizes the DECIDED width behaviour (ARCH "Column-width behaviour" / AC5b).
///   Returns `current` with column `c` raised to `max(current[c], candidates[c])`
///   for each `c` in `candidates`, and EVERY other column returned UNCHANGED. It
///   NEVER lowers a width (monotone) and NEVER lets one column's candidate affect
///   another column (independence — an established column's width is a function
///   of its OWN content alone). Because a horizontal scroll only ever re-measures
///   a column's own content over the SAME vertical row window, that column's
///   candidate equals its already-established width, so merging leaves it
///   identical — horizontal scroll can never churn an established width; scroll a
///   column out of view and back and it is exactly as you left it. A width grows
///   ONLY when the vertical row window reveals longer content in that column (a
///   larger candidate). Candidate keys outside `0 ..< current.count` are ignored.
public protocol ColumnLayouting: Sendable {
    func window(widths: [Double], viewportX: Double, viewportWidth: Double, overscan: Int) -> ColumnWindow
    func grown(_ current: [Double], mergingCandidates candidates: [Int: Double]) -> [Double]
}
