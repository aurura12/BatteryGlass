import Foundation
import XCTest
@testable import BatteryGlass

final class PowerDiagnosticsTests: XCTestCase {
    func testDiagnosticSamplePreservesRawAndDerivedPowerFields() throws {
        let sample = PowerDiagnosticsSample(
            timestamp: Date(timeIntervalSince1970: 1_000),
            state: .charging,
            adapterConnected: true,
            isCharging: true,
            batteryVoltageV: 12.6,
            batteryCurrentA: 3.603,
            batteryPowerW: 45.4,
            telemetryBatteryPowerW: 0,
            systemPowerInW: 81.79,
            systemLoadW: 91.6,
            systemVoltageInV: 19.903,
            systemCurrentInA: 1.296,
            adapterWatts: 100,
            adapterVoltageV: 20,
            adapterCurrentA: 4.089,
            snapshotSystemPowerW: 36.39,
            chargingPowerW: 45.4,
            directSupplyPowerW: 36.39,
            adapterOutputPowerW: 81.79,
            consumptionPowerW: 81.79
        )

        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(
            PowerDiagnosticsSample.self,
            from: encoder.encode(sample)
        )

        XCTAssertEqual(decoded.systemPowerInW, 81.79)
        XCTAssertEqual(decoded.systemLoadW, 91.6)
        XCTAssertEqual(decoded.chargingPowerW, 45.4)
        XCTAssertEqual(decoded.adapterOutputPowerW, 81.79)
    }
}
