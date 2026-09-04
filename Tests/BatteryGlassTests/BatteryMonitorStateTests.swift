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
}
