import XCTest
@testable import BatteryGlass

final class PowerTelemetryEnergyTests: XCTestCase {
    func testWallEnergyCounterDeltaConvertsCounterUnitsToKWh() {
        let energy = PowerTelemetryEnergy.wallEnergyKWh(
            before: 1_000_000,
            after: 1_250_000,
            duration: 1_800
        )

        // 250_000 counter units ÷ 1e9 units/kWh = 0.00025 kWh
        XCTAssertEqual(energy ?? 0, 0.00025, accuracy: 0.000000001)
    }

    func testWallEnergyCounterRejectsReset() {
        XCTAssertNil(
            PowerTelemetryEnergy.wallEnergyKWh(
                before: 2_000,
                after: 1_000,
                duration: 1_800
            )
        )
    }

    func testWallEnergyCounterRejectsImplausiblyLargePower() {
        // 100_000_000 units ÷ 1e9 = 0.1 kWh over 60 s → 6000 W，远超 500 W 上限。
        XCTAssertNil(
            PowerTelemetryEnergy.wallEnergyKWh(
                before: 0,
                after: 100_000_000,
                duration: 60
            )
        )
    }

    func testWallEnergyCounterAppliesCalibrationFactorAfterValidation() {
        let energy = PowerTelemetryEnergy.wallEnergyKWh(
            before: 1_000_000,
            after: 1_250_000,
            duration: 1_800,
            calibrationFactor: 0.8
        )

        XCTAssertEqual(energy ?? 0, 0.0002, accuracy: 0.000000001)
    }

    func testWallEnergyCounterRejectsInvalidCalibrationFactor() {
        XCTAssertNil(
            PowerTelemetryEnergy.wallEnergyKWh(
                before: 1_000_000,
                after: 1_250_000,
                duration: 1_800,
                calibrationFactor: 0
            )
        )
    }

    func testUncalibratedEnergyUsesDefaultUnitAssumption() {
        XCTAssertEqual(
            PowerTelemetryEnergy.uncalibratedEnergyKWh(rawDelta: 250_000),
            0.00025,
            accuracy: 0.000000001
        )
        XCTAssertEqual(PowerTelemetryEnergy.uncalibratedEnergyKWh(rawDelta: 0), 0)
    }
}
