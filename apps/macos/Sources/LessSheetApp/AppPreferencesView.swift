import AppKit
import LessSheetKit
import SwiftUI

/// A compact macOS preferences panel with native mode segments and theme thumbnails.
struct AppPreferencesView: View {
    @Bindable var appearance: AppAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Color mode").font(.headline)
                AppearanceSegments(selection: Binding(
                    get: { AppearanceMode.allCases.firstIndex(of: appearance.settings.mode) ?? 0 },
                    set: { appearance.settings.mode = AppearanceMode.allCases[$0] }
                ))
                .frame(height: 28)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Theme").font(.headline)
                HStack(spacing: 12) {
                    ForEach(AppearanceTheme.allCases, id: \.self) { theme in
                        ThemeChoice(theme: theme, selected: appearance.settings.theme == theme) {
                            appearance.settings.theme = theme
                        }
                    }
                }
            }
            if appearance.settings.theme == .custom {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    ColorPicker("Background", selection: customColor(background: true), supportsOpacity: false)
                    ColorPicker("Text", selection: customColor(background: false), supportsOpacity: false)
                    Toggle("Alternating row shading", isOn: $appearance.settings.zebraStripes)
                }
            }
        }
        .padding(24)
        .frame(width: 548)
    }

    private func customColor(background: Bool) -> Binding<Color> {
        Binding(get: {
            Color(nsColor: AppPalette.rgb(background ? appearance.settings.customBackground
                                                    : appearance.settings.customText))
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let red = UInt32((min(1, max(0, rgb.redComponent)) * 255).rounded())
            let green = UInt32((min(1, max(0, rgb.greenComponent)) * 255).rounded())
            let blue = UInt32((min(1, max(0, rgb.blueComponent)) * 255).rounded())
            let packed = (red << 16) | (green << 8) | blue
            if background { appearance.settings.customBackground = packed }
            else { appearance.settings.customText = packed }
        })
    }
}

private struct ThemeChoice: View {
    let theme: AppearanceTheme
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var title: String {
        theme == .highContrast ? "High contrast" : theme.rawValue.capitalized
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ThemePreview(theme: theme)
                Text(title).font(.callout)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor
                        : Color(nsColor: .separatorColor).opacity(hovering ? 1 : 0.5),
                                  lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AppearanceSegments: NSViewRepresentable {
    @Binding var selection: Int
    private var labels: [String] { ["System", "Light", "Dark"] }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentStyle = .automatic
        control.setAccessibilityLabel("Color mode")
        for index in 0..<3 {
            control.setWidth(122, forSegment: index)
        }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = selection
        let symbols = ["desktopcomputer", "sun.max", "moon"]
        for index in 0..<3 {
            let image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)
            control.setImage(image, forSegment: index)
            control.setToolTip(labels[index], forSegment: index)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard (0..<3).contains(sender.selectedSegment) else { return }
            selection.wrappedValue = sender.selectedSegment
        }
    }
}

/// The same semantic colors and one-point rules used by the real table.
private struct ThemePreview: View {
    let theme: AppearanceTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = AppPalette.resolve(theme: theme, dark: colorScheme == .dark)
        VStack(spacing: 0) {
            previewRow(["A", "B"], palette: palette)
                .background(Color(nsColor: palette.header))
                .overlay(alignment: .bottom) { Color(nsColor: palette.line).frame(height: 1) }
            previewRow(["12", "34"], palette: palette)
            previewRow(["56", "78"], palette: palette)
                .background(Color(nsColor: palette.foreground).opacity(
                    theme == .custom && AppAppearance.shared.settings.zebraStripes ? 0.06 : 0))
        }
        .frame(width: 96, height: 72)
        .background(Color(nsColor: palette.background))
        .overlay { Rectangle().strokeBorder(Color(nsColor: palette.line), lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private func previewRow(_ values: [String], palette: AppPalette) -> some View {
        HStack(spacing: 0) {
            Text(values[0]).frame(width: 48, height: 24)
                .overlay(alignment: .trailing) { Color(nsColor: palette.line).frame(width: 1) }
            Text(values[1]).frame(width: 48, height: 24)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Color(nsColor: palette.foreground))
    }
}
