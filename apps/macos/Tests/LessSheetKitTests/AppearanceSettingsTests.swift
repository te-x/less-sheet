import Foundation
import LessSheetKit
import XCTest

final class AppearanceSettingsTests: XCTestCase {
    func testDefaultsAndUnknownValues() throws {
        let name = "less-sheet.appearance-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppearanceSettings(defaults: defaults), AppearanceSettings())
        defaults.set("removed", forKey: "appearance.mode")
        defaults.set("colorful", forKey: "appearance.theme")
        XCTAssertEqual(AppearanceSettings(defaults: defaults), AppearanceSettings())
    }

    func testEveryModeAndThemeSurvivesReloadIndependently() throws {
        let name = "less-sheet.appearance-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for mode in AppearanceMode.allCases {
            for theme in AppearanceTheme.allCases {
                let settings = AppearanceSettings(mode: mode, theme: theme)
                settings.save(to: defaults)
                XCTAssertEqual(AppearanceSettings(defaults: defaults), settings)
            }
        }
    }

    func testCustomColorsAndStripesSurviveThemeChanges() throws {
        let name = "less-sheet.appearance-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = AppearanceSettings(mode: .dark, theme: .custom)
        settings.customBackground = 0x25392A
        settings.customText = 0xC4D8AB
        settings.zebraStripes = false
        settings.save(to: defaults)
        XCTAssertEqual(AppearanceSettings(defaults: defaults), settings)
        settings.theme = .neutral
        settings.save(to: defaults)
        var restored = AppearanceSettings(defaults: defaults)
        restored.theme = .custom
        XCTAssertEqual(restored.customBackground, 0x25392A)
        XCTAssertEqual(restored.customText, 0xC4D8AB)
        XCTAssertFalse(restored.zebraStripes)
    }

    func testInvalidSavedColorsUseDefaults() throws {
        let name = "less-sheet.appearance-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(-1, forKey: "appearance.background")
        defaults.set(0x1000000, forKey: "appearance.text")
        let restored = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(restored.customBackground, 0xFFFFFF)
        XCTAssertEqual(restored.customText, 0x333333)
        XCTAssertTrue(restored.zebraStripes)
    }

}
