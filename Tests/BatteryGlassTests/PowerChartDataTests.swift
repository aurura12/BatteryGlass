import Foundation
import XCTest
@testable import BatteryGlass

final class PowerChartDataTests: XCTestCase {
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
}
