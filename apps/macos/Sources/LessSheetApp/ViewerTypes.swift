import CoreGraphics
import Foundation

// MARK: - Layout constants (grid geometry; shared by on-screen + dump paths)

enum GridMetrics {
    static let rowHeight: CGFloat = 22
    static let minColumnWidth: CGFloat = 72
    static let maxColumnWidth: CGFloat = 360
    static let fillerColumnWidth: CGFloat = 120
    static let cellHPadding: CGFloat = 10
    /// Scroll buffer kept each direction, well under the ABI's window cap so a
    /// request never over-asks.
    static let scrollBufferRows = 600
    /// Gutter padding, and a floor on the digit count so it never looks cramped.
    static let rowNumberHPadding: CGFloat = 8
    static let rowNumberMinDigits = 2
    /// Room for the oversized-row marker, reserved UNCONDITIONALLY — whether or
    /// not any visible row is oversized — so the gutter's width cannot change as
    /// such rows scroll in and out.
    static let oversizedMarkerReserve: CGFloat = 14
    /// The horizontal analog of `scrollBufferRows` for what gets MEASURED and
    /// DRAWN: a small scroll settles inside already-accurate columns.
    static let columnOverscan = 8
    /// The same for what gets FETCHED. Larger than `columnOverscan`, so a scroll
    /// that outgrows the drawn overscan by a few columns still lands inside cells
    /// already fetched rather than needing another core round-trip.
    static let columnFetchBuffer = 32
    /// Columns fetched for a session's very FIRST materialize, before the grid's
    /// first geometry callback establishes a real column window. Every column
    /// carries at least `minColumnWidth`, so a document with this many columns is
    /// already wider than any real viewport — the bound can therefore never
    /// shortchange a file that actually fits one, while keeping an extremely wide
    /// document's cold open O(hundreds) of columns rather than O(columnCount).
    static let initialColumnFetchCount = 256
    /// Filler rows kept below the last data row, so the bottom-right floating
    /// controls never cover the final rows: five of them clear the control
    /// cluster with margin. Pure fill, never counted as data.
    static let overscrollRows = 5
    /// The transparent title-bar region's height. The grid extends UNDER it, so
    /// content scrolls beneath and frosts, but insets its scrollable content by
    /// this much so row 1 rests fully below it at rest.
    static let titleBarInset: CGFloat = 32
}
