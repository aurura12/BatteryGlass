import XCTest
@testable import BatteryGlass

final class HistoryRangeTests: XCTestCase {
    func testDaysMatchRawValues() {
        XCTAssertEqual(HistoryRange.today.days, 1)
        XCTAssertEqual(HistoryRange.threeDays.days, 3)
        XCTAssertEqual(HistoryRange.sevenDays.days, 7)
    }

    func testTitlesAreLocalizedChinese() {
        XCTAssertEqual(HistoryRange.today.title, "今日")
        XCTAssertEqual(HistoryRange.threeDays.title, "近 3 天")
        XCTAssertEqual(HistoryRange.sevenDays.title, "近 7 天")
    }

    func testAllCasesAreOrderedShortestFirst() {
        XCTAssertEqual(HistoryRange.allCases, [.today, .threeDays, .sevenDays])
    }

    func testDetailWindowTitleCombinesRangeAndBaseTitle() {
        XCTAssertEqual(ExpandedChart.power.title(range: .today), "今日 · 功率曲线")
        XCTAssertEqual(ExpandedChart.voltage.title(range: .sevenDays), "近 7 天 · 电压曲线")
    }

    func testExpandedChartMapsToMetricTabs() {
        XCTAssertNil(ExpandedChart.power.metric)
        XCTAssertNil(ExpandedChart.level.metric)
        XCTAssertEqual(ExpandedChart.temperature.metric, .temperature)
        XCTAssertEqual(ExpandedChart.voltage.metric, .voltage)
        XCTAssertEqual(ExpandedChart(metric: .voltage), .voltage)
        XCTAssertEqual(ExpandedChart(metric: .temperature), .temperature)
    }
}
