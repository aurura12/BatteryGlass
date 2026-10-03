import Foundation
import XCTest
@testable import BatteryGlass

final class DailyEnergyQualityTests: XCTestCase {
    func testOldQualityPayloadDefaultsMissingSleepFieldWithoutLosingExistingFlags() throws {
        let data = Data("""
        {"hasSamplingGaps":true,"hasEstimatedSleepEnergy":false,"hasUncalibratedCounterEnergy":false,
         "hasLowerBoundSleepEnergy":false,"hasUnknownHistoricalCoverage":true}
        """.utf8)
        let quality = try JSONDecoder().decode(DailyEnergyQuality.self, from: data)
        XCTAssertFalse(quality.hasUnmeasuredSleepEnergy)
        XCTAssertTrue(quality.hasSamplingGaps)
        XCTAssertTrue(quality.hasUnknownProvenance)
    }

    func testUnmeasuredSleepWarningRoundTripsAndIsAnAccuracyWarning() throws {
        let quality = DailyEnergyQuality(hasUnmeasuredSleepEnergy: true)
        XCTAssertTrue(quality.hasAccuracyWarning)
        XCTAssertFalse(quality.hasUnknownProvenance)
        XCTAssertEqual(
            try JSONDecoder().decode(DailyEnergyQuality.self, from: JSONEncoder().encode(quality)), quality
        )
    }
}
