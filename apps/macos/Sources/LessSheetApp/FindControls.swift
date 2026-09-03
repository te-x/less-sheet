import AppKit
import Contracts
import Foundation
import SwiftUI

// The Find control: the leftmost button in the floating row, opening a popup
// with a Text | Where switch, incremental counts, scan progress, wrap notices
// and a cancel affordance. The per-cell highlighting is the core's verdict, and
// the shortcuts are wired in AppUI.

extension EnvironmentValues {
    /// Forces the value field's rejected styling in a headless dump.
    @Entry var overlayFindRejected: Bool = false
}

/// ⌘F opens and focuses the popup; Esc closes it and clears the highlights,
/// keeping the typed query. While a scan runs the popup shows progress and a
/// cancel affordance, and the main window stays fully interactive.
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
    /// Red on a live blink, or when a dump forces it.
    private var rejected: Bool { rejectedFlash || dumpRejected }

    var body: some View {
        Button {
            model.openFindField()
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
        .help("Find text or a value in a column")
        .accessibilityLabel("Find")
        .onChange(of: model.findFocusRequests) { _, _ in
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

    /// Deliberately an overestimate, which only widens the gap above the button
    /// and can never overlap it.
    private var popupHeight: CGFloat {
        let base: CGFloat = model.findSession.draft.mode == .text ? 116 : 156
        return base + (searching ? 34 : 0) + 28 + 24   // + apply-as-filter + match-case rows
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

            matchCaseRow
            filterRow
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

    /// Reflects the standing filter state: on applies the SAME draft Find would
    /// run, off clears it. Disabled when off and the draft composes nothing, so
    /// it never reads as dead text.
    private var filterRow: some View {
        HStack(spacing: 8) {
            Text("Filter to matches").font(.caption)
            Spacer(minLength: 8)
            Toggle("", isOn: filterBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .disabled(!model.isFiltered && !model.canApplyFilter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter to matches")
    }

    private var filterBinding: Binding<Bool> {
        Binding(get: { model.isFiltered },
                set: { enabled in enabled ? model.applyFindAsFilter() : model.clearFilter() })
    }

    /// The ONE case control, shared by Text and Where: off folds ASCII case, on
    /// is byte-exact. Flipping it re-issues whatever is active, since case
    /// sensitivity is part of the request's identity.
    private var matchCaseRow: some View {
        HStack(spacing: 8) {
            Toggle("Match case", isOn: matchCaseBinding)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Spacer(minLength: 8)
        }
        .font(.caption)
        .accessibilityLabel("Match case")
        .accessibilityHint("Off folds letter case; on matches exactly.")
    }

    /// The setter routes through the model, so the toggle re-issues rather than
    /// merely recording the flag.
    private var matchCaseBinding: Binding<Bool> {
        Binding(get: { model.findSession.draft.caseSensitive },
                set: { model.setCaseSensitive($0) })
    }

    private var textFields: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            if dumpChrome {
                // A dump cannot capture a live TextField, so mirror its state.
                Text(model.findSession.draft.text.isEmpty ? "Find" : model.findSession.draft.text)
                    .foregroundStyle(model.findSession.draft.text.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Find", text: $model.findSession.draft.text)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .query)
                    .onSubmit { model.submitFindField() }
                    .onKeyPress(.return, phases: .down) { handleReturn($0) }
            }
        }
        .font(.callout)
        .accessibilityLabel("Find text")
    }
}

extension FindControlView {
    /// A column picker listing every column, hidden ones marked, an operator
    /// picker, and a value field.
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
        let comparison = model.findSession.draft.comparison
        if dumpChrome {
            Text(comparison.glyph)
                .font(.callout.weight(.semibold).monospaced())
                .frame(width: 34, height: 24)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)) }
        } else {
            Picker("Operator", selection: $model.findSession.draft.comparison) {
                ForEach(SearchOperator.allCases, id: \.self) { comparison in
                    Text(comparison.glyph).tag(comparison)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Operator")
            .accessibilityValue(comparison.accessibilityName)
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
                    .onSubmit { model.submitFindField() }
                    .onKeyPress(.return, phases: .down) { handleReturn($0) }
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(rejected ? Color.red : .secondary.opacity(0.4), lineWidth: rejected ? 2 : 1)
        }
        .modifier(Shake(animatableData: shake))
        .accessibilityLabel("Value")
        .accessibilityValue(rejected ? "Enter a number for this comparison." : "")
    }

    private func valueColor(empty: Bool) -> Color {
        if rejected { return .red }
        return empty ? .secondary : .primary
    }

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

    /// Shift+Return steps to the previous match and is consumed here; plain
    /// Return falls through to `.onSubmit`, so the first Enter runs the search and
    /// each later one advances. Either way the field is re-asserted as first
    /// responder next runloop, so a landing scroll cannot quietly drop focus and
    /// stall repeated-Enter cycling.
    private func handleReturn(_ keyPress: KeyPress) -> KeyPress.Result {
        DispatchQueue.main.async { focus = focusTarget }
        guard keyPress.modifiers.contains(.shift) else { return .ignored }
        model.stepFind(.backward)
        return .handled
    }

    /// Keep the field open with its text selected, blink it red, and — unless
    /// Reduce Motion — shake it.
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

/// Custom-drawn rather than a native segmented picker, so it renders in a
/// headless dump.
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
