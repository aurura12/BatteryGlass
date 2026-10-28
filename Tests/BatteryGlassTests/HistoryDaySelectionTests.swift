import Foundation
import XCTest
@testable import BatteryGlass

final class HistoryDaySelectionTests: XCTestCase {
    func testAlwaysIncludesTodayEvenWithoutSamples() {
        let now = date("2026-08-27 12:00:00")

        let selection = HistoryDaySelection(
            days: [],
            selected: nil,
            now: now,
            calendar: utcCalendar()
        )

        XCTAssertEqual(selection.days, [calendar(now).startOfDay(for: now)])
        XCTAssertEqual(selection.label, "今日")
        XCTAssertTrue(selection.isToday)
        XCTAssertFalse(selection.canGoOlder)
        XCTAssertFalse(selection.canGoNewer)
    }

    func testDefaultsToTodayWhenNoSelection() {
        let selection = HistoryDaySelection(
            days: [date("2026-08-25 10:00:00"), date("2026-08-26 10:00:00")],
            selected: nil,
            now: date("2026-08-27 12:00:00"),
            calendar: utcCalendar()
        )

        XCTAssertEqual(selection.selected, date("2026-08-27 00:00:00"))
        XCTAssertTrue(selection.isToday)
    }

    func testOlderAndNewerNavigation() {
        let selection = HistoryDaySelection(
            days: [
                date("2026-08-25 10:00:00"),
                date("2026-08-26 10:00:00"),
                date("2026-08-27 10:00:00")
            ],
            selected: date("2026-08-26 09:00:00"),
            now: date("2026-08-27 12:00:00"),
            calendar: utcCalendar()
        )

        XCTAssertTrue(selection.canGoOlder)
        XCTAssertTrue(selection.canGoNewer)
        XCTAssertEqual(selection.olderDay, date("2026-08-25 00:00:00"))
        XCTAssertEqual(selection.newerDay, date("2026-08-27 00:00:00"))
    }

    func testNavigationStopsAtBothEnds() {
        let days = [date("2026-08-26 10:00:00"), date("2026-08-27 10:00:00")]

        let oldest = HistoryDaySelection(
            days: days,
            selected: date("2026-08-26 09:00:00"),
            now: date("2026-08-27 12:00:00"),
            calendar: utcCalendar()
        )
        XCTAssertFalse(oldest.canGoOlder)
        XCTAssertNil(oldest.olderDay)
        XCTAssertTrue(oldest.canGoNewer)

        let newest = HistoryDaySelection(
            days: days,
            selected: date("2026-08-27 12:00:00"),
            now: date("2026-08-27 12:00:00"),
            calendar: utcCalendar()
        )
        XCTAssertTrue(newest.canGoOlder)
        XCTAssertFalse(newest.canGoNewer)
        XCTAssertNil(newest.newerDay)
    }

    func testSnapsSelectionToNearestAvailableDayWhenPruned() {
        // 今天 8/27：8/22 与 8/27 都有样本，而 8/24 的样本已被清理 → 选中 8/24 应回退到 8/22。
        let selection = HistoryDaySelection(
            days: [date("2026-08-22 09:00:00"), date("2026-08-27 09:00:00")],
            selected: date("2026-08-24 09:00:00"),
            now: date("2026-08-27 12:00:00"),
            calendar: utcCalendar()
        )

        XCTAssertEqual(selection.selected, date("2026-08-22 00:00:00"))
        XCTAssertFalse(selection.canGoOlder)
    }

    func testSelectionSnapsForwardToNewestWhenBeforeAllDays() {
        let selection = HistoryDaySelection(
            days: [date("2026-08-26 09:00:00")],
            selected: date("2026-08-20 09:00:00"),
            now: date("2026-08-27 12:00:00"),
            calendar: utcCalendar()
        )

        XCTAssertEqual(selection.selected, date("2026-08-27 00:00:00"))
    }

    func testLabelsUseTodayYesterdayAndDate() {
        let selection = HistoryDaySelection(
            days: [
                date("2026-08-25 10:00:00"),
                date("2026-08-26 10:00:00"),
                date("2026-08-27 10:00:00")
            ],
            selected: date("2026-08-27 12:00:00"),
            now: date("2026-08-27 12:00:00"),
            calendar: utcCalendar()
        )

        XCTAssertEqual(selection.label, "今日")
        XCTAssertEqual(selection.label(for: date("2026-08-26 09:00:00")), "昨天")
        // M/d 标签交给 BatteryFormatters.xAxisDayLabel（时区相关），只断言一致性。
        XCTAssertEqual(
            selection.label(for: date("2026-08-25 09:00:00")),
            BatteryFormatters.xAxisDayLabel(date("2026-08-25 09:00:00"))
        )
    }

    // MARK: - Helpers

    private func calendar(_ now: Date) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testMenuKeepsOnlyRecentDaysButSelectionStillSeesAll() {
        let now = date("2026-08-27 12:00:00")
        let calendar = utcCalendar()
        let days = (0..<200).map { calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: now))! }
        let selection = HistoryDaySelection(days: days, selected: now, now: now, calendar: calendar)

        let menuDays = selection.recentMenuDays(limit: 120)
        XCTAssertEqual(menuDays.count, 120)
        XCTAssertEqual(menuDays.last, calendar.startOfDay(for: now))
        XCTAssertEqual(selection.days.count, 200)
    }

    func testMenuReturnsEveryDayWhenBelowLimit() {
        let now = date("2026-08-27 12:00:00")
        let calendar = utcCalendar()
        let days = (0..<5).map { calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: now))! }
        let selection = HistoryDaySelection(days: days, selected: now, now: now, calendar: calendar)

        XCTAssertEqual(selection.recentMenuDays(), selection.days)
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }

    private func historySample(at timestamp: Date) -> HistorySample {
        HistorySample(
            timestamp: timestamp,
            power: 0,
            consumptionPowerW: 20,
            percent: 50,
            cycleCount: 1,
            healthPercent: 100
        )
    }

    private func utcCalendar() -> Calendar {
        calendar(date("2026-08-27 12:00:00"))
    }
}
