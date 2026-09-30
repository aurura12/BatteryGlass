import Foundation
import XCTest
@testable import BatteryGlass

@MainActor
final class PowerTelemetryCalibrationTests: XCTestCase {
    private func makeFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-calibration-\(UUID().uuidString).json")
    }

    private let context = PowerTelemetryCalibrationContext(
        hardwareModel: "TestModel1,1",
        operatingSystem: "macOS Test"
    )

    private func makeRecord(
        context: PowerTelemetryCalibrationContext,
        rawDelta: UInt64 = 250_000,
        uncalibrated: Double = 0.25,
        measured: Double = 0.2,
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> PowerTelemetryCalibrationRecord {
        try XCTUnwrap(
            PowerTelemetryCalibrationRecord(
                context: context,
                rawDelta: rawDelta,
                uncalibratedEnergyKWh: uncalibrated,
                measuredEnergyKWh: measured,
                createdAt: createdAt
            )
        )
    }

    func testCalibrationRecordRoundTripsAndProvidesModelScopedFactor() throws {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        store.append(try makeRecord(context: context))

        let reloaded = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        XCTAssertEqual(reloaded.calibrationFactor, 0.8, accuracy: 0.0000001)
        XCTAssertTrue(reloaded.isCalibrated)
    }

    func testMissingCalibrationUsesUnitFactorAndIsUncalibrated() {
        let fileURL = makeFileURL()
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
        XCTAssertNil(store.activeRecord)
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

    func testActiveRecordIgnoresOtherContextsAndPicksLatest() throws {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        let otherContext = PowerTelemetryCalibrationContext(
            hardwareModel: "OtherModel,1",
            operatingSystem: "macOS Test"
        )

        store.append(try makeRecord(context: otherContext, measured: 0.5))
        store.append(try makeRecord(
            context: context,
            measured: 0.2,
            createdAt: Date(timeIntervalSince1970: 1_000)
        ))
        store.append(try makeRecord(
            context: context,
            measured: 0.1,
            createdAt: Date(timeIntervalSince1970: 2_000)
        ))

        let active = try XCTUnwrap(store.activeRecord)
        XCTAssertEqual(active.measuredEnergyKWh, 0.1, accuracy: 0.0000001)
        XCTAssertEqual(active.context, context)
        XCTAssertEqual(store.calibrationFactor, 0.4, accuracy: 0.0000001)
    }

    func testRemoveAndClearRecordsPersist() throws {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        let first = try makeRecord(context: context, createdAt: Date(timeIntervalSince1970: 1_000))
        let second = try makeRecord(context: context, createdAt: Date(timeIntervalSince1970: 2_000))
        store.append(first)
        store.append(second)

        store.remove(id: first.id)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(
            PowerTelemetryCalibrationStore(fileURL: fileURL, context: context).records.count,
            1
        )

        store.clearRecords()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(store.isCalibrated)
        XCTAssertTrue(PowerTelemetryCalibrationStore(fileURL: fileURL, context: context).records.isEmpty)
    }

    func testSessionCompletionSavesRecordWithDerivedFactor() throws {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        XCTAssertTrue(store.startSession(startCounter: 1_000_000_000, batteryPercent: 63))

        let result = store.completeSession(endCounter: 1_250_000_000, measuredEnergyKWh: 0.2)
        guard case .saved(let record) = result else {
            return XCTFail("expected saved, got \(result)")
        }

        XCTAssertEqual(record.rawDelta, 250_000_000)
        XCTAssertEqual(record.uncalibratedEnergyKWh, 0.25, accuracy: 0.0000001)
        XCTAssertEqual(record.calibrationFactor, 0.8, accuracy: 0.0000001)
        XCTAssertNil(store.session)
        XCTAssertTrue(store.isCalibrated)
    }

    func testSessionPersistsAcrossReload() {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        XCTAssertTrue(store.startSession(startCounter: 42, batteryPercent: nil))

        let reloaded = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        XCTAssertEqual(reloaded.session?.startCounter, 42)
        XCTAssertEqual(reloaded.session?.context, context)
    }

    func testSessionRejectsZeroStartCounter() {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        XCTAssertFalse(store.startSession(startCounter: 0, batteryPercent: nil))
        XCTAssertNil(store.session)
    }

    func testCompleteSessionDetectsCounterReset() {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        XCTAssertTrue(store.startSession(startCounter: 500, batteryPercent: nil))

        XCTAssertEqual(store.completeSession(endCounter: 400, measuredEnergyKWh: 0.2), .counterReset)
        XCTAssertNil(store.session)
        XCTAssertFalse(store.isCalibrated)
    }

    func testCompleteSessionDetectsContextChange() {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        XCTAssertTrue(store.startSession(startCounter: 1_000, batteryPercent: nil))

        let otherOSContext = PowerTelemetryCalibrationContext(
            hardwareModel: context.hardwareModel,
            operatingSystem: "macOS Updated"
        )
        let reloaded = PowerTelemetryCalibrationStore(fileURL: fileURL, context: otherOSContext)

        XCTAssertEqual(
            reloaded.completeSession(endCounter: 1_250, measuredEnergyKWh: 0.2),
            .contextChanged
        )
        XCTAssertNil(reloaded.session)
    }

    func testCompleteSessionRejectsInvalidMeasurementAndKeepsSession() {
        let fileURL = makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = PowerTelemetryCalibrationStore(fileURL: fileURL, context: context)
        XCTAssertTrue(store.startSession(startCounter: 1_000, batteryPercent: nil))

        XCTAssertEqual(store.completeSession(endCounter: 1_250, measuredEnergyKWh: 0), .invalidInput)
        XCTAssertNotNil(store.session, "invalidInput 应保留会话以便修正后重试")
        XCTAssertFalse(store.isCalibrated)
    }
}
