import Foundation

public enum AppearanceMode: String, CaseIterable, Sendable {
    case system, light, dark
}

public enum AppearanceTheme: String, CaseIterable, Sendable {
    case neutral, highContrast, soft, custom
}

/// Stable string identifiers keep saved choices independent of picker order.
public struct AppearanceSettings: Equatable, Sendable {
    public var mode: AppearanceMode
    public var theme: AppearanceTheme
    public var customBackground: UInt32 = 0xFFFFFF
    public var customText: UInt32 = 0x333333
    public var zebraStripes = true

    public init(mode: AppearanceMode = .system, theme: AppearanceTheme = .neutral) {
        self.mode = mode
        self.theme = theme
    }

    public init(defaults: UserDefaults) {
        mode = defaults.string(forKey: "appearance.mode").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        theme = defaults.string(forKey: "appearance.theme").flatMap(AppearanceTheme.init(rawValue:)) ?? .neutral
        if let value = defaults.object(forKey: "appearance.background") as? NSNumber,
           (0...0xFFFFFF).contains(value.int64Value) { customBackground = value.uint32Value }
        if let value = defaults.object(forKey: "appearance.text") as? NSNumber,
           (0...0xFFFFFF).contains(value.int64Value) { customText = value.uint32Value }
        if defaults.object(forKey: "appearance.stripes") != nil {
            zebraStripes = defaults.bool(forKey: "appearance.stripes")
        }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: "appearance.mode")
        defaults.set(theme.rawValue, forKey: "appearance.theme")
        defaults.set(customBackground, forKey: "appearance.background")
        defaults.set(customText, forKey: "appearance.text")
        defaults.set(zebraStripes, forKey: "appearance.stripes")
    }
}
