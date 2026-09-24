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
}
