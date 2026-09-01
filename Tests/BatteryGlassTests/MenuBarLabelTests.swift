import XCTest
@testable import BatteryGlass

final class MenuBarLabelTests: XCTestCase {
    func testBatteryIconUsesNativeSymbolForNormalBattery() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.percent = 80

        XCTAssertEqual(MenuBarBatterySymbol.name(for: snapshot), "battery.75percent")
    }
}
