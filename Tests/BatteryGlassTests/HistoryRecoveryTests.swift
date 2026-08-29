import Foundation
import XCTest
@testable import BatteryGlass

final class HistoryRecoveryTests: XCTestCase {
    func testBackfillsMissingConsumptionFromNearestDiagnostic() {
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let historySample = HistorySample(
            timestamp: timestamp,
            power: 0,
            percent: 80,
            cycleCount: 1,
            healthPercent: 100
        )
        let diagnosticSample = diagnosticSample(at: timestamp.addingTimeInterval(1))

        let result = HistorySampleRecovery.backfillConsumptionPower(
            in: [historySample],
            from: [diagnosticSample]
        )

        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.samples[0].consumptionPowerW, 42)
    }

    func testDoesNotBackfillWhenDiagnosticIsTooFarAway() {
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let historySample = HistorySample(
            timestamp: timestamp,
            power: 0,
            percent: 80,
            cycleCount: 1,
            healthPercent: 100
        )
        let diagnosticSample = diagnosticSample(at: timestamp.addingTimeInterval(10))

        let result = HistorySampleRecovery.backfillConsumptionPower(
            in: [historySample],
            from: [diagnosticSample]
        )

        XCTAssertFalse(result.didChange)
        XCTAssertNil(result.samples[0].consumptionPowerW)
    }

    private func diagnosticSample(at timestamp: Date) -> PowerDiagnosticsSample {
        PowerDiagnosticsSample(
            timestamp: timestamp,
            state: .pluggedIn,
            adapterConnected: true,
            isCharging: false,
            batteryVoltageV: 12,
            batteryCurrentA: 0,
            batteryPowerW: 0,
            telemetryBatteryPowerW: nil,
            systemPowerInW: 42,
            systemLoadW: 42,
            systemVoltageInV: 20,
            systemCurrentInA: 2.1,
            adapterWatts: 100,
            adapterVoltageV: 20,
            adapterCurrentA: 2.1,
            snapshotSystemPowerW: 42,
            chargingPowerW: nil,
            directSupplyPowerW: 42,
            adapterOutputPowerW: 42,
            consumptionPowerW: 42
        )
    }
}
