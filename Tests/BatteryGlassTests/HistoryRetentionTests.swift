import Foundation
import XCTest
@testable import BatteryGlass

final class HistoryRetentionTests: XCTestCase {
    func testRetentionKeepsAllCurrentDaySamplesAndLastPreviousDaySample() {
        let calendar = utcCalendar()
        let previousDay = date("2026-08-26 23:59:55")
        let currentDay = date("2026-08-27 00:00:05")
        let samples = [
            historySample(at: previousDay),
            historySample(at: currentDay),
            historySample(at: currentDay.addingTimeInterval(5)),
            historySample(at: currentDay.addingTimeInterval(10))
        ]

        let kept = HistoryRetention.samplesForCurrentDay(
            samples,
            now: currentDay,
            calendar: calendar
        )

        XCTAssertEqual(kept.map(\.timestamp), [previousDay, currentDay, currentDay.addingTimeInterval(5), currentDay.addingTimeInterval(10)])
    }

    func testSamplesForDayReturnsOnlySamplesInsideCalendarDay() {
        let calendar = utcCalendar()
        let previousDay = date("2026-08-26 23:59:55")
        let currentDay = date("2026-08-27 00:00:05")
        let nextDay = date("2026-08-28 00:00:05")
        let samples = [
            historySample(at: previousDay),
            historySample(at: currentDay),
            historySample(at: nextDay)
        ]

        let kept = HistoryRetention.samples(
            forDay: currentDay,
            from: samples,
            calendar: calendar
        )

        XCTAssertEqual(kept.map(\.timestamp), [currentDay])
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

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
