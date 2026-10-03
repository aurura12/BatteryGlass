import Foundation
import XCTest
@testable import BatteryGlass

/// 「未被积分覆盖的时长」统计：断点、功率读数缺失、睡眠排除与跨午夜拆分。
final class SamplingGapAccountingTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
    ) -> Date {
        calendar.date(
            from: DateComponents(
                year: year, month: month, day: day,
                hour: hour, minute: minute, second: second
            )
        )!
    }

    private func sample(at timestamp: Date, power: Double?) -> HistorySample {
        HistorySample(
            timestamp: timestamp,
            power: 0,
            consumptionPowerW: power,
            percent: 50,
            cycleCount: 1,
            healthPercent: 100
        )
    }

    func testIgnoresShortIntervalsWithValidReadings() {
        let samples = [
            sample(at: date(2026, 10, 3, 10, 0, 0), power: 20),
            sample(at: date(2026, 10, 3, 10, 0, 5), power: 21)
        ]

        let report = EnergyCalculator.unaccountedSecondsByDay(samples: samples, calendar: calendar)

        XCTAssertTrue(report.isEmpty)
    }

    func testCountsSecondsWithMissingPowerReading() {
        let samples = [
            sample(at: date(2026, 10, 3, 10, 0, 0), power: 20),
            sample(at: date(2026, 10, 3, 10, 0, 5), power: nil),
            sample(at: date(2026, 10, 3, 10, 0, 10), power: 22)
        ]

        let report = EnergyCalculator.unaccountedSecondsByDay(samples: samples, calendar: calendar)
        let today = report["2026-10-03"]

        // 两条相邻区间都缺一端读数，各计 5 秒，且归入「读数缺失」而非「断点」。
        XCTAssertEqual(today?.missingReadingSeconds ?? 0, 10, accuracy: 0.0001)
        XCTAssertEqual(today?.gapSeconds ?? 0, 0, accuracy: 0.0001)
        XCTAssertEqual(today?.needsWarning, false)
    }

    func testShortMissingReadingsStayBelowWarning() {
        // 实测一次拔插电源约 1 分钟读数缺失、一天 2~3 次：量级不足 0.5%，
        // 不应点亮整天告警。
        var samples = [sample(at: date(2026, 10, 3, 10, 0, 0), power: nil)]
        for index in 1...24 {
            samples.append(sample(at: date(2026, 10, 3, 10, 0, index * 5), power: nil))
        }

        let report = EnergyCalculator.unaccountedSecondsByDay(samples: samples, calendar: calendar)
        let today = report["2026-10-03"]

        XCTAssertEqual(today?.missingReadingSeconds ?? 0, 120, accuracy: 0.0001)
        XCTAssertLessThan(today?.missingReadingSeconds ?? 0, EnergyCalculator.missingReadingWarningSeconds)
        XCTAssertEqual(today?.needsWarning, false)
    }

    func testAccumulatedMissingReadingsWarnOnceAboveThreshold() {
        // 连续约 12 分钟读不到功率（电量计长时间不给读数）→ 累计跨过门槛。
        var samples = [sample(at: date(2026, 10, 3, 10, 0, 0), power: nil)]
        for index in 1...140 {
            samples.append(sample(at: date(2026, 10, 3, 10, 0, index * 5), power: nil))
        }

        let report = EnergyCalculator.unaccountedSecondsByDay(samples: samples, calendar: calendar)
        let today = report["2026-10-03"]

        XCTAssertEqual(today?.missingReadingSeconds ?? 0, 700, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(
            today?.missingReadingSeconds ?? 0,
            EnergyCalculator.missingReadingWarningSeconds
        )
        XCTAssertEqual(today?.needsWarning, true)
    }

    func testLongGapWarnsImmediately() {
        let samples = [
            sample(at: date(2026, 10, 3, 10, 0, 0), power: 20),
            sample(at: date(2026, 10, 3, 10, 5, 0), power: 20)
        ]

        let report = EnergyCalculator.unaccountedSecondsByDay(samples: samples, calendar: calendar)
        let today = report["2026-10-03"]

        // 间隔超过 maximumGap 说明当时应用没在记录，哪怕只有一段也立即告警。
        XCTAssertEqual(today?.gapSeconds ?? 0, 300, accuracy: 0.0001)
        XCTAssertEqual(today?.missingReadingSeconds ?? 0, 0, accuracy: 0.0001)
        XCTAssertEqual(today?.needsWarning, true)
    }

    func testExcludesSleepIntervals() {
        let samples = [
            sample(at: date(2026, 10, 3, 3, 0, 0), power: 20),
            sample(at: date(2026, 10, 3, 5, 0, 0), power: 20)
        ]
        let sleep = SleepInterval(
            start: date(2026, 10, 3, 3, 0, 0),
            end: date(2026, 10, 3, 5, 0, 0)
        )

        let report = EnergyCalculator.unaccountedSecondsByDay(
            samples: samples,
            calendar: calendar,
            excludedIntervals: [sleep]
        )

        XCTAssertTrue(report.isEmpty)
    }

    func testSplitsSecondsAcrossMidnight() {
        let samples = [
            sample(at: date(2026, 10, 3, 23, 59, 50), power: nil),
            sample(at: date(2026, 10, 4, 0, 0, 10), power: nil)
        ]

        let report = EnergyCalculator.unaccountedSecondsByDay(samples: samples, calendar: calendar)

        XCTAssertEqual(report["2026-10-03"]?.missingReadingSeconds ?? 0, 10, accuracy: 0.0001)
        XCTAssertEqual(report["2026-10-04"]?.missingReadingSeconds ?? 0, 10, accuracy: 0.0001)
    }

    func testDaySegmentsKeepsWithinDayIntervalWhole() {
        let segments = EnergyCalculator.daySegments(
            from: date(2026, 10, 3, 10, 0, 0),
            to: date(2026, 10, 3, 10, 0, 30),
            calendar: calendar
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].dayKey, "2026-10-03")
        XCTAssertEqual(segments[0].seconds, 30, accuracy: 0.0001)
    }
}
