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
}
