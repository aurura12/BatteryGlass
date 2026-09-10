import XCTest
@testable import BatteryGlass

final class MenuBarLabelTests: XCTestCase {
    func testBatteryIconUsesNativeSymbolForNormalBattery() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.percent = 80

        XCTAssertEqual(MenuBarBatterySymbol.name(for: snapshot), "battery.75percent")
    }

    func testChargingIconReflectsActualLevelInsteadOfFullBattery() {
        var low = BatterySnapshot()
        low.state = .charging
        low.percent = 40
        XCTAssertEqual(MenuBarBatterySymbol.name(for: low), "battery.50percent")

        var high = BatterySnapshot()
        high.state = .charging
        high.percent = 92
        XCTAssertEqual(MenuBarBatterySymbol.name(for: high), "battery.100percent")
    }

    func testUnknownStateUsesEmptyBatterySymbol() {
        var snapshot = BatterySnapshot()
        snapshot.state = .unknown
        snapshot.percent = 0

        XCTAssertEqual(MenuBarBatterySymbol.name(for: snapshot), "battery.0percent")
    }

    func testAccessibilityLabelAnnouncesChargingState() {
        var snapshot = BatterySnapshot()
        snapshot.state = .charging
        snapshot.percent = 40

        let label = MenuBarAccessibility.label(for: snapshot)
        XCTAssertTrue(label.contains("40%"))
        XCTAssertTrue(label.contains("正在充电"))
    }

    func testAccessibilityLabelDescribesDischargingAndUnknown() {
        var discharging = BatterySnapshot()
        discharging.state = .discharging
        discharging.percent = 55
        XCTAssertTrue(MenuBarAccessibility.label(for: discharging).contains("电池供电"))

        var unknown = BatterySnapshot()
        unknown.state = .unknown
        XCTAssertEqual(MenuBarAccessibility.label(for: unknown), "BatteryGlass，未检测到电池")
    }
}
