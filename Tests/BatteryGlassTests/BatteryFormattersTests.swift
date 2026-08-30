import XCTest
@testable import BatteryGlass

final class BatteryFormattersTests: XCTestCase {
    func testEnergyUsesThreeFractionDigits() {
        XCTAssertEqual(BatteryFormatters.energyKWh(1.23456), "1.235 kWh")
    }

    func testMenuBarTimeRemainingFormatsHoursAndMinutes() {
        XCTAssertEqual(BatteryFormatters.menuBarTimeRemaining(8_100), "2h15m")
        XCTAssertEqual(BatteryFormatters.menuBarTimeRemaining(2_700), "45m")
        XCTAssertEqual(BatteryFormatters.menuBarTimeRemaining(30), "0m")
    }

    func testMenuBarTimeRemainingHandlesInvalidValues() {
        XCTAssertEqual(BatteryFormatters.menuBarTimeRemaining(nil), "--")
        XCTAssertEqual(BatteryFormatters.menuBarTimeRemaining(-10), "--")
        XCTAssertEqual(BatteryFormatters.menuBarTimeRemaining(0), "--")
    }

    func testXAxisLabels() {
        let date = BatteryFormatters.dayKeyDate("2026-08-30")!
        XCTAssertEqual(BatteryFormatters.xAxisDayLabel(date), "8/30")
        XCTAssertEqual(BatteryFormatters.xAxisMonthLabel(date), "2026-08")
    }
}
