import XCTest
@testable import BatteryGlass

final class PowerTelemetryEnergyTests: XCTestCase {
    func testWallEnergyCounterDeltaConvertsMicroWhToKWh() {
        let energy = PowerTelemetryEnergy.wallEnergyKWh(
            before: 1_000_000,
            after: 1_250_000,
            duration: 1_800
        )

        XCTAssertEqual(energy ?? 0, 0.25, accuracy: 0.0000001)
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
        XCTAssertNil(
            PowerTelemetryEnergy.wallEnergyKWh(
                before: 0,
                after: 10_000_000,
                duration: 60
            )
        )
    }
}
