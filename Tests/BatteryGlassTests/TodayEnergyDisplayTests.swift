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

        let clean = TodayEnergyDisplay(summary: summary, recordingEnabled: true)
        XCTAssertEqual(clean.energyKWh, 0.146)
        XCTAssertFalse(clean.needsAttention)
        XCTAssertNil(clean.warningText)
        XCTAssertEqual(clean.qualityLabel, "查看统计说明")

        summary.energyQuality = DailyEnergyQuality(hasEstimatedSleepEnergy: true)
        let warned = TodayEnergyDisplay(summary: summary, recordingEnabled: true)
        XCTAssertTrue(warned.needsAttention)
        XCTAssertTrue(warned.warningText?.contains("睡眠段为估算值") == true)
        XCTAssertEqual(warned.qualityLabel, "含估算")
    }

    func testMissingSummaryShowsNoValueAndNoWarning() {
        let display = TodayEnergyDisplay(summary: nil, recordingEnabled: true)
        XCTAssertNil(display.energyKWh)
        XCTAssertFalse(display.needsAttention)
        XCTAssertNil(display.warningText)
        XCTAssertEqual(display.qualityLabel, "暂无有效数据")
    }

    func testIncompleteRecordsTakePriorityOverEstimatesAndKeepAllReasons() {
        let quality = DailyEnergyQuality(hasSamplingGaps: true, hasEstimatedSleepEnergy: true)
        let display = TodayEnergyDisplay(summary: summary(quality: quality), recordingEnabled: true)

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
            let display = TodayEnergyDisplay(summary: summary(quality: quality), recordingEnabled: true)
            XCTAssertEqual(display.qualityLabel, label)
            XCTAssertEqual(display.needsAttention, needsAttention)
            XCTAssertNotNil(display.warningText)
        }
    }

    func testInvalidEnergyShowsNoValueInsteadOfANumberWithAUnit() {
        for energy in [nil, -0.1, Double.nan, Double.infinity] as [Double?] {
            var summary = summary()
            summary.energyKWh = energy
            let display = TodayEnergyDisplay(summary: summary, recordingEnabled: true)

            XCTAssertNil(display.energyKWh)
            XCTAssertEqual(display.qualityLabel, "暂无有效数据")
            XCTAssertTrue(display.needsAttention)
        }
        XCTAssertEqual(TodayEnergyDisplay(summary: summary(energy: 0), recordingEnabled: true).energyKWh, 0)
    }

    func testRecordingDisabledMarksTheValueAsStopped() {
        let display = TodayEnergyDisplay(summary: summary(), recordingEnabled: false)
        XCTAssertEqual(display.energyKWh, 0.177)
        XCTAssertTrue(display.needsAttention)
        XCTAssertEqual(display.qualityLabel, "记录已关闭")
        XCTAssertEqual(display.warningText, "历史记录已关闭，之后的使用未计入今日耗电")

        // 关闭前已经存在的质量原因不能因为显示「记录已关闭」而丢掉。
        let quality = DailyEnergyQuality(hasSamplingGaps: true)
        let combined = TodayEnergyDisplay(summary: summary(quality: quality), recordingEnabled: false)
        XCTAssertEqual(combined.qualityLabel, "记录已关闭")
        XCTAssertTrue(combined.needsAttention)
        XCTAssertTrue(combined.warningText?.contains("历史记录已关闭") == true)
        XCTAssertTrue(combined.warningText?.contains("采样断点") == true)

        // 关闭后没有当天数据：仍显示占位符，但说明里要给出原因。
        let empty = TodayEnergyDisplay(summary: nil, recordingEnabled: false)
        XCTAssertNil(empty.energyKWh)
        XCTAssertEqual(empty.qualityLabel, "暂无有效数据")
        XCTAssertFalse(empty.needsAttention)
        XCTAssertEqual(empty.warningText, "历史记录已关闭，之后的使用未计入今日耗电")

        // 开着记录时行为不变。
        let enabled = TodayEnergyDisplay(summary: summary(), recordingEnabled: true)
        XCTAssertFalse(enabled.needsAttention)
        XCTAssertNil(enabled.warningText)
        XCTAssertEqual(enabled.qualityLabel, "查看统计说明")
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
