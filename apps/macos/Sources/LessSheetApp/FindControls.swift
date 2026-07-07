import AppKit
import Contracts
import Foundation
import SwiftUI

// The Find control (ARCH-find-seek app reqs. 6–10): the LEFTMOST glass button in
// the floating control row, opening an upward popup with a Text | Where switch,
// incremental "match n of m" counts + scan progress, wrap notices, and a
// cancel affordance — the same glass/reveal/popup language as Jump and the
// dialect pills. Grid highlighting lives in SheetRow (driven by the model's
// CellMatcher); the shortcuts (⌘F / ⌘G / ⇧⌘G) are wired in AppUI.

extension EnvironmentValues {
    /// Forces the find value field's rejected (red) styling in a headless dump.
    @Entry var overlayFindRejected: Bool = false
}

/// Find (req. 6): a glass magnifying-glass button that opens an upward popup.
/// ⌘F reveals + focuses it; Esc closes it and clears highlights (the typed
/// query is retained for the session). While a scan runs the popup shows
/// progress + a cancel affordance; the main window stays fully interactive.
struct FindControlView: View {
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome
    @Environment(\.overlayFindRejected) private var dumpRejected
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: FindField?
    @State private var shake: CGFloat = 0
    @State private var rejectedFlash = false

    private enum FindField { case query, value }

    private var display: FindDisplay { model.findSession.display }
    private var searching: Bool { display.progress != nil }
    private var hasActiveSearch: Bool { display.request != nil }
    private var popupVisible: Bool { model.findFieldActive }
    /// The value field shows its rejected (red) styling on a live blink or when
    /// a headless dump forces it.
    private var rejected: Bool { rejectedFlash || dumpRejected }

    var body: some View {
        Button {
            model.openFindField()
            model.revealOverlay()
            DispatchQueue.main.async { focus = focusTarget }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: OverlayMetrics.controlSize, height: OverlayMetrics.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassChrome(hasActiveSearch ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Circle())
        .overlay { if hasActiveSearch { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
        .overlay(alignment: .top) {
            if popupVisible {
                popup
                    .fixedSize()
                    .offset(y: -(popupHeight + OverlayMetrics.popupGap))
            }
        }
        .help("Find")
        .accessibilityLabel("Find")
        .onChange(of: model.findFocusRequests) { _, _ in
            // ⌘F: open + focus (keyboard reveal path).
            model.openFindField()
            DispatchQueue.main.async { focus = focusTarget }
        }
        .onChange(of: model.findRejections) { _, _ in reject() }
        .onChange(of: display.progress != nil) { _, isScanning in
            if isScanning { FindProbe.noteScanningShown() }
        }
    }

    private var focusTarget: FindField {
        model.findSession.draft.mode == .text ? .query : .value
    }

    /// Overestimated popup height so the upward float always clears the button
    /// (an overestimate only widens the gap; it never overlaps).
    private var popupHeight: CGFloat {
        let base: CGFloat = model.findSession.draft.mode == .text ? 116 : 156
        return base + (searching ? 34 : 0)
    }

    // MARK: - Popup

    @ViewBuilder
    private var popup: some View {
        VStack(alignment: .leading, spacing: 8) {
            FindModeSwitch(mode: $model.findSession.draft.mode)
                .onChange(of: model.findSession.draft.mode) { _, _ in
                    DispatchQueue.main.async { focus = focusTarget }
                }

            switch model.findSession.draft.mode {
            case .text: textFields
            case .predicate: whereFields
            }

            statusRow
            if let progress = display.progress { scanningRow(progress) }
        }
        .padding(14)
        .frame(width: 260)
        .glassChrome(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onExitCommand { model.closeFind() }              // Esc closes + clears
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find")
    }

    // Text mode: one query field with smart case (ARCH req. 7).
    private var textFields: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            if dumpChrome {
                Text(model.findSession.draft.text.isEmpty ? "Find" : model.findSession.draft.text)
                    .foregroundStyle(model.findSession.draft.text.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Find", text: $model.findSession.draft.text)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .query)
                    .onSubmit { model.submitFind() }
            }
        }
        .font(.callout)
        .accessibilityLabel("Find text")
    }

    // Where mode: a column picker (all columns; hidden ones marked), an
    // operator picker (= ≠ < > ≤ ≥), and a value field (ARCH req. 7).
    private var whereFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnPicker
            HStack(spacing: 8) {
                operatorPicker
                valueField
            }
        }
    }

    @ViewBuilder
    private var columnPicker: some View {
        let column = model.findSession.draft.column
        if dumpChrome {
            HStack(spacing: 4) {
                Text("Column").foregroundStyle(.secondary)
                Text(columnLabel(column)).foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker("Column", selection: $model.findSession.draft.column) {
                ForEach(0..<max(model.columnCount, 1), id: \.self) { col in
                    Text(columnLabel(col)).tag(col)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Column")
            .accessibilityValue(columnLabel(column))
        }
    }

    @ViewBuilder
    private var operatorPicker: some View {
        let op = model.findSession.draft.op
        if dumpChrome {
            Text(op.glyph)
                .font(.callout.weight(.semibold).monospaced())
                .frame(width: 34, height: 24)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)) }
        } else {
            Picker("Operator", selection: $model.findSession.draft.op) {
                ForEach(SearchOperator.allCases, id: \.self) { op in
                    Text(op.glyph).tag(op)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Operator")
            .accessibilityValue(op.accessibilityName)
        }
    }

    private var valueField: some View {
        Group {
            if dumpChrome {
                Text(model.findSession.draft.value.isEmpty ? "Value" : model.findSession.draft.value)
                    .foregroundStyle(valueColor(empty: model.findSession.draft.value.isEmpty))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Value", text: $model.findSession.draft.value)
                    .textFieldStyle(.plain)
                    .foregroundStyle(rejected ? Color.red : Color.primary)
                    .focused($focus, equals: .value)
                    .onSubmit { model.submitFind() }
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(rejected ? Color.red : .secondary.opacity(0.4), lineWidth: rejected ? 2 : 1) }
        .modifier(Shake(animatableData: shake))
        .accessibilityLabel("Value")
        .accessibilityValue(rejected ? "Enter a number for this comparison." : "")
    }

    private func valueColor(empty: Bool) -> Color {
        if rejected { return .red }
        return empty ? .secondary : .primary
    }

    // The count / notice line + previous/next navigation (ARCH reqs. 8, 10).
    private var statusRow: some View {
        HStack(spacing: 8) {
            Text(FindCopy.status(display))
                .font(.caption)
                .foregroundStyle(display.notice == .noMatches ? Color.secondary : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button { model.stepFind(.backward) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(!hasActiveSearch)
                .help("Previous match")
                .accessibilityLabel("Previous match")
            Button { model.stepFind(.forward) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(!hasActiveSearch)
                .help("Next match")
                .accessibilityLabel("Next match")
        }
        .font(.caption)
    }

    // While scanning: progress bar + "Scanning… 34%" + cancel (ARCH reqs. 8, 10;
    // no silent stalls, sentence-case copy).
    private func scanningRow(_ progress: Double) -> some View {
        let fraction = max(0, min(1, progress))
        return HStack(spacing: 8) {
            if dumpChrome {
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(width: 64, height: 6)
                    Capsule().fill(Color.accentColor).frame(width: 64 * fraction, height: 6)
                }
            } else {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 64)
            }
            Text("Scanning… \(Int(fraction * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Cancel", role: .cancel) { model.cancelFind() }
                .buttonStyle(.plain)
                .font(.caption)
        }
        .accessibilityLabel("Scanning, \(Int(fraction * 100)) percent. Press Cancel to stop.")
    }

    private func columnLabel(_ column: Int) -> String {
        guard (0..<model.columnCount).contains(column) else { return "" }
        let base = model.columnLabel(column)
        return model.visibility.isHidden(column) ? "\(base) (hidden)" : base
    }

    /// A rejected submit (ordering predicate, non-numeric value): keep the field
    /// open with its text selected, blink it red, and — unless Reduce Motion —
    /// shake it (reuses the jump rejection components).
    private func reject() {
        model.openFindField()
        focus = .value
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
        }
        rejectedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.5)) { rejectedFlash = false }
        }
        if !reduceMotion {
            shake = 0
            withAnimation(.linear(duration: 0.4)) { shake = 1 }
        }
    }
}

/// The Text | Where segmented switch (ARCH req. 7). Custom-drawn (not a native
/// segmented Picker) so it renders in headless ImageRenderer dumps. Sentence-
/// case user vocabulary; "Where" renders `FindMode.predicate`.
struct FindModeSwitch: View {
    @Binding var mode: FindMode

    var body: some View {
        HStack(spacing: 0) {
            segment("Text", .text)
            segment("Where", .predicate)
        }
        .padding(2)
        .background(Capsule().fill(.quaternary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find mode")
    }

    private func segment(_ title: String, _ value: FindMode) -> some View {
        let selected = mode == value
        return Button { mode = value } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background { if selected { Capsule().fill(Color.accentColor) } }
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Find popup copy — sentence case, user vocabulary, identical terms everywhere
/// (ARCH req. 10): "Match 3 of 47", the growing "Match 3 of 47…", "No matches",
/// "Wrapped to start" / "Wrapped to end", "Stopped", "Scanning… 34%".
enum FindCopy {
    static func status(_ display: FindDisplay) -> String {
        if let notice = display.notice {
            switch notice {
            case .wrappedToStart: return "Wrapped to start"
            case .wrappedToEnd: return "Wrapped to end"
            case .noMatches: return "No matches"
            case .stopped: return "Stopped"
            }
        }
        if let position = display.position {
            let base = "Match \(position) of \(display.total)"
            return display.totalIsFinal ? base : base + "…"
        }
        if display.total > 0 {
            let base = "\(display.total) match\(display.total == 1 ? "" : "es")"
            return display.totalIsFinal ? base : base + "…"
        }
        return ""
    }
}

extension SearchOperator {
    /// The picker glyph (= ≠ < > ≤ ≥).
    var glyph: String {
        switch self {
        case .equals: "="
        case .notEquals: "≠"
        case .lessThan: "<"
        case .greaterThan: ">"
        case .lessOrEqual: "≤"
        case .greaterOrEqual: "≥"
        }
    }

    /// VoiceOver name for the operator.
    var accessibilityName: String {
        switch self {
        case .equals: "Equals"
        case .notEquals: "Not equal to"
        case .lessThan: "Less than"
        case .greaterThan: "Greater than"
        case .lessOrEqual: "Less than or equal to"
        case .greaterOrEqual: "Greater than or equal to"
        }
    }
}

// MARK: - Verification hook (LESSSHEET_FIND)

// Verification-only instrumentation for the find path — INERT unless the env var
// is set, so it costs nothing in normal use and never touches the < 500 ms
// cold-start measurement (it starts only after the first data-bearing frame).
//
//   LESSSHEET_FIND=<query>   Drive the REAL UI find path (identical to typing
//     <query> in the Text field + Enter) once, right after first paint. Logs
//     submit / scanning-shown / progress / the terminal state — the first
//     landing (match n of m) and the final count, or "no matches", or a
//     rejection. A 250 ms MAIN-ACTOR heartbeat logs its inter-tick gap every
//     tick (any gap > 500 ms = the main thread stalled) — the no-stall proof
//     for a full-file search on the big fixture. The terminal state is dumped
//     and, under LESSSHEET_DUMP_EXIT, the headless instance quits.
@MainActor
enum FindProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let query: String? = {
        guard let raw = env["LESSSHEET_FIND"], !raw.isEmpty else { return nil }
        return raw
    }()

    /// True when the hook is armed.
    static var active: Bool { query != nil }

    /// Opt-in: after the initial search resolves, trigger a wrap (Previous
    /// before the first match) and trace the notice's visible lifetime, proving
    /// the wrap notice is held for the readable latch before it clears.
    static let wrapMode: Bool = env["LESSSHEET_FIND_WRAP"] != nil

    private static var model: DocumentModel?
    private static var t0 = DispatchTime.now()
    private static var lastTick = DispatchTime.now()
    private static var heartbeat: Task<Void, Never>?
    private static var scanningLogged = false
    private static var landedLogged = false
    private static var finalLogged = false
    private static var lastPct = -1
    private static var maxGapMs = 0
    private static var finished = false
    private static var lastNotice = "none"
    private static var wrapTriggered = false
    private static var wrapNoticeSeen = false

    private static func noticeName(_ notice: FindNotice?) -> String {
        switch notice {
        case .wrappedToStart: "wrappedToStart"
        case .wrappedToEnd: "wrappedToEnd"
        case .noMatches: "noMatches"
        case .stopped: "stopped"
        case nil: "none"
        }
    }

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000)
    }

    /// Called from the first data-bearing frame's task: start the heartbeat and
    /// submit the query through the real popup path.
    static func run(model: DocumentModel) {
        guard active, let query else { return }
        self.model = model
        t0 = DispatchTime.now()
        lastTick = t0
        maxGapMs = 0
        finished = false
        scanningLogged = false
        landedLogged = false
        finalLogged = false
        lastPct = -1
        startHeartbeat()
        log("lesssheet.find.submit query=\(query) at_ms=\(elapsedMs())"
            + " known_total=\(model.rowCountInfo.count) exact=\(model.rowCountInfo.isExact)")
        model.submitFindQuery(query)     // identical to typing <query> + Enter
        checkTerminal()
    }

    private static func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                let now = DispatchTime.now()
                let gap = Int((now.uptimeNanoseconds &- lastTick.uptimeNanoseconds) / 1_000_000)
                lastTick = now
                maxGapMs = max(maxGapMs, gap)
                // Include the current notice each tick so a wrap latch shows as a
                // run of identical-notice ticks before it clears.
                let notice = model.map { noticeName($0.findSession.display.notice) } ?? "none"
                log("lesssheet.heartbeat.gap_ms=\(gap) notice=\(notice) at_ms=\(elapsedMs())\(gap > 500 ? " STALL" : "")")
                if elapsedMs() > 90_000 {     // never leave a headless run hanging
                    log("lesssheet.find.timeout_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
                    finish(); return
                }
            }
        }
    }

    /// The scanning progress state reached the view layer (main-actor render proof).
    static func noteScanningShown() {
        guard active, !scanningLogged else { return }
        scanningLogged = true
        log("lesssheet.find.scanning_shown_ms=\(elapsedMs())")
    }

    /// Fold hook: called from the model after each search poll fold.
    static func note(model: DocumentModel) {
        guard active, !finished else { return }
        let display = model.findSession.display
        // Notice transitions (with timestamps) trace the wrap latch's lifetime.
        let noticeNow = noticeName(display.notice)
        if noticeNow != lastNotice {
            lastNotice = noticeNow
            log("lesssheet.find.notice=\(noticeNow) at_ms=\(elapsedMs())")
        }
        if let progress = display.progress {
            let pct = Int((max(0, min(1, progress)) * 100).rounded())
            if pct != lastPct {
                lastPct = pct
                log("lesssheet.find.progress=\(pct) at_ms=\(elapsedMs())")
            }
        }
        if let current = display.current, !landedLogged {
            landedLogged = true
            log("lesssheet.find.landed pos=\(display.position ?? 0) total=\(display.total)"
                + " row_0based=\(current.row) col=\(current.column) at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
        }
        if display.totalIsFinal, !finalLogged {
            finalLogged = true
            log("lesssheet.find.count_final total=\(display.total) at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
        }
        checkTerminal()
    }

    /// The submit was rejected (ordering predicate, non-numeric value) or the
    /// core refused the start (seed core) — a terminal state.
    static func rejected(model: DocumentModel) {
        guard active, !finished else { return }
        log("lesssheet.find.rejected at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
        finish()
    }

    private static func checkTerminal() {
        guard active, !finished, let model else { return }
        let display = model.findSession.display
        let landed = display.current != nil
        let noMatches = display.notice == .noMatches

        if wrapMode {
            // Phase 1: once the initial search is final and landed, trigger a
            // wrap — Previous before the first match exhausts core-side and the
            // view-model turns it into "Wrapped to end".
            if display.totalIsFinal, landed, !wrapTriggered {
                wrapTriggered = true
                log("lesssheet.find.wrap_trigger dir=backward at_ms=\(elapsedMs())")
                model.stepFind(.backward)
                return
            }
            // Phase 2: the wrap notice must appear, hold for the latch, then
            // clear when the wrap lands — terminal once it has cleared.
            if wrapTriggered {
                if display.notice != nil { wrapNoticeSeen = true }
                if wrapNoticeSeen, display.notice == nil, display.current != nil {
                    log("lesssheet.find.wrap_landed pos=\(display.position ?? 0)"
                        + " row_0based=\(display.current?.row ?? 0) at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
                    finish()
                }
            }
            return
        }

        // Terminal once the scan is final and the first landing resolved (or the
        // whole file holds no match).
        if display.totalIsFinal, landed || noMatches {
            log("lesssheet.find.terminal total=\(display.total) final=\(display.totalIsFinal)"
                + " landed=\(landed) no_matches=\(noMatches) at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
            finish()
        }
    }

    private static func finish() {
        guard !finished else { return }
        finished = true
        heartbeat?.cancel()
        heartbeat = nil
        if let model { FrameDump.dumpFindResult(for: model) }
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
