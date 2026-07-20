import Foundation
import Contracts

/// Emits the cold-start timing marker (ARCH-walking-skeleton functional req. 7):
/// one `lesssheet.first_rows_visible_ms=<int>` line to stderr per document open
/// that reaches a data-bearing table. Error and empty states emit nothing.
///
/// `begin()` is called as the very first statement of `main.swift` — the closest
/// approximation to process start available to app code.
enum LaunchTiming {
    private nonisolated(unsafe) static var startNanos: UInt64 = DispatchTime.now().uptimeNanoseconds

    static func begin() {
        startNanos = DispatchTime.now().uptimeNanoseconds
    }

    /// Emits the marker for the first frame that shows document data.
    static func markFirstRowsVisible() {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startNanos
        let milliseconds = Int(elapsed / 1_000_000)
        FileHandle.standardError.write(Data((TimingMarker.line(milliseconds: milliseconds) + "\n").utf8))
    }
}
