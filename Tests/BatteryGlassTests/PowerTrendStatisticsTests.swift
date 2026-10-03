import Foundation
import XCTest
@testable import BatteryGlass

final class PowerTrendStatisticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testReadingsExpireAsCurrentTimeAdvancesWithoutNewSamples() {
        let samples = [PowerSample(timestamp: now, power: 25, percent: 50)]
        XCTAssertEqual(PowerTrendStatistics(samples: samples, now: now.addingTimeInterval(120)).peakPower, 25)
        let expired = PowerTrendStatistics(samples: samples, now: now.addingTimeInterval(121))
        XCTAssertNil(expired.peakPower)
        XCTAssertNil(expired.averagePower)
    }

    func testSparseOldSamplesAndFutureSamplesDoNotDistortCurrentStatistics() {
        let samples = [
            PowerSample(timestamp: now.addingTimeInterval(-600), power: 100, percent: 50),
            PowerSample(timestamp: now.addingTimeInterval(-120), power: 10, percent: 50),
            PowerSample(timestamp: now, power: 20, percent: 50),
            PowerSample(timestamp: now.addingTimeInterval(1), power: 200, percent: 50)
        ]
        let statistics = PowerTrendStatistics(samples: samples, now: now)
        XCTAssertEqual(statistics.peakPower, 20)
        XCTAssertEqual(statistics.averagePower, 15)
    }

    func testInvalidReadingsDoNotPoisonValidZeroAndPositiveMeasurements() {
        let samples = [Double.nan, Double.infinity, -20, 0, 10].map {
            PowerSample(timestamp: now, power: $0, percent: 50)
        }
        let statistics = PowerTrendStatistics(samples: samples, now: now)
        XCTAssertEqual(statistics.peakPower, 10)
        XCTAssertEqual(statistics.averagePower, 5)
    }

    func testStatisticsRecoverWhenANewReadingArrives() {
        let old = PowerSample(timestamp: now.addingTimeInterval(-1000), power: 100, percent: 50)
        XCTAssertNil(PowerTrendStatistics(samples: [old], now: now).averagePower)
        let fresh = PowerSample(timestamp: now, power: 12, percent: 50)
        let statistics = PowerTrendStatistics(samples: [old, fresh], now: now)
        XCTAssertEqual(statistics.peakPower, 12)
        XCTAssertEqual(statistics.averagePower, 12)
    }
}
