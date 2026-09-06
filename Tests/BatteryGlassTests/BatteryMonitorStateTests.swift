import XCTest
@testable import BatteryGlass

@MainActor
final class BatteryMonitorStateTests: XCTestCase {
    func testExternalPowerWinsOverStaleNegativeBatteryCurrent() {
        let state = BatteryMonitor.resolvedPowerState(
            externalConnected: true,
            isCharging: false,
            isFinishingCharge: false,
            isPresent: true,
            batteryCurrent: -2.0
        )

        XCTAssertEqual(state, .pluggedIn)
    }

    func testPluggedDischargeRequiresTwoConsecutiveNegativeSamples() {
        var confirmation = BatteryDischargeConfirmation()

        XCTAssertFalse(
            confirmation.update(
                adapterConnected: true,
                state: .pluggedIn,
                batteryPowerW: -24
            )
        )
        XCTAssertTrue(
            confirmation.update(
                adapterConnected: true,
                state: .pluggedIn,
                batteryPowerW: -24
            )
        )
    }

    func testPluggedDischargeConfirmationResetsWhenSourceStopsDischarging() {
        var confirmation = BatteryDischargeConfirmation()
        _ = confirmation.update(adapterConnected: true, state: .pluggedIn, batteryPowerW: -24)
        _ = confirmation.update(adapterConnected: true, state: .pluggedIn, batteryPowerW: -24)

        XCTAssertFalse(
            confirmation.update(
                adapterConnected: true,
                state: .pluggedIn,
                batteryPowerW: 12
            )
        )
        XCTAssertFalse(
            confirmation.update(
                adapterConnected: false,
                state: .discharging,
                batteryPowerW: -24
            )
        )
    }

    func testMaintenancePowerSelectionKeepsDirectAndAdapterInputsSeparate() {
        let result = BatteryMonitor.minimumMaintenancePowers(
            directSamples: [4, 2, 3],
            adapterInputSamples: [70, 65, 68]
        )

        XCTAssertEqual(result.directSupplyPowerW ?? 0, 2, accuracy: 0.000001)
        XCTAssertEqual(result.adapterInputPowerW ?? 0, 65, accuracy: 0.000001)
    }
}
