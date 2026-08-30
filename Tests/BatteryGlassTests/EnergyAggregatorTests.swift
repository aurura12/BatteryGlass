import Foundation
import XCTest
@testable import BatteryGlass

final class EnergyAggregatorTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // 周一为一周开始
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func summary(dayKey: String, energyKWh: Double?) -> DailySummary {
        DailySummary(
            dayKey: dayKey,
            date: BatteryFormatters.dayKeyDate(dayKey) ?? Date(),
            sampleCount: 1,
            maxCycleCount: 0,
            minHealthPercent: nil,
            energyKWh: energyKWh,
            averagePower: 0,
            maxPower: 0,
            minPower: 0
        )
    }

    func testDayGroupingKeepsPerDayValues() {
        let summaries = [
            summary(dayKey: "2026-08-30", energyKWh: 0.1),
            summary(dayKey: "2026-08-31", energyKWh: 0.2)
        ]
        let aggregates = EnergyAggregator.aggregate(summaries: summaries, grouping: .day, calendar: calendar)

        XCTAssertEqual(aggregates.count, 2)
        XCTAssertEqual(aggregates[0].energyKWh, 0.1, accuracy: 0.0001)
        XCTAssertEqual(aggregates[1].energyKWh, 0.2, accuracy: 0.0001)
    }

    func testWeekGroupingMergesSameWeek() {
        // 2026-08-31 是周一（新一周开始），2026-08-30 是周日（上一周）。
        let summaries = [
            summary(dayKey: "2026-08-28", energyKWh: 0.1), // 周五
            summary(dayKey: "2026-08-30", energyKWh: 0.2), // 周日，同一周
            summary(dayKey: "2026-08-31", energyKWh: 0.3)  // 周一，新一周
        ]
        let aggregates = EnergyAggregator.aggregate(summaries: summaries, grouping: .week, calendar: calendar)

        XCTAssertEqual(aggregates.count, 2)
        XCTAssertEqual(aggregates[0].energyKWh, 0.3, accuracy: 0.0001)
        XCTAssertEqual(aggregates[1].energyKWh, 0.3, accuracy: 0.0001)
    }

    func testMonthGroupingMergesSameMonth() {
        let summaries = [
            summary(dayKey: "2026-08-01", energyKWh: 0.1),
            summary(dayKey: "2026-08-31", energyKWh: 0.2),
            summary(dayKey: "2026-09-01", energyKWh: 0.3)
        ]
        let aggregates = EnergyAggregator.aggregate(summaries: summaries, grouping: .month, calendar: calendar)

        XCTAssertEqual(aggregates.count, 2)
        XCTAssertEqual(aggregates[0].title, "2026-08")
        XCTAssertEqual(aggregates[0].energyKWh, 0.3, accuracy: 0.0001)
        XCTAssertEqual(aggregates[1].title, "2026-09")
    }

    func testSkipsSummariesWithoutEnergy() {
        let summaries = [
            summary(dayKey: "2026-08-30", energyKWh: nil),
            summary(dayKey: "2026-08-31", energyKWh: 0.5)
        ]
        let aggregates = EnergyAggregator.aggregate(summaries: summaries, grouping: .day, calendar: calendar)

        XCTAssertEqual(aggregates.count, 1)
        XCTAssertEqual(aggregates[0].energyKWh, 0.5, accuracy: 0.0001)
    }

    func testNearestAggregateSelectsClosestPeriod() {
        let aggregates = [
            EnergyAggregate(periodStart: BatteryFormatters.dayKeyDate("2026-08-01")!, title: "A", energyKWh: 1),
            EnergyAggregate(periodStart: BatteryFormatters.dayKeyDate("2026-08-08")!, title: "B", energyKWh: 2)
        ]
        // 08-03 距 08-01（2 天）比距 08-08（5 天）更近。
        let date = BatteryFormatters.dayKeyDate("2026-08-03")!
        XCTAssertEqual(EnergyAggregator.nearestAggregate(to: date, from: aggregates)?.title, "A")
    }
}
