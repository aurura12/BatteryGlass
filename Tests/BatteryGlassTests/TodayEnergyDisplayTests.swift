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
        XCTAssertEqual(clean.qualityLabel, "查看统计说明")

        summary.energyQuality = DailyEnergyQuality(hasEstimatedSleepEnergy: true)
        let warned = TodayEnergyDisplay(summary: summary)
        XCTAssertTrue(warned.needsAttention)
        XCTAssertTrue(warned.warningText?.contains("睡眠段为估算值") == true)
        XCTAssertEqual(warned.qualityLabel, "含估算")
    }

    func testMissingSummaryShowsNoValueAndNoWarning() {
        let display = TodayEnergyDisplay(summary: nil)
        XCTAssertNil(display.energyKWh)
        XCTAssertFalse(display.needsAttention)
        XCTAssertNil(display.warningText)
        XCTAssertEqual(display.qualityLabel, "暂无有效数据")
    }

    func testIncompleteRecordsTakePriorityOverEstimatesAndKeepAllReasons() {
        let quality = DailyEnergyQuality(hasSamplingGaps: true, hasEstimatedSleepEnergy: true)
        let display = TodayEnergyDisplay(summary: summary(quality: quality))

        XCTAssertEqual(display.qualityLabel, "记录不完整")
        XCTAssertTrue(display.needsAttention)
        XCTAssertTrue(display.warningText?.contains("采样断点") == true)
        XCTAssertTrue(display.warningText?.contains("睡眠段为估算值") == true)
    }

    func testQualityLabelsDistinguishMissingSleepCalibrationAndLegacyData() {
        let cases: [(DailyEnergyQuality, String, Bool)] = [
            (.init(hasUnmeasuredSleepEnergy: true), "记录不完整", true),
            (.init(hasLowerBoundSleepEnergy: true), "记录不完整", true),
            (.init(hasUncalibratedCounterEnergy: true), "未校准", true),
            (.init(hasUnknownHistoricalCoverage: true), "旧版记录", false)
        ]

        for (quality, label, needsAttention) in cases {
            let display = TodayEnergyDisplay(summary: summary(quality: quality))
            XCTAssertEqual(display.qualityLabel, label)
            XCTAssertEqual(display.needsAttention, needsAttention)
            XCTAssertNotNil(display.warningText)
        }
    }

    func testInvalidEnergyShowsNoValueInsteadOfANumberWithAUnit() {
        for energy in [nil, -0.1, Double.nan, Double.infinity] as [Double?] {
            var summary = summary()
            summary.energyKWh = energy
            let display = TodayEnergyDisplay(summary: summary)

            XCTAssertNil(display.energyKWh)
            XCTAssertEqual(display.qualityLabel, "暂无有效数据")
            XCTAssertTrue(display.needsAttention)
        }
        XCTAssertEqual(TodayEnergyDisplay(summary: summary(energy: 0)).energyKWh, 0)
    }

    private func summary(energy: Double = 0.177, quality: DailyEnergyQuality? = nil) -> DailySummary {
        DailySummary(
            dayKey: "2026-10-28",
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            sampleCount: 120,
            maxCycleCount: 195,
            minHealthPercent: 82,
            energyKWh: energy,
            averagePower: 29,
            maxPower: 29.5,
            minPower: 22.3,
            energyQuality: quality
        )
    }
}
