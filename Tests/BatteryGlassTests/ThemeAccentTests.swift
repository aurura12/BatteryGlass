import SwiftUI
import XCTest
@testable import BatteryGlass

final class ThemeAccentTests: XCTestCase {
    func testHexRoundTrip() {
        XCTAssertEqual(ThemeAccent(hex: "#D94F8A")?.hexString, "#D94F8A")
        XCTAssertEqual(ThemeAccent(hex: "12a594")?.hexString, "#12A594")
        // 8 位写法忽略 alpha，避免取色器带透明度时把半透明色写进设置。
        XCTAssertEqual(ThemeAccent(hex: "#D94F8A80")?.hexString, "#D94F8A")
    }

    func testMalformedHexIsRejected() {
        for value in ["", "#", "#12345", "#1234567", "#GGGGGG", "蓝色"] {
            XCTAssertNil(ThemeAccent(hex: value), "应拒绝非法值：\(value)")
        }
    }

    func testComponentsAreClampedToUnitRange() {
        let accent = ThemeAccent(red: -0.5, green: 2, blue: 0.5)
        XCTAssertEqual(accent.red, 0)
        XCTAssertEqual(accent.green, 1)
        XCTAssertEqual(accent.blue, 0.5)
    }

    func testColorRoundTripKeepsStoredHex() {
        let accent = ThemeAccent(hex: "#E07A12")!
        XCTAssertEqual(ThemeAccent(color: accent.color).hexString, "#E07A12")
    }

    func testPresetsAreDistinctAndDefaultIsLegacyBlue() {
        let hexes = ThemeAccentPreset.allCases.map(\.accent.hexString)
        XCTAssertEqual(Set(hexes).count, ThemeAccentPreset.allCases.count)
        XCTAssertEqual(ThemeAccentPreset.blue.accent.hexString, ThemeAccent.defaultHex)
        XCTAssertEqual(ThemeAccent.fallback.hexString, ThemeAccent.defaultHex)
    }
}

@MainActor
final class ThemeAccentSettingsTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    func testDefaultAccentWhenUnset() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }

        XCTAssertEqual(AppSettings(defaults: defaults).themeAccentHex, ThemeAccent.defaultHex)
    }

    func testAccentChangeIsPersisted() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }

        let settings = AppSettings(defaults: defaults)
        settings.themeAccentHex = "#12A594"

        XCTAssertEqual(AppSettings(defaults: defaults).themeAccent.hexString, "#12A594")
    }

    func testInvalidStoredValueFallsBackToDefault() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }

        defaults.set("不是颜色", forKey: "themeAccentHex")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.themeAccentHex, ThemeAccent.defaultHex)
        XCTAssertEqual(settings.themeAccent.hexString, ThemeAccent.defaultHex)
    }
}

final class BatteryStylingAccentTests: XCTestCase {
    private let accent = Color(red: 0.85, green: 0.31, blue: 0.54)

    func testDischargingUsesThemeAccent() {
        let snapshot = BatterySnapshot(state: .discharging, percent: 50)
        XCTAssertEqual(BatteryStyling.tint(for: snapshot, accent: accent), accent)
        XCTAssertEqual(BatteryStyling.gradient(for: snapshot, accent: accent).first, accent)
    }

    func testStatusColorsAreNotOverriddenByThemeAccent() {
        XCTAssertEqual(
            BatteryStyling.tint(for: BatterySnapshot(state: .charging, percent: 50), accent: accent),
            DesignTokens.statusGreen
        )
        XCTAssertEqual(
            BatteryStyling.tint(for: BatterySnapshot(state: .discharging, percent: 10), accent: accent),
            DesignTokens.statusRed
        )
        XCTAssertEqual(
            BatteryStyling.tint(for: BatterySnapshot(state: .discharging, percent: 20), accent: accent),
            DesignTokens.statusAmber
        )
    }

    func testUnknownBatteryStaysNeutral() {
        XCTAssertEqual(
            BatteryStyling.tint(for: BatterySnapshot(), accent: accent),
            Color.secondary
        )
    }
}
