/// The cold-start timing marker (ARCH-walking-skeleton functional req. 7).
///
/// REQUIREMENT (applies to debug AND release builds): the app emits exactly
/// one marker line per document open that reaches the table —
/// `lesssheet.first_rows_visible_ms=<int>` — where `<int>` is the integer
/// millisecond count measured from PROCESS START to the first frame that
/// shows document data. Emit it to stderr (or as an os_signpost carrying the
/// same string). This is the hook the reviewer and slice 2's budget
/// enforcement (< 500 ms) measure against; error and empty states emit
/// nothing.
public enum TimingMarker {
    /// The exact marker prefix; the emitted line is `prefix + String(ms)`.
    public static let firstRowsVisiblePrefix = "lesssheet.first_rows_visible_ms="

    /// Formats the marker line for a measured duration.
    public static func line(milliseconds: Int) -> String {
        firstRowsVisiblePrefix + String(milliseconds)
    }
}
