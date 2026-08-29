import Foundation
import XCTest
@testable import BatteryGlass

final class DailyEnergySummaryPolicyTests: XCTestCase {
    func testRecoveryOnlyRecalculatesAllowedDays() {
        let yesterday = summary(dayKey: "2026-08-27", energy: 3.25, sampleCount: 1)
        let today = summary(dayKey: "2026-08-28", energy: 0.5, sampleCount: 10)

        let result = DailyEnergySummaryPolicy.reconcile(
            summaries: [yesterday, today],
            recalculatedEnergy: [
                "2026-08-27": 0.001,
                "2026-08-28": 1.25
            ],
            allowedDayKeys: ["2026-08-28"]
        )

        XCTAssertEqual(result.first?.energyKWh, 3.25)
        XCTAssertEqual(result.last?.energyKWh, 1.25)
    }

    func testSparseLegacySummaryIsMarkedIncomplete() {
        let sparse = summary(dayKey: "2026-08-27", energy: 0.0001, sampleCount: 1)
        let normal = summary(dayKey: "2026-08-28", energy: 0.25, sampleCount: 10)

        let result = DailyEnergySummaryPolicy.markSparseLegacySummariesIncomplete(
            [sparse, normal],
            todayKey: "2026-08-28"
        )

        XCTAssertNil(result.first?.energyKWh)
        XCTAssertEqual(result.last?.energyKWh, 0.25)
    }

    func testSummaryRetentionKeepsAllDays() {
        let oldSummary = summary(dayKey: "2020-01-01", energy: 1, sampleCount: 10)

        XCTAssertEqual(
            DailyEnergySummaryPolicy.retainedSummaries([oldSummary]),
            [oldSummary]
        )
    }

    private func summary(dayKey: String, energy: Double, sampleCount: Int) -> DailySummary {
        DailySummary(
            dayKey: dayKey,
            date: Date(timeIntervalSince1970: 0),
            sampleCount: sampleCount,
            maxCycleCount: 1,
            minHealthPercent: 100,
            energyKWh: energy,
            averagePower: 20,
            maxPower: 20,
            minPower: 20
        )
    }
}
