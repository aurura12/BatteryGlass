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

    // MARK: - AxisTickScale

    func testChartDataAxisTicksMatchValueDomain() {
        let data = TodayMetricChartData(
            samples: [sample(offset: 0, temperature: 30.5), sample(offset: 5, temperature: 30.8)],
            metric: .temperature
        )

        XCTAssertEqual(data.axisTicks.domain, data.valueDomain)
        XCTAssertFalse(data.axisTicks.labels.isEmpty)
    }

    /// 当日温度跨度很小时，固定取整会让刻度全变成 "31"。
    func testNarrowTemperatureDomainKeepsLabelsDistinct() {
        let scale = MetricValueAxis.ticks(in: 30.47...30.83)

        XCTAssertEqual(scale.fractionDigits, 1)
        XCTAssertEqual(scale.labels, ["30.5", "30.6", "30.7", "30.8"])
    }

    /// 当日电压跨度很小时，固定 1 位小数会让刻度全变成 "12.7"。
    func testNarrowVoltageDomainKeepsLabelsDistinct() {
        let scale = MetricValueAxis.ticks(in: 12.667...12.703)

        XCTAssertEqual(scale.fractionDigits, 2)
        XCTAssertEqual(scale.labels, ["12.67", "12.68", "12.69", "12.70"])
    }

    func testWideDomainUsesNiceStep() {
        let scale = MetricValueAxis.ticks(in: 18...42)

        XCTAssertEqual(scale.fractionDigits, 0)
        XCTAssertEqual(scale.labels, ["20", "25", "30", "35", "40"])
    }

    /// 平线温度经 `yDomain` 扩到 29.26…32.34 后仍需得到整数刻度。
    func testFlatTemperatureDomainUsesIntegerTicks() {
        let scale = MetricValueAxis.ticks(in: MetricValueAxis.yDomain(for: [30.8]))

        XCTAssertEqual(scale.fractionDigits, 0)
        XCTAssertEqual(scale.labels, ["30", "31", "32"])
    }

    /// 耗电量柱图：0.0x kWh 量级的刻度也必须互不重复（原先固定 %.1f 会全显示 "0.0"）。
    func testEnergyScaleLabelsAreDistinct() {
        let scale = MetricValueAxis.ticks(in: 0...0.088)

        XCTAssertEqual(scale.fractionDigits, 2)
        XCTAssertEqual(scale.labels, ["0.00", "0.02", "0.04", "0.06", "0.08"])
    }

    func testTicksStayInsideDomainAndAscending() {
        let domains: [ClosedRange<Double>] = [
            0...1, 18...42, 30.47...30.83, 12.667...12.703, 95...105,
            0...0.088, 0...3.7, 29.26...32.34, (-20)...(-5)
        ]

        for domain in domains {
            let scale = MetricValueAxis.ticks(in: domain)
            XCTAssertTrue((3...5).contains(scale.values.count), "域 \(domain) 刻度数量异常")
            XCTAssertEqual(scale.values, scale.values.sorted(), "域 \(domain) 刻度未升序")
            for value in scale.values {
                XCTAssertTrue(domain.contains(value), "域 \(domain) 的刻度 \(value) 越界")
            }
            XCTAssertEqual(
                Set(scale.labels).count,
                scale.values.count,
                "域 \(domain) 出现重复刻度标签 \(scale.labels)"
            )
        }
    }

    func testFractionDigitsFollowsStep() {
        XCTAssertEqual(MetricValueAxis.fractionDigits(forStep: 0.005), 3)
        XCTAssertEqual(MetricValueAxis.fractionDigits(forStep: 0.01), 2)
        XCTAssertEqual(MetricValueAxis.fractionDigits(forStep: 0.05), 2)
        XCTAssertEqual(MetricValueAxis.fractionDigits(forStep: 0.2), 1)
        XCTAssertEqual(MetricValueAxis.fractionDigits(forStep: 0.5), 1)
        XCTAssertEqual(MetricValueAxis.fractionDigits(forStep: 1), 0)
        XCTAssertEqual(MetricValueAxis.fractionDigits(forStep: 5), 0)
        XCTAssertEqual(MetricValueAxis.fractionDigits(forStep: 10), 0)
    }

    func testDegenerateDomainDoesNotCrash() {
        // 零宽值域（`ClosedRange` 不允许 nan 边界，故只覆盖宽度为 0 的退化情形）。
        let empty = MetricValueAxis.ticks(in: 5...5)
        XCTAssertTrue(empty.values.isEmpty)
        XCTAssertEqual(empty.domain, 5...5)
    }

    // MARK: - 可见域 Y 轴（缩放）

    func testVisibleMetricDomainAtFullRangeEqualsFullDayDomain() {
        // 未缩放时可见样本就是全量样本，动态 Y 域必须与预计算域一致。
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let samples = (0..<120).map { index in
            HistorySample(
                timestamp: start.addingTimeInterval(Double(index) * 600),
                power: 10,
                percent: 50,
                cycleCount: 1,
                healthPercent: 100,
                temperatureCelsius: Double(30 + index % 12)
            )
        }
        let data = TodayMetricChartData(samples: samples, metric: .temperature)
        let domain = BatteryLevelAxis.xDomain(now: samples.last!.timestamp, calendar: calendar)

        let visible = ChartViewport.visibleSamples(data.samples, in: domain)
        let dynamicDomain = MetricValueAxis.yDomain(
            for: visible.compactMap(\.temperatureCelsius)
        )

        XCTAssertEqual(visible.count, data.samples.count)
        XCTAssertEqual(dynamicDomain, data.valueDomain)
    }

    func testZoomedVisibleMetricDomainNarrows() {
        let samples = (0..<288).map { index in
            let temperature = index < 72
                ? Double(30 + index % 4)
                : Double(60 + index % 4)
            return sample(offset: Double(index) * 300, temperature: temperature)
        }
        let data = TodayMetricChartData(samples: samples, metric: .temperature)

        let zoomed = ChartViewport.visibleSamples(
            data.samples,
            in: Date(timeIntervalSince1970: 1_700_000_000)...Date(timeIntervalSince1970: 1_700_000_000 + 6 * 3_600)
        )
        let dynamicDomain = MetricValueAxis.yDomain(for: zoomed.compactMap(\.temperatureCelsius))

        XCTAssertLessThan(
            dynamicDomain.upperBound - dynamicDomain.lowerBound,
            data.valueDomain.upperBound - data.valueDomain.lowerBound
        )
    }
}
