import Foundation
import XCTest
@testable import BatteryGlass

final class HistoryMetricChartDataTests: XCTestCase {
    private func sample(
        offset: TimeInterval,
        temperature: Double? = nil,
        voltage: Double? = nil
    ) -> HistorySample {
        HistorySample(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            power: 10,
            percent: 50,
            cycleCount: 1,
            healthPercent: 100,
            temperatureCelsius: temperature,
            voltage: voltage
        )
    }

    private func summary(dayOffset: Int, sampleCount: Int, maxCycleCount: Int) -> DailySummary {
        DailySummary(
            dayKey: "2026-08-\(String(format: "%02d", dayOffset + 1))",
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(dayOffset) * 86_400),
            sampleCount: sampleCount,
            maxCycleCount: maxCycleCount,
            minHealthPercent: nil,
            energyKWh: nil,
            averagePower: 0,
            maxPower: 0,
            minPower: 0
        )
    }

    // MARK: - TodayMetricChartData

    func testTemperatureMetricFiltersSamplesWithoutValue() {
        let data = TodayMetricChartData(
            samples: [
                sample(offset: 0, temperature: 30),
                sample(offset: 5),
                sample(offset: 10, temperature: 35)
            ],
            metric: .temperature
        )

        XCTAssertEqual(data.samples.count, 2)
        XCTAssertEqual(data.samples.compactMap(\.temperatureCelsius), [30, 35])
        XCTAssertEqual(data.valueDomain, 29.5...35.5)
    }

    func testVoltageMetricFiltersSamplesWithoutValue() {
        let data = TodayMetricChartData(
            samples: [
                sample(offset: 0, voltage: 12),
                sample(offset: 5, temperature: 30),
                sample(offset: 10, voltage: 13)
            ],
            metric: .voltage
        )

        XCTAssertEqual(data.samples.count, 2)
        XCTAssertEqual(data.valueDomain, 11.9...13.1)
    }

    func testChartDataDownsamplesKeepingFirstAndLast() {
        let samples = (0..<10).map { sample(offset: Double($0) * 5, temperature: Double(30 + $0)) }
        let data = TodayMetricChartData(samples: samples, metric: .temperature, maximumDisplayedSamples: 4)

        XCTAssertEqual(data.samples.count, 10)
        XCTAssertEqual(data.displayedSamples.count, 4)
        XCTAssertEqual(data.displayedSamples.first?.timestamp, samples.first?.timestamp)
        XCTAssertEqual(data.displayedSamples.last?.timestamp, samples.last?.timestamp)
    }

    func testChartDataEmptyWhenNoMetricValues() {
        let data = TodayMetricChartData(samples: [sample(offset: 0)], metric: .temperature)

        XCTAssertTrue(data.samples.isEmpty)
        XCTAssertTrue(data.displayedSamples.isEmpty)
        XCTAssertEqual(data.valueDomain, 0...1)
    }

    // MARK: - MetricValueAxis

    func testYDomainEmptyFallsBackToUnitRange() {
        XCTAssertEqual(MetricValueAxis.yDomain(for: []), 0...1)
    }

    func testYDomainFlatLineAddsPadding() {
        XCTAssertEqual(MetricValueAxis.yDomain(for: [100, 100]), 95...105)
    }

    func testYDomainPadsTenPercentOfSpan() {
        XCTAssertEqual(MetricValueAxis.yDomain(for: [20, 40]), 18...42)
    }

    func testYDomainIgnoresNonFiniteValues() {
        XCTAssertEqual(MetricValueAxis.yDomain(for: [.nan, 20, 40, .infinity]), 18...42)
    }

    // MARK: - CycleTrendData

    func testCycleTrendSkipsDaysWithoutOrdinarySamples() {
        let data = CycleTrendData(summaries: [
            summary(dayOffset: 0, sampleCount: 120, maxCycleCount: 10),
            // 仅由睡眠能量创建的汇总：sampleCount == 0，maxCycleCount 为 0 不是真实循环数。
            summary(dayOffset: 1, sampleCount: 0, maxCycleCount: 0),
            summary(dayOffset: 2, sampleCount: 30, maxCycleCount: 12)
        ])

        XCTAssertEqual(data.entries.map(\.dayKey), ["2026-08-01", "2026-08-03"])
        XCTAssertEqual(data.latest, 12)
    }

    func testCycleTrendCapsToLimitKeepingLatest() {
        let summaries = (0..<5).map { summary(dayOffset: $0, sampleCount: 10, maxCycleCount: 100 + $0) }
        let data = CycleTrendData(summaries: summaries, limit: 3)

        XCTAssertEqual(data.entries.map(\.dayKey), ["2026-08-03", "2026-08-04", "2026-08-05"])
        XCTAssertEqual(data.latest, 104)
    }

    func testCycleTrendLatestNilWhenEmpty() {
        let data = CycleTrendData(summaries: [summary(dayOffset: 0, sampleCount: 0, maxCycleCount: 0)])
        XCTAssertTrue(data.entries.isEmpty)
        XCTAssertNil(data.latest)
    }

    // MARK: - TodayTemperatureStats

    func testTemperatureMaximum() {
        let samples = [
            sample(offset: 0, temperature: 30),
            sample(offset: 5, temperature: 38.4),
            sample(offset: 10)
        ]
        XCTAssertEqual(TodayTemperatureStats.maximum(in: samples) ?? 0, 38.4, accuracy: 0.0001)
        XCTAssertNil(TodayTemperatureStats.maximum(in: [sample(offset: 0)]))
    }

    func testTemperatureDurationAboveThresholdSkipsGapsAndCoolSamples() {
        let samples = [
            sample(offset: 0, temperature: 36),
            sample(offset: 5, temperature: 36),
            sample(offset: 10, temperature: 30),
            // 300 秒断点（待机等无采样）不应计入高温时长。
            sample(offset: 310, temperature: 36),
            sample(offset: 315, temperature: 36)
        ]

        let duration = TodayTemperatureStats.durationAbove(35, in: samples)
        XCTAssertEqual(duration, 15, accuracy: 0.0001)
    }
}
