import Foundation
import XCTest
@testable import BatteryGlass

final class TodayEnergyDisplayTests: XCTestCase {
    func testSummaryMapsValueAndAttention() {
        var summary = DailySummary(
            dayKey: "2026-10-28",
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            sampleCount: 120,
            maxCycleCount: 195,
            minHealthPercent: 82,
            energyKWh: 0.146,
            averagePower: 12,
            maxPower: 28,
            minPower: 3
        )

        let clean = TodayEnergyDisplay(summary: summary)
        XCTAssertEqual(clean.energyKWh, 0.146)
        XCTAssertFalse(clean.needsAttention)
        XCTAssertNil(clean.warningText)

        summary.energyQuality = DailyEnergyQuality(hasEstimatedSleepEnergy: true)
        let warned = TodayEnergyDisplay(summary: summary)
        XCTAssertTrue(warned.needsAttention)
        XCTAssertTrue(warned.warningText?.contains("睡眠段为估算值") == true)
    }

    func testMissingSummaryShowsNoValueAndNoWarning() {
        let display = TodayEnergyDisplay(summary: nil)
        XCTAssertNil(display.energyKWh)
        XCTAssertFalse(display.needsAttention)
        XCTAssertNil(display.warningText)
    }
}
