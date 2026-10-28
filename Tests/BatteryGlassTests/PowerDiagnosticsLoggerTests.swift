import Foundation
import XCTest
@testable import BatteryGlass

final class PowerDiagnosticsLoggerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlassDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testAppendWritesOneLinePerSample() throws {
        let logger = PowerDiagnosticsLogger(directory: directory)
        logger.append(makeSample(at: 1_000))
        logger.append(makeSample(at: 2_000))

        XCTAssertEqual(try lines(at: logger.fileURL).count, 2)
        XCTAssertEqual(try timestamps(at: logger.fileURL), [1_000, 2_000])
    }

    func testRotatesBeforeWritingWhenFileWouldExceedLimit() throws {
        // 阈值远小于单条记录，第二次写入必然触发轮换。
        let logger = PowerDiagnosticsLogger(directory: directory, maximumLogBytes: 200)
        logger.append(makeSample(at: 1_000))
        logger.append(makeSample(at: 2_000))

        let backup = backupURL(for: logger.fileURL)
        XCTAssertEqual(try timestamps(at: backup), [1_000])
        XCTAssertEqual(try timestamps(at: logger.fileURL), [2_000])
    }

    func testRotationKeepsOnlyOneBackup() throws {
        let logger = PowerDiagnosticsLogger(directory: directory, maximumLogBytes: 200)
        logger.append(makeSample(at: 1_000))
        logger.append(makeSample(at: 2_000))
        logger.append(makeSample(at: 3_000))

        // 第二次轮换丢弃上一份备份，只保留紧邻的那一份。
        XCTAssertEqual(try timestamps(at: backupURL(for: logger.fileURL)), [2_000])
        XCTAssertEqual(try timestamps(at: logger.fileURL), [3_000])
    }

    func testBackupPathUsesLogFileBaseName() {
        let logger = PowerDiagnosticsLogger(directory: directory)
        XCTAssertEqual(backupURL(for: logger.fileURL).lastPathComponent, "power-diagnostics.1.jsonl")
    }

    // MARK: - Helpers

    private func makeSample(at seconds: TimeInterval) -> PowerDiagnosticsSample {
        PowerDiagnosticsSample(
            timestamp: Date(timeIntervalSince1970: seconds),
            state: .discharging,
            adapterConnected: false,
            isCharging: false,
            batteryVoltageV: 12.1,
            batteryCurrentA: 1.2,
            batteryPowerW: -14.5,
            batteryDischargePowerW: 14.5,
            batteryDischargingWhilePlugged: false,
            telemetryBatteryPowerW: -14,
            systemPowerInW: nil,
            systemLoadW: 14,
            systemVoltageInV: nil,
            systemCurrentInA: nil,
            adapterWatts: nil,
            adapterVoltageV: nil,
            adapterCurrentA: nil,
            snapshotSystemPowerW: 14,
            chargingPowerW: nil,
            directSupplyPowerW: nil,
            adapterOutputPowerW: nil,
            consumptionPowerW: 14.5
        )
    }

    private func backupURL(for logURL: URL) -> URL {
        logURL.deletingPathExtension().appendingPathExtension("1.jsonl")
    }

    private func lines(at url: URL) throws -> [Data] {
        try Data(contentsOf: url)
            .split(separator: 0x0A)
            .map { Data($0) }
    }

    private func timestamps(at url: URL) throws -> [TimeInterval] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try lines(at: url).map { line in
            try decoder.decode(PowerDiagnosticsSample.self, from: line)
                .timestamp
                .timeIntervalSince1970
        }
    }
}
