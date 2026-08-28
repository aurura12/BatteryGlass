import XCTest
@testable import BatteryGlass

final class BatteryFormattersTests: XCTestCase {
    func testEnergyUsesThreeFractionDigits() {
        XCTAssertEqual(BatteryFormatters.energyKWh(1.23456), "1.235 kWh")
    }
}
