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
}
