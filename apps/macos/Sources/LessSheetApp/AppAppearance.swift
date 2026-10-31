import AppKit
import LessSheetKit
import Observation

/// Application preferences never belong to a document session.
@MainActor @Observable
final class AppAppearance {
    static let shared = AppAppearance()
    var settings: AppearanceSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: .standard)
            apply()
        }
    }

    private init() { settings = AppearanceSettings(defaults: .standard) }

    func apply() {
        switch settings.mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        NativeGridController.live?.appearanceChanged()
    }
}

/// Both the real grid and the miniature tables resolve this palette. Neutral
/// retains macOS semantic colors; custom palettes match the Linux choices.
@MainActor
struct AppPalette {
    let background: NSColor
    let foreground: NSColor
    let header: NSColor
    let line: NSColor
    let accent: NSColor
    let secondary: NSColor

    static var current: AppPalette {
        resolve(theme: AppAppearance.shared.settings.theme,
                dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    static func resolve(theme: AppearanceTheme, dark: Bool) -> AppPalette {
        if theme == .neutral {
            return AppPalette(background: .textBackgroundColor, foreground: .labelColor,
                              header: .windowBackgroundColor, line: .gridColor,
                              accent: .controlAccentColor, secondary: .secondaryLabelColor)
        }
        let background: NSColor
        let foreground: NSColor
        let accent: NSColor
        if theme == .custom {
            background = rgb(AppAppearance.shared.settings.customBackground)
            foreground = rgb(AppAppearance.shared.settings.customText)
            accent = .controlAccentColor
        } else if theme == .highContrast {
            background = dark ? .black : .white
            foreground = dark ? .white : .black
            accent = rgb(dark ? 0x75BAFF : 0x004CA3)
        } else {
            background = rgb(dark ? 0x454E49 : 0xDCDED5)
            foreground = rgb(dark ? 0xB4C0B7 : 0x575E59)
            accent = rgb(dark ? 0x9AB4A4 : 0x536F64)
        }
        let tint: CGFloat = theme == .highContrast ? 0.12 : 0.04
        return AppPalette(background: background, foreground: foreground,
                          header: background.blended(withFraction: tint, of: foreground) ?? background,
                          line: foreground.withAlphaComponent(theme == .highContrast ? 0.4 : 0.08),
                          accent: accent, secondary: foreground)
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

extension NativeGridController {
    /// Repaint only allocated views. Changing appearance must never reload the
    /// file, scan rows, change the selection, or reset the scroll position.
    func appearanceChanged() {
        scroll.backgroundColor = AppPalette.current.background
        table.backgroundColor = AppPalette.current.background
        table.enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
        table.needsDisplay = true
        header.needsDisplay = true
        gutter.needsDisplay = true
        flushGridDisplay()
    }
}
