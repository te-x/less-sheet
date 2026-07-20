import CoreGraphics
import Foundation

// MARK: - Layout constants (grid geometry; shared by on-screen + dump paths)

enum GridMetrics {
    static let rowHeight: CGFloat = 22
    static let minColumnWidth: CGFloat = 72
    static let maxColumnWidth: CGFloat = 360
    static let fillerColumnWidth: CGFloat = 120
    static let cellHPadding: CGFloat = 10
    /// Rows kept behind the scan frontier as scroll buffer each direction
    /// (well under LS_WINDOW_MAX_ROWS so a window request never over-asks).
    static let scrollBufferRows = 600
    /// Row-number gutter: inner horizontal padding, and a floor on the digit
    /// count so the gutter never looks cramped. The gutter is fixed against
    /// horizontal scroll and sized to the largest VISIBLE 1-based number.
    static let rowNumberHPadding: CGFloat = 8
    static let rowNumberMinDigits = 2
    /// Extra gutter width reserved, UNCONDITIONALLY, for the oversized-row
    /// marker (ARCH-huge-row-budget req. 7) drawn before the row number.
    /// Reserved regardless of whether any currently-visible row is oversized
    /// so the gutter's width never changes as oversized rows scroll in/out —
    /// a scroll-triggered geometry change is exactly the class of bug the
    /// column-width-growth fixes upstream had to correct.
    static let oversizedMarkerReserve: CGFloat = 14
    /// Extra columns kept measured/materialized on EACH side of the horizontal
    /// column window (ARCH-column-windowing) — the horizontal analog of
    /// `scrollBufferRows`: a small scroll settles inside already-accurate
    /// columns instead of immediately needing a fresh window + refine.
    static let columnOverscan = 8
    /// Extra columns FETCHED on each side of the current column window
    /// whenever `materialize` (re-)issues `setWindow(columns:)` (ARCH-column-
    /// windowing round-2, AC7) — the fetch analog of `scrollBufferRows`, sized
    /// larger than `columnOverscan` (which only pads what gets MEASURED/DRAWN)
    /// so a scroll that outgrows the drawn overscan by a handful of columns
    /// still lands inside cells already fetched instead of needing another
    /// core round-trip on the very next tick.
    static let columnFetchBuffer = 32
    /// Columns fetched for the very FIRST materialize of a session, before the
    /// grid's first geometry callback establishes a real horizontal column
    /// window (the column analog of `lastVisibleCount = 40` for rows). Every
    /// column carries at least `minColumnWidth` (72 pt), so any document with
    /// this many columns or fewer is already wider than any real viewport —
    /// i.e. it can never be a viewport-FITTING file — so this bound never
    /// shortchanges `measureColumnWidths`'s sample for a file AC4 actually
    /// applies to, while still keeping an extremely wide document's cold-open
    /// fetch O(hundreds) of columns, never O(columnCount) (the round-2 fix
    /// that carries wide_100k_cols under the AC5 budget).
    static let initialColumnFetchCount = 256
    /// End-of-file overscroll: rows of empty filler grid kept BELOW the last
    /// data row so the user can scroll a little past it and the bottom-right
    /// floating controls never cover the final rows. 5 rows (110 pt) clears the
    /// control cluster (36 pt button + 24 pt inset ≈ 60 pt) with margin. Pure
    /// fill — never counted as data (row count / scrollbar estimate ignore it).
    static let overscrollRows = 5
    /// Height of the transparent title-bar region (the window's top safe area on
    /// this chromeless titled window). The grid extends UNDER it (so content
    /// scrolls beneath and frosts) but insets its scrollable content by this much
    /// so row 1 rests fully below it at (0,0). Matches the measured safe-area top.
    static let titleBarInset: CGFloat = 32
}
