import Foundation
import XCTest
@testable import BatteryGlass

final class ChartTimeAxisTests: XCTestCase {
    // MARK: - 刻度单位

    func testSubHourSpanUsesTenMinuteUnit() {
        XCTAssertEqual(ChartTimeAxis.unit(forSpan: 1_800), .minute(step: 10))
    }

    func testOneToTwoHourSpanUsesThirtyMinuteUnit() {
        XCTAssertEqual(ChartTimeAxis.unit(forSpan: 3_600), .minute(step: 30))
        XCTAssertEqual(ChartTimeAxis.unit(forSpan: 7_199), .minute(step: 30))
    }

    func testMultiHourSpanUsesHourlyUnit() {
        XCTAssertEqual(ChartTimeAxis.unit(forSpan: 7_200), .hour(step: 1))
        XCTAssertEqual(ChartTimeAxis.unit(forSpan: 21_599), .hour(step: 1))
    }

    func testHalfDaySpanUsesThreeHourStep() {
        XCTAssertEqual(ChartTimeAxis.unit(forSpan: 21_600), .hour(step: 3))
    }

    func testFullDaySpanUsesSixHourStep() {
        XCTAssertEqual(ChartTimeAxis.unit(forSpan: 86_400), .hour(step: 6))
    }

    func testInvalidSpanFallsBackToSixHourStep() {
        for span in [0.0, -10.0, .nan, .infinity] {
            XCTAssertEqual(ChartTimeAxis.unit(forSpan: span), .hour(step: 6))
        }
    }

    func testIncludesMinutesOnlyForMinuteUnits() {
        XCTAssertTrue(ChartTickUnit.minute(step: 10).includesMinutes)
        XCTAssertFalse(ChartTickUnit.hour(step: 6).includesMinutes)
    }

    // MARK: - 刻度生成

    func testFullDayMarksLandOnSixHourGrid() {
        let calendar = gmtCalendar()
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let domain = start...start.addingTimeInterval(20 * 3_600)

        let marks = ChartTimeAxis.marks(in: domain, unit: .hour(step: 6), calendar: calendar)

        XCTAssertEqual(marks.map { $0.timeIntervalSince(start) }, [0, 6, 12, 18].map { Double($0) * 3_600 })
    }

    func testZoomedWindowMarksAreAlignedNotOffset() {
        let calendar = gmtCalendar()
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        // 窗口从 13:37 起，刻度必须仍对齐到整点 / 整十分钟，而不是从 13:37 起递推。
        let lower = start.addingTimeInterval(13 * 3_600 + 37 * 60)
        let upper = start.addingTimeInterval(15 * 3_600 + 30 * 60)
        let domain = lower...upper

        let hourly = ChartTimeAxis.marks(in: domain, unit: .hour(step: 1), calendar: calendar)
        XCTAssertEqual(hourly.map { $0.timeIntervalSince(start) },
                       [14, 15].map { Double($0) * 3_600 })

        let tenMinute = ChartTimeAxis.marks(in: domain, unit: .minute(step: 10), calendar: calendar)
        XCTAssertEqual(tenMinute.count, 12)
        XCTAssertEqual(tenMinute.first?.timeIntervalSince(start), Double(13 * 3_600 + 40 * 60))
    }

    func testMarksAreAscendingAndInsideDomain() {
        let calendar = gmtCalendar()
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let domain = start.addingTimeInterval(3 * 3_600)...start.addingTimeInterval(11 * 3_600)

        let marks = ChartTimeAxis.marks(in: domain, unit: .hour(step: 3), calendar: calendar)

        XCTAssertEqual(marks, marks.sorted())
        XCTAssertTrue(marks.allSatisfy { domain.contains($0) })
        XCTAssertEqual(marks.count, 3)
    }

    func testZeroWidthDomainDoesNotCrash() {
        let calendar = gmtCalendar()
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

        let marks = ChartTimeAxis.marks(in: start...start, unit: .hour(step: 1), calendar: calendar)

        XCTAssertLessThanOrEqual(marks.count, 1)
    }

    // MARK: - Helpers

    private func gmtCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
