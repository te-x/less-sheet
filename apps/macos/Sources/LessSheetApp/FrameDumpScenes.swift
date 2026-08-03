import AppKit
import Contracts
import Foundation
import SwiftUI

// Eager, ImageRenderer-capturable scene views + synthetic fixtures for the
// headless frame dump. Split out of FrameDump.swift as pure code motion so each
// file stays within the length budget; all types keep their original internal
// access and are used only by `FrameDump` in the same target.

/// Eager (non-lazy, no ScrollView) spreadsheet grid used ONLY by the frame
/// dump so `ImageRenderer` can capture it off-screen. Renders the fixed
/// row-number gutter, the header, the currently loaded window rows (bounded),
/// and the spreadsheet fill to both edges — the same `SheetRow` the live grid
/// uses (with stickiness disabled: there is no ScrollView to counter here).
struct DumpGrid: View {
    let model: DocumentModel
    /// A top inset (title-bar height) used by the title-bar scene so the header
    /// + row 1 render BELOW the simulated title bar, mirroring the live safe-area
    /// inset (item 1). Zero for the normal grid dump.
    var topInset: CGFloat = 0
    private static let maxRows = 40

    var body: some View {
        let widths = model.visibleWidths()
        let dataWidth = widths.reduce(0, +)
        let loaded = min(model.window.rows.count, Self.maxRows)
        let firstRow = Int(model.window.firstRow)
        let gutterWidth = DocumentModel.rowNumberWidth(
            digits: DocumentModel.rowNumberDigits(forMaxNumber: firstRow + loaded)
        )
        let fillerCols = fillerColumnCount(dataWidth: dataWidth, gutterWidth: gutterWidth)
        let usedRows = loaded + 1 // + header
        let capacity = Int(ceil((frameDumpGridHeight - topInset) / GridMetrics.rowHeight))
        let fillerRows = max(0, capacity - usedRows)

        VStack(alignment: .leading, spacing: 0) {
            if topInset > 0 { Color.clear.frame(height: topInset) }
            SheetRow(rowNumber: nil, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                     cells: model.headerLabels(), widths: widths, fillerColumns: fillerCols, isHeader: true)
            ForEach(0..<loaded, id: \.self) { offset in
                SheetRow(
                    rowNumber: firstRow + offset + 1, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                    cells: model.visibleBodyCells(forRow: firstRow + offset),
                    widths: widths, fillerColumns: fillerCols, isHeader: false,
                    highlights: model.cellHighlights(forRow: firstRow + offset),
                    truncated: model.visibleBodyTruncated(forRow: firstRow + offset)
                )
            }
            ForEach(0..<fillerRows, id: \.self) { _ in
                SheetRow(rowNumber: nil, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                         cells: [], widths: widths, fillerColumns: fillerCols, isHeader: false)
            }
            Spacer(minLength: 0)
        }
        // Pinned to the dump size and clipped: fill rows overflow to the right
        // edge (last cell clipped) without widening the view, so an overlay
        // composited over this stays correctly inset from the window edge.
        .frame(width: 900, height: 600, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
        .environment(\.overlayDumpChrome, true)   // header uses its opaque fallback off-screen
    }

    private func fillerColumnCount(dataWidth: CGFloat, gutterWidth: CGFloat) -> Int {
        let available: CGFloat = 900 - gutterWidth
        guard available > dataWidth else { return 0 }
        return Int(ceil((available - dataWidth) / GridMetrics.fillerColumnWidth))
    }
}

private let frameDumpGridHeight: CGFloat = 600

/// End-anchored eager grid for the overscroll dump (req. 8): the last loaded
/// data rows, then the end-of-file overscroll strip of empty grid, so the final
/// data row lands above where the floating controls sit. Mirrors the live
/// scrolled-to-end state (header pinned at top, earlier rows scrolled off).
struct DumpEndGrid: View {
    let model: DocumentModel

    var body: some View {
        let widths = model.visibleWidths()
        let dataWidth = widths.reduce(0, +)
        let loadedRows = model.window.rows.count
        let firstRow = Int(model.window.firstRow)
        let gutterWidth = DocumentModel.rowNumberWidth(
            digits: DocumentModel.rowNumberDigits(forMaxNumber: firstRow + loadedRows)
        )
        let fillerCols = fillerColumnCount(dataWidth: dataWidth, gutterWidth: gutterWidth)
        // Rows that fit above the overscroll strip (minus the header row).
        let usable = max(0, Int(frameDumpGridHeight / GridMetrics.rowHeight) - 1 - GridMetrics.overscrollRows)
        let show = min(loadedRows, usable)
        let start = loadedRows - show

        VStack(alignment: .leading, spacing: 0) {
            SheetRow(rowNumber: nil, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                     cells: model.headerLabels(), widths: widths, fillerColumns: fillerCols, isHeader: true)
            ForEach(start..<loadedRows, id: \.self) { offset in
                SheetRow(
                    rowNumber: firstRow + offset + 1, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                    cells: model.visibleBodyCells(forRow: firstRow + offset),
                    widths: widths, fillerColumns: fillerCols, isHeader: false,
                    highlights: model.cellHighlights(forRow: firstRow + offset),
                    truncated: model.visibleBodyTruncated(forRow: firstRow + offset)
                )
            }
            ForEach(0..<GridMetrics.overscrollRows, id: \.self) { _ in
                SheetRow(rowNumber: nil, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                         cells: [], widths: widths, fillerColumns: fillerCols, isHeader: false)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 900, height: 600, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
        .environment(\.overlayDumpChrome, true)   // header uses its opaque fallback off-screen
    }

    private func fillerColumnCount(dataWidth: CGFloat, gutterWidth: CGFloat) -> Int {
        let available: CGFloat = 900 - gutterWidth
        guard available > dataWidth else { return 0 }
        return Int(ceil((available - dataWidth) / GridMetrics.fillerColumnWidth))
    }
}

/// A simulated macOS title bar for the headless title-bar dump (req. 1): traffic
/// lights at the leading edge and the document title centered, over a
/// translucent band standing in for the real chrome's top-of-window blur.
struct DumpTitleBar: View {
    let title: String
    /// Title-bar band height — matches the window's top safe area (item 1).
    static let height: CGFloat = 32

    var body: some View {
        ZStack {
            Text(title.isEmpty ? "LessSheet" : title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            HStack(spacing: 8) {
                dot(Color(red: 1.00, green: 0.37, blue: 0.34))
                dot(Color(red: 1.00, green: 0.74, blue: 0.19))
                dot(Color(red: 0.22, green: 0.79, blue: 0.30))
                Spacer()
            }
            .padding(.leading, 20)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 12, height: 12)
    }
}

/// A plain-view mirror of the Settings window for headless dumps: the same parse
/// parameters (current values) and per-column visibility state, with the last
/// visible column marked disabled. Uses only ImageRenderer-capturable views
/// (Text + SF Symbols), unlike the live native Form.
struct DumpSettings: View {
    let model: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.title3.weight(.semibold))

            Text("Parsing").font(.caption).foregroundStyle(.secondary)
            labeled("First row is header", model.dialect.hasHeader ? "On" : "Off")
            labeled("Separator", DialectGlyph.separatorName(model.dialect.separator))
            labeled("Quote character", model.dialect.quote.map(DialectGlyph.quoteName) ?? "None")
            labeled("Text encoding", DialectGlyph.encodingValueLabel(model.dialect))

            Divider().padding(.vertical, 4)

            Text("Columns").font(.caption).foregroundStyle(.secondary)
            ForEach(0..<model.columnCount, id: \.self) { column in
                let hidden = model.visibility.isHidden(column)
                let lastVisible = !hidden && !model.canHide(column)
                HStack(spacing: 8) {
                    Image(systemName: hidden ? "square" : "checkmark.square.fill")
                        .foregroundStyle(lastVisible ? Color.secondary : (hidden ? Color.secondary : Color.accentColor))
                    Text(model.columnLabel(column))
                        .foregroundStyle(lastVisible ? .secondary : .primary)
                    if lastVisible {
                        Text("last visible").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 500, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary)
        }
    }
}

/// Synthetic find sessions for the headless find dumps, keyed to the find.csv
/// fixture (header name,qty,note; data rows 0..7 — "needle" folds to rows
/// 0,1,2,3,6,7). Presentation-only fixtures: the counts state uses illustrative
/// numbers to exhibit the growing "Match n of m…" + "Scanning… %" copy.
enum FindScenes {
    private static func draft(
        mode: FindMode, text: String = "", column: Int = 0,
        comparison: SearchOperator = .equals, value: String = ""
    ) -> FindDraft {
        FindDraft(mode: mode, text: text, column: column, comparison: comparison, value: value)
    }

    private static let empty = FindDisplay(
        request: nil, current: nil, position: nil,
        total: 0, totalIsFinal: false, progress: nil, notice: nil
    )

    /// Text popup, nothing run yet.
    static let textState = FindSession(draft: draft(mode: .text, text: "needle"), display: empty)

    /// Where popup, nothing run yet (qty ≤ 2).
    static let whereState = FindSession(
        draft: draft(mode: .predicate, column: 1, comparison: .lessOrEqual, value: "2"),
        display: empty
    )

    /// Growing count while scanning ("Match 3 of 47…" + "Scanning… 34%"), strong
    /// highlight on the current match + subtle on the rest.
    static let countsState = FindSession(
        draft: draft(mode: .text, text: "needle"),
        display: FindDisplay(
            request: .text(query: "needle", scope: nil, caseSensitive: false),
            current: SearchMatch(row: 2, column: 0),
            position: 3, total: 47, totalIsFinal: false, progress: 0.34, notice: nil
        )
    )

    /// No matches anywhere.
    static let noMatchesState = FindSession(
        draft: draft(mode: .text, text: "zzz"),
        display: FindDisplay(
            request: .text(query: "zzz", scope: nil, caseSensitive: false),
            current: nil, position: nil, total: 0, totalIsFinal: true, progress: nil, notice: .noMatches
        )
    )

    /// Wrapped-to-start notice (Next past the last match).
    static let wrappedState = FindSession(
        draft: draft(mode: .text, text: "needle"),
        display: FindDisplay(
            request: .text(query: "needle", scope: nil, caseSensitive: false),
            current: SearchMatch(row: 0, column: 2),
            position: 1, total: 6, totalIsFinal: true, progress: nil, notice: .wrappedToStart
        )
    )

    /// Highlights only (popup closed): subtle on every "needle" cell, strong on
    /// the current match (row 0, col 2 — "alpha needle").
    static let highlightsState = FindSession(
        draft: draft(mode: .text, text: "needle"),
        display: FindDisplay(
            request: .text(query: "needle", scope: nil, caseSensitive: false),
            current: SearchMatch(row: 0, column: 2),
            position: 1, total: 6, totalIsFinal: true, progress: nil, notice: nil
        )
    )
}

// MARK: - Scene composition (pure SwiftUI builders)
// Moved out of FrameDump.swift as pure code motion. `internal` (not `private`)
// so `FrameDump.renderScene`'s dispatch helpers in FrameDump.swift can reach
// them; none touch FrameDump's private members (they only build views).
extension FrameDump {
    @MainActor
    static func overlayScene(
        _ model: DocumentModel, expandedPill: PillKind?, jumpFlow: JumpFlow, jumpFieldActive: Bool = false
    ) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(
            from: model, expandedPill: expandedPill,
            jumpFlow: jumpFlow, jumpFieldActive: jumpFieldActive
        )
        return ZStack(alignment: .bottomTrailing) {
            DumpGrid(model: model)
            OverlayView(model: snapshot)
        }
        .environment(\.overlayDumpChrome, true)
    }

    /// The rejected-jump state (item 4): the jump field re-armed and styled red
    /// (blink), showing the exact total in its copy so the user sees the valid
    /// range. The live blink+shake is animated; the dump captures the red field.
    @MainActor
    static func rejectScene(_ model: DocumentModel) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(
            from: model, expandedPill: nil, jumpFlow: .idle, jumpFieldActive: true
        )
        return ZStack(alignment: .bottomTrailing) {
            DumpGrid(model: model)
            OverlayView(model: snapshot)
        }
        .environment(\.overlayDumpChrome, true)
        .environment(\.overlayJumpRejected, true)
    }

    /// The revealed title-bar state (req. 1): the grid with the document title +
    /// traffic lights shown, plus the bottom-right control row. The real title
    /// bar is NSWindow chrome ImageRenderer can't capture, so it is simulated
    /// here (like the glass/Form dump mirrors) purely for verification.
    @MainActor
    static func titleBarScene(_ model: DocumentModel) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(from: model, expandedPill: nil, jumpFlow: .idle)
        // Mirror the live chrome (item 1): the grid content is inset by the
        // title-bar height, so at rest the header + row 1 sit fully BELOW the
        // title-bar region (never hidden under it); scrolled content travels
        // under the region and frosts (the native scroll-edge effect — live
        // only, can't be captured off-screen).
        return ZStack(alignment: .top) {
            DumpGrid(model: model, topInset: DumpTitleBar.height)
            DumpTitleBar(title: (model.path as NSString).lastPathComponent)
        }
        .overlay(alignment: .bottomTrailing) { OverlayView(model: snapshot) }
        .environment(\.overlayDumpChrome, true)
    }

    /// A find scene (ARCH req. 9): the grid (with the search's viewport
    /// highlights) plus the overlay's find popup in a chosen state, rendered
    /// with the opaque dump chrome. The synthetic `findSession` drives the popup
    /// copy AND the strong current-match highlight; the SUBTLE highlights come
    /// from the CORE's per-window match flags (thin-frontend-shared-core Phase 1
    /// — the frontend keeps no matcher). The dump snapshot is sessionless, so we
    /// compute those flags once on the LIVE core (same window) for the scene's
    /// request and seed them into the snapshot (`seedMatchFlags`).
    @MainActor
    static func findScene(_ model: DocumentModel, findSession: FindSession, fieldActive: Bool) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(
            from: model, expandedPill: nil, jumpFlow: .idle,
            findSession: findSession, findFieldActive: fieldActive
        )
        if let request = findSession.display.request {
            snapshot.seedMatchFlags(model.dumpMatchFlagsMask(for: request))
        }
        return ZStack(alignment: .bottomTrailing) {
            DumpGrid(model: snapshot)          // subtle highlights from the seeded core mask; strong from findSession
            OverlayView(model: snapshot)
        }
        .environment(\.overlayDumpChrome, true)
    }

    /// The scrolled-to-end state (req. 8): the last data rows anchored so the
    /// final row sits above the floating controls, with the end-of-file
    /// overscroll strip of empty grid below it — proving the last row stays
    /// legible instead of hiding under the buttons.
    @MainActor
    static func overscrollScene(_ model: DocumentModel) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(from: model, expandedPill: nil, jumpFlow: .idle)
        return ZStack(alignment: .bottomTrailing) {
            DumpEndGrid(model: model)
            OverlayView(model: snapshot)
        }
        .environment(\.overlayDumpChrome, true)
    }
}
