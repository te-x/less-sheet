import Foundation
import Contracts

/// The cold-start timing marker: one `lesssheet.first_rows_visible_ms=<int>`
/// line to stderr per document open that reaches a data-bearing table. Error and
/// empty states emit nothing.
///
/// `begin()` is the very first statement of `main.swift`, the closest
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

    // MARK: - Launch phase breakdown

    /// Phase stamps between process start and the first data-bearing frame, inert
    /// unless `LESSSHEET_LAUNCH_PHASES` is set, so the shipped launch path is
    /// unchanged and the marker above stays comparable.
    ///
    /// The marker is a single number, and a single number can only be argued
    /// about, not optimized. Measuring from outside the process showed the
    /// invisible pre-`main` prefix is only ~17 ms of a ~188 ms wait, so nearly all
    /// of it happens in code we own and none of it was attributed.
    ///
    /// Each stamp prints `lesssheet.phase.<name>=<ms since process start>`, so
    /// consecutive deltas are the phase costs.
    private static let phasesOn =
        ProcessInfo.processInfo.environment["LESSSHEET_LAUNCH_PHASES"] != nil

    static func phase(_ name: String) {
        guard phasesOn else { return }
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000)
        FileHandle.standardError.write(Data("lesssheet.phase.\(name)=\(elapsedMs)\n".utf8))
    }

    /// Main-actor isolated because its one caller is AppKit's draw path — a real
    /// isolation guarantee, so no lock is needed.
    @MainActor private static var stampedOnce: Set<String> = []

    /// A one-shot stamp for a name that sits in a PER-FRAME path: the first call
    /// emits, every later one is a set lookup. In the shipped launch path this
    /// costs one Bool read per row draw.
    ///
    /// It exists for `first_row_pixels`, stamped on the first real data row to
    /// paint — the ground truth for "the rows are on screen", and the number
    /// launch work is measured against. `first_rows_visible_ms` approximates the
    /// same moment about 15 ms EARLIER: it marks where SwiftUI schedules the
    /// document task, before AppKit has drawn a single row. That marker is pinned
    /// by the frozen cold-open tests and deliberately left as it is.
    @MainActor
    static func phaseOnce(_ name: String) {
        guard phasesOn, stampedOnce.insert(name).inserted else { return }
        phase(name)
    }
}
