import Foundation
import XCTest
@testable import BatteryGlass

final class PowerChartDataTests: XCTestCase {
    func testInitialScrollDateShowsLatestTwoHoursWhenMoreDataExists() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = [
            historySample(at: first),
            historySample(at: first.addingTimeInterval(7_200)),
            historySample(at: first.addingTimeInterval(14_400))
        ]

        XCTAssertEqual(
            PowerChartWindow.initialScrollDate(for: samples),
            first.addingTimeInterval(7_200)
        )

        let bounds = PowerChartWindow.scrollBounds(for: samples)
        XCTAssertEqual(bounds?.start, first)
        XCTAssertEqual(bounds?.end, first.addingTimeInterval(7_200))
    }

    func testInitialScrollDateShowsAllDataWhenLessThanTwoHoursExists() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = [
            historySample(at: first),
            historySample(at: first.addingTimeInterval(3_600))
        ]

        XCTAssertEqual(PowerChartWindow.initialScrollDate(for: samples), first)

        let bounds = PowerChartWindow.scrollBounds(for: samples)
        XCTAssertEqual(bounds?.start, first)
        XCTAssertEqual(bounds?.end, first)
    }

    func testScrollFollowsLatestWhenUserIsAtPreviousEnd() {
        let previousEnd = Date(timeIntervalSince1970: 7_200)

        XCTAssertTrue(
            PowerChartWindow.shouldFollowLatest(
                currentPosition: previousEnd,
                previousEnd: previousEnd
            )
        )
    }

    func testScrollDoesNotFollowLatestAfterUserMovesToHistory() {
        let previousEnd = Date(timeIntervalSince1970: 7_200)
        let historyPosition = previousEnd.addingTimeInterval(-3_600)

        XCTAssertFalse(
            PowerChartWindow.shouldFollowLatest(
                currentPosition: historyPosition,
                previousEnd: previousEnd
            )
        )
    }

    func testVisibleDomainUsesCustomScrollPosition() {
        let start = date("2026-08-27 08:00:00")
        let position = start.addingTimeInterval(3_600)
        let latest = start.addingTimeInterval(14_400)

        let domain = PowerChartWindow.visibleDomain(
            startingAt: position,
            latest: latest
        )

        XCTAssertEqual(domain.lowerBound, position)
        XCTAssertEqual(domain.upperBound, position.addingTimeInterval(7_200))
    }

    func testChartDataFiltersMissingPowerAndDownsamplesToLimit() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<6).map { index in
            HistorySample(
                timestamp: first.addingTimeInterval(Double(index)),
                power: Double(index),
                consumptionPowerW: index.isMultiple(of: 2) ? Double(index) : nil,
                percent: 50,
                cycleCount: 1,
                healthPercent: 100
            )
        }

        let data = PowerChartData(samples: samples, maximumDisplayedSamples: 2)

        XCTAssertEqual(data.energySamples.map(\.consumptionPowerW), [0, 2, 4])
        XCTAssertEqual(data.chartSamples.map(\.consumptionPowerW), [0, 4])
    }

    func testChartDataKeepsAllSamplesWhenUnderLimit() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = [
            HistorySample(
                timestamp: first,
                power: 10,
                consumptionPowerW: 10,
                percent: 50,
                cycleCount: 1,
                healthPercent: 100
            ),
            HistorySample(
                timestamp: first.addingTimeInterval(5),
                power: 20,
                consumptionPowerW: 20,
                percent: 50,
                cycleCount: 1,
                healthPercent: 100
            )
        ]

        let data = PowerChartData(samples: samples, maximumDisplayedSamples: 10)

        XCTAssertEqual(data.chartSamples, data.energySamples)
    }

    func testChartSamplesExcludePointsOutsideVisibleDomain() {
        let start = Date(timeIntervalSince1970: 1_000)
        let domain = start...start.addingTimeInterval(10)
        let samples = [
            historySample(at: start.addingTimeInterval(-5)),
            historySample(at: start),
            historySample(at: start.addingTimeInterval(5)),
            historySample(at: start.addingTimeInterval(15))
        ]

        XCTAssertEqual(
            PowerChartWindow.samples(in: domain, from: samples).map(\.timestamp),
            [start, start.addingTimeInterval(5)]
        )
    }

    private func historySample(at timestamp: Date) -> HistorySample {
        HistorySample(
            timestamp: timestamp,
            power: 20,
            consumptionPowerW: 20,
            percent: 50,
            cycleCount: 1,
            healthPercent: 100
        )
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }
}
