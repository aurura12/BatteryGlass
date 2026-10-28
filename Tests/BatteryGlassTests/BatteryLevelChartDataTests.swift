import Foundation
import XCTest
@testable import BatteryGlass

final class BatteryLevelChartDataTests: XCTestCase {
    // MARK: - BatteryLevelChartData

    func testKeepsSamplesWithNilConsumptionPower() {
        // 与 PowerChartData 的关键差异：电量曲线不得因 consumptionPowerW 为空而丢点。
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<4).map { index in
            HistorySample(
                timestamp: first.addingTimeInterval(Double(index)),
                power: 20,
                consumptionPowerW: nil,
                percent: Double(50 + index),
                cycleCount: 1,
                healthPercent: 100
            )
        }

        let data = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 10)

        XCTAssertEqual(data.samples.count, 4)
        XCTAssertEqual(data.displayedSamples.count, 4)
        XCTAssertEqual(data.displayedSamples.map(\.percent), [50, 51, 52, 53])
    }

    func testDownsamplesToLimitPreservingFirstAndLast() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<1_000).map { index in
            sample(at: first.addingTimeInterval(Double(index)), percent: Double(index % 100))
        }

        let data = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 800)

        XCTAssertEqual(data.displayedSamples.count, 800)
        XCTAssertEqual(data.displayedSamples.first?.timestamp, samples.first?.timestamp)
        XCTAssertEqual(data.displayedSamples.last?.timestamp, samples.last?.timestamp)
    }

    func testDownsampledDailySeriesKeepsItsOriginalContinuousRun() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<1_440).map { index in
            sample(
                at: first.addingTimeInterval(Double(index) * 60),
                percent: Double(50 + index % 5)
            )
        }

        let data = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 240)

        XCTAssertEqual(data.displayedSamples.count, 240)
        XCTAssertEqual(data.displayedSegments.count, 1)
        // The selected points are more than five minutes apart, so re-running gap detection
        // on the downsampled array would incorrectly turn this real continuous run into dots.
        XCTAssertGreaterThan(PowerChartSegmentation.splitByGaps(data.displayedSamples).count, 1)
        XCTAssertEqual(data.displayedSegments[0].first?.timestamp, samples.first?.timestamp)
        XCTAssertEqual(data.displayedSegments[0].last?.timestamp, samples.last?.timestamp)
    }

    func testContinuousDayProducesSingleSegmentForConnectedArea() {
        // 锁定整段连续输入必须落到一个 `displayedSegments`：
        // `TodayBatteryLevelChart` 的 `AreaMark` / `LineMark` 共享同一 `series`
        // 才能被 Swift Charts 合并为一条连续填充区域，否则密集样本会被画成
        // 独立竖条（"梳齿"），见 `HistoryBatteryLevelChart.swift`
        // 注释。
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = stride(from: 0.0, to: 43_200, by: 5).map { offset in
            sample(at: start.addingTimeInterval(offset), percent: 70)
        }

        let data = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 800)

        XCTAssertEqual(data.displayedSegments.count, 1, "整段连续输入必须落在单个 segment 以便 AreaMark series 合并")
        XCTAssertEqual(data.displayedSamples.count, 800)
    }

    func testKeepsAllSamplesUnderLimit() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<5).map { index in
            sample(at: first.addingTimeInterval(Double(index)), percent: 60)
        }

        let data = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 800)

        XCTAssertEqual(data.displayedSamples, data.samples)
    }

    func testCapBoundaryExactlyAtLimitKeepsAll() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<3).map { index in
            sample(at: first.addingTimeInterval(Double(index)), percent: 40)
        }

        let data = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 3)

        XCTAssertEqual(data.displayedSamples, data.samples)
    }

    func testEmptyInputProducesEmptyData() {
        let data = BatteryLevelChartData(samples: [], maximumDisplayedSamples: 800)

        XCTAssertTrue(data.samples.isEmpty)
        XCTAssertTrue(data.displayedSamples.isEmpty)
        XCTAssertEqual(data.percentDomain, 0...100)
    }

    func testPercentDomainUsesFullSamplesNotDownsampled() {
        // cap=2 时抽样只保留首尾（下标 0 与 4），把极值放在会被丢弃的下标，
        // domain 仍应覆盖 0…100。
        let first = Date(timeIntervalSince1970: 1_000)
        var samples = (0..<5).map { index in
            sample(at: first.addingTimeInterval(Double(index)), percent: 50)
        }
        samples[1] = sample(at: samples[1].timestamp, percent: 0)
        samples[2] = sample(at: samples[2].timestamp, percent: 100)

        let data = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 2)

        XCTAssertEqual(data.displayedSamples.count, 2)
        XCTAssertTrue(data.displayedSamples.allSatisfy { $0.percent == 50 })
        XCTAssertEqual(data.percentDomain, 0...100)
    }

    // MARK: - HistoryChartRendering.gapBridges

    func testGapBridgesConnectAdjacentSegmentsWithRealSamples() {
        // 待机缺口两侧的实测样本必须成为细连接线的端点，中间不补任何点。
        let first = Date(timeIntervalSince1970: 1_000)
        let a = sample(at: first, percent: 84)
        let b = sample(at: first.addingTimeInterval(60), percent: 84)
        let c = sample(at: first.addingTimeInterval(1_800), percent: 53)
        let d = sample(at: first.addingTimeInterval(3_600), percent: 58)

        let bridges = HistoryChartRendering.gapBridges([[a, b], [c, d]])

        XCTAssertEqual(bridges.count, 1)
        XCTAssertEqual(bridges.first?.start, b)
        XCTAssertEqual(bridges.first?.end, c)
    }

    func testGapBridgesIgnoreSingleSegment() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = [sample(at: first, percent: 70), sample(at: first.addingTimeInterval(5), percent: 70)]

        XCTAssertTrue(HistoryChartRendering.gapBridges([samples]).isEmpty)
        XCTAssertTrue(HistoryChartRendering.gapBridges([]).isEmpty)
        XCTAssertTrue(HistoryChartRendering.gapBridges([[]]).isEmpty)
    }

    func testGapBridgesSkipNonAdvancingSegments() {
        let first = Date(timeIntervalSince1970: 1_000)
        let a = sample(at: first, percent: 50)
        let b = sample(at: first, percent: 60)

        XCTAssertTrue(HistoryChartRendering.gapBridges([[a], [b]]).isEmpty)
    }

    // MARK: - BatteryLevelAxis.yDomain

    func testYDomainFallsBackToZeroToHundredWhenEmpty() {
        XCTAssertEqual(BatteryLevelAxis.yDomain(for: []), 0...100)
    }

    func testYDomainAddsPaddingAroundRange() {
        XCTAssertEqual(BatteryLevelAxis.yDomain(for: [20, 80]), 14...86)
    }

    func testYDomainEnforcesMinimumSpanForFlatLine() {
        let domain = BatteryLevelAxis.yDomain(for: [80, 80])

        XCTAssertEqual(domain, 74...86)
        XCTAssertGreaterThanOrEqual(domain.upperBound - domain.lowerBound, 10)
    }

    func testYDomainSlidesWindowAtLowerBound() {
        XCTAssertEqual(BatteryLevelAxis.yDomain(for: [2]), 0...12)
    }

    func testYDomainSlidesWindowAtUpperBound() {
        XCTAssertEqual(BatteryLevelAxis.yDomain(for: [99]), 88...100)
    }

    func testYDomainFullRangeStaysZeroToHundred() {
        XCTAssertEqual(BatteryLevelAxis.yDomain(for: [0, 100]), 0...100)
    }

    func testYDomainIgnoresNonFiniteValues() {
        XCTAssertEqual(BatteryLevelAxis.yDomain(for: [.nan, 50]), 44...56)
    }

    // MARK: - BatteryLevelAxis.xDomain

    func testXDomainStartsAtLocalMidnightAndEndsAtNow() {
        let calendar = gmtCalendar()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let startOfDay = calendar.startOfDay(for: now)

        let domain = BatteryLevelAxis.xDomain(now: now, calendar: calendar)

        XCTAssertEqual(domain.lowerBound, startOfDay)
        XCTAssertEqual(domain.upperBound, now)
    }

    func testXDomainGuardsDegenerateWidthAtMidnight() {
        let calendar = gmtCalendar()
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

        let domain = BatteryLevelAxis.xDomain(now: midnight, calendar: calendar)

        XCTAssertEqual(domain.lowerBound, midnight)
        XCTAssertGreaterThanOrEqual(
            domain.upperBound.timeIntervalSince(domain.lowerBound),
            60
        )
    }

    // MARK: - 可见域 Y 轴（缩放）

    func testVisibleYDomainAtFullRangeEqualsPrecomputedDomain() {
        // 未缩放时可见样本就是全量样本，动态 Y 域必须与预计算域逐值相等，
        // 保证加缩放不影响默认外观。
        let calendar = gmtCalendar()
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let samples = (0..<120).map { index in
            sample(
                at: start.addingTimeInterval(Double(index) * 600),
                percent: Double(40 + index % 25)
            )
        }
        let data = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 800)
        let domain = BatteryLevelAxis.xDomain(now: samples.last!.timestamp, calendar: calendar)

        let visible = ChartViewport.visibleSamples(data.samples, in: domain)

        XCTAssertEqual(visible.count, data.samples.count)
        XCTAssertEqual(BatteryLevelAxis.yDomain(for: visible.map(\.percent)), data.percentDomain)
    }

    func testZoomedVisibleYDomainIsNarrowerThanFullDay() {
        let calendar = gmtCalendar()
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let samples = (0..<288).map { index in
            let percent = index < 72
                ? Double(40 + index % 10)
                : Double(80 + index % 10)
            return sample(at: start.addingTimeInterval(Double(index) * 300), percent: percent)
        }
        let data = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 800)

        let zoomedVisible = ChartViewport.visibleSamples(
            data.samples,
            in: start...start.addingTimeInterval(6 * 3_600)
        )
        let zoomedDomain = BatteryLevelAxis.yDomain(for: zoomedVisible.map(\.percent))

        XCTAssertLessThan(
            zoomedDomain.upperBound - zoomedDomain.lowerBound,
            data.percentDomain.upperBound - data.percentDomain.lowerBound
        )
    }

    func testXDomainDefaultUnchanged() {
        let calendar = gmtCalendar()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let domain = BatteryLevelAxis.xDomain(now: now, calendar: calendar)

        XCTAssertEqual(domain.lowerBound, calendar.startOfDay(for: now))
        XCTAssertEqual(domain.upperBound, now)
    }

    func testXDomainPastDaySpansFullDayWithoutSamples() {
        let calendar = gmtCalendar()
        let today = date("2026-08-27 12:00:00")
        let pastDay = date("2026-08-26 00:00:00")

        let domain = BatteryLevelAxis.xDomain(
            day: pastDay,
            now: today,
            lastSample: nil,
            calendar: calendar
        )

        XCTAssertEqual(domain.lowerBound, pastDay)
        XCTAssertEqual(domain.upperBound, date("2026-08-27 00:00:00"))
    }

    func testXDomainPastDayEndsAtLastSample() {
        let calendar = gmtCalendar()
        let today = date("2026-08-27 12:00:00")
        let pastDay = date("2026-08-26 00:00:00")
        let lastSample = date("2026-08-26 23:30:00")

        let domain = BatteryLevelAxis.xDomain(
            day: pastDay,
            now: today,
            lastSample: lastSample,
            calendar: calendar
        )

        XCTAssertEqual(domain.upperBound, lastSample)
    }

    func testXDomainPastDayKeepsMinimumWidth() {
        let calendar = gmtCalendar()
        let today = date("2026-08-27 12:00:00")
        let pastDay = date("2026-08-26 00:00:00")
        let lastSample = date("2026-08-26 00:00:00")

        let domain = BatteryLevelAxis.xDomain(
            day: pastDay,
            now: today,
            lastSample: lastSample,
            calendar: calendar
        )

        XCTAssertGreaterThanOrEqual(
            domain.upperBound.timeIntervalSince(domain.lowerBound),
            60
        )
    }

    func testXDomainTodayKeepsMinimumWidthAtMidnight() {
        let calendar = gmtCalendar()
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

        let domain = BatteryLevelAxis.xDomain(
            day: midnight,
            now: midnight,
            lastSample: midnight,
            calendar: calendar
        )

        XCTAssertGreaterThanOrEqual(
            domain.upperBound.timeIntervalSince(domain.lowerBound),
            60
        )
    }

    // MARK: - Helpers

    private func sample(at timestamp: Date, percent: Double) -> HistorySample {
        HistorySample(
            timestamp: timestamp,
            power: 20,
            consumptionPowerW: 20,
            percent: percent,
            cycleCount: 1,
            healthPercent: 100
        )
    }

    private func gmtCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }
}
