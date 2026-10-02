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

    func testHistoryDateIncludesYearForOlderYearsAndUsesRequestedTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_788_048_000) // 2026-08-30 12:00 UTC
        let older = calendar.date(from: DateComponents(year: 2025, month: 8, day: 30))!
        XCTAssertEqual(BatteryFormatters.historyDayLabel(older, now: now, calendar: calendar), "2025/8/30")
        let sameYear = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25))!
        XCTAssertEqual(BatteryFormatters.historyDayLabel(sameYear, now: now, calendar: calendar), "8/25")
    }
}
