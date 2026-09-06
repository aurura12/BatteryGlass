import Foundation
import XCTest
@testable import BatteryGlass

final class PowerTelemetryCalibrationTests: XCTestCase {
    func testCalibrationRecordRoundTripsAndProvidesModelScopedFactor() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-calibration-(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let context = PowerTelemetryCalibrationContext(
            hardwareModel: "TestModel1,1",
            operatingSystem: "macOS Test"
        )
        let record = try XCTUnwrap(
            PowerTelemetryCalibrationRecord(
                context: context,
                rawDelta: 250_000,
                uncalibratedEnergyKWh: 0.25,
                measuredEnergyKWh: 0.2,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
        )

        var store = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        store.append(record)

        let reloaded = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        XCTAssertEqual(reloaded.calibrationFactor, 0.8, accuracy: 0.0000001)
        XCTAssertTrue(reloaded.isCalibrated)
    }

    func testMissingCalibrationUsesUnitFactorAndIsUncalibrated() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-calibration-(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PowerTelemetryCalibrationStore(
            fileURL: fileURL,
            context: PowerTelemetryCalibrationContext(
                hardwareModel: "UncalibratedModel,1",
                operatingSystem: "macOS Test"
            )
        )

        XCTAssertEqual(store.calibrationFactor, 1)
        XCTAssertFalse(store.isCalibrated)
    }

    func testOldSleepSegmentDefaultsToUncalibrated() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000003",
          "start": "2026-08-27T10:00:00Z",
          "end": "2026-08-27T11:00:00Z",
          "energyKWh": 0.02,
          "averagePowerW": 20,
          "mode": "discharging",
          "measurementMethod": "telemetryCounter"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let segment = try decoder.decode(SleepSegment.self, from: Data(json.utf8))

        XCTAssertFalse(segment.isCalibrated)
    }
}
