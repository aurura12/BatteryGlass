import Foundation
import XCTest
@testable import BatteryGlass

final class PowerChartInteractionTests: XCTestCase {
    func testNearestSampleIsSelectedForHoverTime() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = [
            sample(at: first, power: 10),
            sample(at: first.addingTimeInterval(5), power: 20),
            sample(at: first.addingTimeInterval(10), power: 30)
        ]

        let nearest = PowerChartInteraction.nearestSample(
            to: first.addingTimeInterval(7),
            from: samples
        )

        XCTAssertEqual(nearest?.consumptionPowerW, 20)
    }

    func testNearestSampleHandlesHoverOutsideSampleRange() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = [
            sample(at: first, power: 10),
            sample(at: first.addingTimeInterval(5), power: 20)
        ]

        XCTAssertEqual(
            PowerChartInteraction.nearestSample(
                to: first.addingTimeInterval(-10),
                from: samples
            )?.consumptionPowerW,
            10
        )
        XCTAssertEqual(
            PowerChartInteraction.nearestSample(
                to: first.addingTimeInterval(20),
                from: samples
            )?.consumptionPowerW,
            20
        )
    }

    func testNearestDailySummarySelectsEnergyForHoveredDate() {
        let first = Date(timeIntervalSince1970: 1_000)
        let summaries = [
            summary(at: first, dayKey: "2026-08-28", energy: 0.136),
            summary(at: first.addingTimeInterval(86_400), dayKey: "2026-08-29", energy: 0.174),
            summary(at: first.addingTimeInterval(172_800), dayKey: "2026-08-30", energy: 0.238)
        ]

        let nearest = PowerChartInteraction.nearestDailySummary(
            to: first.addingTimeInterval(86_400 + 1_800),
            from: summaries
        )

        XCTAssertEqual(nearest?.dayKey, "2026-08-29")
        XCTAssertEqual(nearest?.energyKWh, 0.174)
    }

    func testDailyTooltipAnchorUsesTheHoveredBarsPlotCoordinates() {
        let plotFrame = CGRect(x: 24, y: 12, width: 300, height: 138)

        let anchor = PowerChartInteraction.dailyTooltipAnchor(
            plotFrame: plotFrame,
            xPosition: 180,
            yPosition: 42
        )

        XCTAssertEqual(anchor.x, 204)
        XCTAssertEqual(anchor.y, 54)
    }

    func testDailyEnergyMetricOrderPlacesAverageBeforeTotal() {
        XCTAssertEqual(
            DailyEnergyMetricOrder.titles,
            ["今日", "日均", "总计"]
        )
    }

    func testTotalDailyEnergySumsOnlyCompleteSummaries() {
        let first = Date(timeIntervalSince1970: 1_000)
        let summaries = [
            summary(at: first, dayKey: "2026-08-28", energy: 0.136),
            summary(at: first.addingTimeInterval(86_400), dayKey: "2026-08-29", energy: nil),
            summary(at: first.addingTimeInterval(172_800), dayKey: "2026-08-30", energy: 0.238)
        ]

        XCTAssertEqual(PowerChartInteraction.totalDailyEnergy(from: summaries), 0.374)
    }

    private func sample(at timestamp: Date, power: Double) -> HistorySample {
        HistorySample(
            timestamp: timestamp,
            power: power,
            consumptionPowerW: power,
            percent: 50,
            cycleCount: 1,
            healthPercent: 100
        )
    }

    private func summary(at date: Date, dayKey: String, energy: Double?) -> DailySummary {
        DailySummary(
            dayKey: dayKey,
            date: date,
            sampleCount: 1,
            maxCycleCount: 1,
            minHealthPercent: 100,
            energyKWh: energy,
            averagePower: 10,
            maxPower: 10,
            minPower: 10
        )
    }
}
