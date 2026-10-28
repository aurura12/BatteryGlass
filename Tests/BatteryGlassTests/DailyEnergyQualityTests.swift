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

    func testWarningTextListsFlagsAndStaysNilForCleanDay() {
        XCTAssertNil(DailyEnergyQuality().warningText)

        let quality = DailyEnergyQuality(
            hasSamplingGaps: true,
            hasEstimatedSleepEnergy: true,
            hasUncalibratedCounterEnergy: true,
            hasLowerBoundSleepEnergy: true,
            hasUnknownHistoricalCoverage: true,
            hasUnmeasuredSleepEnergy: true
        )
        let text = quality.warningText
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("采样断点") == true)
        XCTAssertTrue(text?.contains("缺少能耗记录") == true)
        XCTAssertTrue(text?.contains("睡眠段为估算值") == true)
        XCTAssertTrue(text?.contains("未校准的遥测计数器") == true)
        XCTAssertTrue(text?.contains("实际值不低于此") == true)
        XCTAssertTrue(text?.contains("旧版本记录") == true)
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
