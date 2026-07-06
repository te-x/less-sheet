/// Generic spreadsheet column names for documents/state without an effective
/// header: "A"…"Z", "AA", "AB", … — 0-based bijective base-26 over A–Z.
/// (Carried over from the walking-skeleton contract, where it was pinned via
/// the display deriver; the Configure window's checkbox labels and the grid's
/// header row both use it when `DocumentSession.headerCells` is nil, or when
/// a header cell is present but empty.)
///
/// Like `TimingMarker`, this is contract-level policy small enough to live
/// here directly (single source of truth; pinned by frozen tests).
public enum GenericColumnName {
    /// The name of the 0-based column `index`: 0 -> "A", 25 -> "Z",
    /// 26 -> "AA", 27 -> "AB", 701 -> "ZZ", 702 -> "AAA", …
    public static func name(at index: Int) -> String {
        precondition(index >= 0, "column index must be non-negative")
        var n = index
        var scalars: [Unicode.Scalar] = []
        while true {
            let r = n % 26
            scalars.append(Unicode.Scalar(UInt8(65 + r)))
            n = n / 26 - 1
            if n < 0 { break }
        }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }

    /// The first `count` names, in order.
    public static func names(count: Int) -> [String] {
        (0..<max(count, 0)).map(name(at:))
    }
}
