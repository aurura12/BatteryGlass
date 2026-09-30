import Foundation
import XCTest
@testable import BatteryGlass

final class HistoryRetentionTests: XCTestCase {
    // MARK: - retainedSamples

    func testRetentionKeepsAllTodayAndThinsOlderToLastOfBucket() {
        let calendar = utcCalendar()
        let yesterday = date("2026-08-26 10:00:00")
        let today = date("2026-08-27 00:00:05")
        let samples = [
            historySample(at: yesterday),
            historySample(at: yesterday.addingTimeInterval(30)),
            historySample(at: yesterday.addingTimeInterval(59)),
            historySample(at: yesterday.addingTimeInterval(60)),
            historySample(at: today),
            historySample(at: today.addingTimeInterval(5))
        ]

        let kept = HistoryRetention.retainedSamples(
            samples,
            now: today,
            retentionDays: 7,
            olderResolution: 60,
            calendar: calendar
        )

        // 昨天：10:00:00/10:00:30/10:00:59 同一分钟桶只留最后一条，10:01:00 另起一桶。
        // 今天：原样全部保留。
        XCTAssertEqual(
            kept.map(\.timestamp),
            [
                yesterday.addingTimeInterval(59),
                yesterday.addingTimeInterval(60),
                today,
                today.addingTimeInterval(5)
            ]
        )
    }

    func testRetentionPreservesLastPreviousDaySample() {
        let calendar = utcCalendar()
        let previousDay = date("2026-08-26 23:59:55")
        let currentDay = date("2026-08-27 00:00:05")

        let kept = HistoryRetention.retainedSamples(
            [historySample(at: previousDay), historySample(at: currentDay)],
            now: currentDay,
            retentionDays: 7,
            olderResolution: 60,
            calendar: calendar
        )

        // 跨午夜的那条边界样本是今天能量插值的起点，必须保留。
        XCTAssertEqual(kept.map(\.timestamp), [previousDay, currentDay])
    }

    func testRetentionDropsDaysBeyondRetentionWindow() {
        let calendar = utcCalendar()
        let now = date("2026-08-27 12:00:00")
        let tooOld = date("2026-08-19 12:00:00")     // 8 天前
        let inWindow = date("2026-08-21 12:00:00")   // 6 天前

        let kept = HistoryRetention.retainedSamples(
            [historySample(at: tooOld), historySample(at: inWindow)],
            now: now,
            retentionDays: 7,
            olderResolution: 60,
            calendar: calendar
        )

        XCTAssertEqual(kept.map(\.timestamp), [inWindow])
    }

    func testRetentionIsAscendingAndNeverGrows() {
        let calendar = utcCalendar()
        let now = date("2026-08-27 12:00:00")
        // 乱序输入：降采样按时间排序后进行，输出必须升序且条数不超过输入。
        let samples = [
            historySample(at: date("2026-08-26 10:00:40")),
            historySample(at: now),
            historySample(at: date("2026-08-26 10:00:10")),
            historySample(at: now.addingTimeInterval(-5))
        ]

        let kept = HistoryRetention.retainedSamples(
            samples,
            now: now,
            retentionDays: 7,
            olderResolution: 60,
            calendar: calendar
        )

        XCTAssertEqual(kept.map(\.timestamp), kept.map(\.timestamp).sorted())
        XCTAssertLessThanOrEqual(kept.count, samples.count)
        XCTAssertEqual(kept.map(\.timestamp), [
            date("2026-08-26 10:00:40"),
            now.addingTimeInterval(-5),
            now
        ])
    }

    func testRetentionSingleDayKeepsOnlyToday() {
        let calendar = utcCalendar()
        let now = date("2026-08-27 00:00:30")
        let yesterday = date("2026-08-26 23:00:00")

        let kept = HistoryRetention.retainedSamples(
            [historySample(at: yesterday), historySample(at: now)],
            now: now,
            retentionDays: 1,
            olderResolution: 60,
            calendar: calendar
        )

        XCTAssertEqual(kept.map(\.timestamp), [now])
    }

    func testRetentionWithoutResolutionOnlyTrimsByAge() {
        let calendar = utcCalendar()
        let now = date("2026-08-27 12:00:00")
        let yesterday = date("2026-08-26 10:00:10")
        let samples = [
            historySample(at: yesterday),
            historySample(at: yesterday.addingTimeInterval(20)),
            historySample(at: date("2026-08-18 10:00:00"))
        ]

        let kept = HistoryRetention.retainedSamples(
            samples,
            now: now,
            retentionDays: 7,
            olderResolution: 0,
            calendar: calendar
        )

        XCTAssertEqual(kept.map(\.timestamp), [yesterday, yesterday.addingTimeInterval(20)])
    }

    // MARK: - samples(lastDays:)

    func testSamplesLastDaysFiltersToInclusiveStart() {
        let calendar = utcCalendar()
        let now = date("2026-08-27 12:00:00")
        let startOfWindow = date("2026-08-21 00:00:00")   // 恰好 7 天窗口的第一刻
        let outsideWindow = date("2026-08-20 23:59:59")

        let kept = HistoryRetention.samples(
            lastDays: 7,
            from: [historySample(at: outsideWindow), historySample(at: startOfWindow)],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(kept.map(\.timestamp), [startOfWindow])
    }

    func testSamplesLastDaysOneKeepsOnlyToday() {
        let calendar = utcCalendar()
        let now = date("2026-08-27 12:00:00")
        let yesterday = date("2026-08-26 23:59:59")

        let kept = HistoryRetention.samples(
            lastDays: 1,
            from: [historySample(at: yesterday), historySample(at: now)],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(kept.map(\.timestamp), [now])
    }

    // MARK: - samples(forDay:)

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

    // MARK: - 容量

    func testWorstCaseRetainedCountUnderLoadLimits() {
        // 最坏情况：7 天都按 5 秒精度记录（约 17,280 条/天）。
        let calendar = utcCalendar()
        let now = date("2026-08-27 12:00:00")
        let todayStart = now.addingTimeInterval(-12 * 3_600)

        var samples: [HistorySample] = []
        for dayOffset in 0..<7 {
            let dayStart = calendar.date(
                byAdding: .day,
                value: -dayOffset,
                to: todayStart
            )!
            for index in 0..<17_280 {
                samples.append(historySample(at: dayStart.addingTimeInterval(Double(index) * 5)))
            }
        }

        let kept = HistoryRetention.retainedSamples(
            samples,
            now: now,
            retentionDays: 7,
            olderResolution: 60,
            calendar: calendar
        )

        // 今天（5 秒精度）17,280 条 + 往日 6 天各降到 1 分钟 1,440 条。
        XCTAssertEqual(kept.count, 17_280 + 6 * 1_440)
        XCTAssertLessThan(kept.count, HistoryLoadLimits.maxHistorySamples)
        // 单条约 203 字节时的文件体积仍远低于上限（按 250 字节留余量估算）。
        XCTAssertLessThan(kept.count * 250, HistoryLoadLimits.maxHistoryFileBytes)
    }

    // MARK: - Helpers

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
