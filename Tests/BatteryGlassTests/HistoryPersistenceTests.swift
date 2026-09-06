import Foundation
import AppKit
import XCTest
@testable import BatteryGlass

@MainActor
final class HistoryPersistenceTests: XCTestCase {
    func testFlushWritesLatestSamplesImmediately() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        let store = BatteryHistoryStore(settings: settings, fileURL: fileURL)

        var snapshot = BatterySnapshot()
        snapshot.isPresent = true
        snapshot.state = .discharging
        snapshot.percent = 50
        snapshot.voltage = 12
        snapshot.current = -2
        store.record(snapshot)

        store.flush()

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(PersistedHistory.self, from: data)
        XCTAssertEqual(payload.samples.count, 1)
        XCTAssertEqual(payload.samples[0].consumptionPowerW, 24)
    }

    func testTerminationNotificationFlushesLatestSamplesSynchronously() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        let store = BatteryHistoryStore(settings: settings, fileURL: fileURL)

        var firstSnapshot = BatterySnapshot()
        firstSnapshot.isPresent = true
        firstSnapshot.state = .discharging
        firstSnapshot.percent = 50
        firstSnapshot.voltage = 12
        firstSnapshot.current = -2
        store.record(firstSnapshot)

        var latestSnapshot = firstSnapshot
        latestSnapshot.timestamp = firstSnapshot.timestamp.addingTimeInterval(5)
        latestSnapshot.cycleCount = 2
        latestSnapshot.current = -3
        store.record(latestSnapshot)

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(PersistedHistory.self, from: data)
        XCTAssertEqual(payload.samples.count, 2)
        XCTAssertEqual(payload.samples.last?.consumptionPowerW, 36)
    }

    func testSnapshotNotificationIsFlushedBeforeImmediateTermination() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        let store = BatteryHistoryStore(settings: settings, fileURL: fileURL)
        _ = store

        var snapshot = BatterySnapshot()
        snapshot.isPresent = true
        snapshot.state = .discharging
        snapshot.percent = 50
        snapshot.voltage = 12
        snapshot.current = -2

        NotificationCenter.default.post(
            name: .batterySnapshotUpdated,
            object: nil,
            userInfo: ["snapshot": snapshot]
        )
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(PersistedHistory.self, from: data)
        XCTAssertEqual(payload.samples.count, 1)
        XCTAssertEqual(payload.samples[0].consumptionPowerW, 24)
    }

    func testV2PayloadLoadsWithEmptySleepSegments() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let json = """
        {
          "version": 2,
          "samples": [
            {"id":"00000000-0000-0000-0000-000000000001","timestamp":"2026-08-27T10:00:00Z","power":-20,"consumptionPowerW":24,"percent":50,"cycleCount":1,"healthPercent":100}
          ],
          "dailySummaries": []
        }
        """
        try Data(json.utf8).write(to: fileURL)

        let store = BatteryHistoryStore(
            settings: AppSettings(defaults: defaults),
            fileURL: fileURL
        )

        XCTAssertTrue(store.sleepSegments.isEmpty)
        XCTAssertTrue(store.sleepIntervals.isEmpty)
    }

    func testShortSleepBoundarySkipsBridgeEnergy() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = BatteryHistoryStore(
            settings: AppSettings(defaults: defaults),
            fileURL: fileURL
        )
        let start = Date()
        store.record(snapshot(at: start, cycleCount: 1))
        NotificationCenter.default.post(
            name: .sleepIntervalStarted,
            object: nil,
            userInfo: ["start": start]
        )

        store.record(snapshot(at: start.addingTimeInterval(30), cycleCount: 2))
        NotificationCenter.default.post(
            name: .sleepIntervalEnded,
            object: nil,
            userInfo: [
                "start": start,
                "end": start.addingTimeInterval(30)
            ]
        )

        XCTAssertNil(store.allSummaries().first?.energyKWh)
        XCTAssertEqual(store.sleepIntervals.count, 1)
    }

    func testExactlySixtySecondSleepAddsOnlySleepSegmentEnergy() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = BatteryHistoryStore(
            settings: AppSettings(defaults: defaults),
            fileURL: fileURL
        )
        let start = Date()
        let end = start.addingTimeInterval(60)
        store.record(snapshot(at: start, cycleCount: 1))
        NotificationCenter.default.post(
            name: .sleepIntervalStarted,
            object: nil,
            userInfo: ["start": start]
        )
        store.record(snapshot(at: end, cycleCount: 2))
        NotificationCenter.default.post(
            name: .sleepIntervalEnded,
            object: nil,
            userInfo: ["start": start, "end": end]
        )

        store.recordSleepSegment(
            SleepSegment(
                id: UUID(),
                start: start,
                end: end,
                energyKWh: 0.02,
                averagePowerW: 1_200,
                mode: .pluggedIdle
            )
        )

        XCTAssertEqual(store.allSummaries().first?.energyKWh ?? 0, 0.02, accuracy: 0.0000001)
    }

    func testSleepIntervalsRoundTripAndRejectInvalidDuplicates() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = BatteryHistoryStore(
            settings: AppSettings(defaults: defaults),
            fileURL: fileURL
        )
        let start = date("2026-08-27 10:00:00")
        let end = start.addingTimeInterval(60)
        store.recordSleepInterval(start: start, end: start)
        store.recordSleepInterval(start: start, end: end)
        store.recordSleepInterval(start: start, end: end)
        store.flush()

        let reloaded = BatteryHistoryStore(
            settings: AppSettings(defaults: defaults),
            fileURL: fileURL
        )
        XCTAssertEqual(reloaded.sleepIntervals.count, 1)
        XCTAssertEqual(reloaded.sleepIntervals.first?.start, start)
        XCTAssertEqual(reloaded.sleepIntervals.first?.end, end)
    }

    func testSleepSegmentsRoundTripThroughV3Payload() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        let store = BatteryHistoryStore(settings: settings, fileURL: fileURL)

        let segment = SleepSegment(
            id: UUID(),
            start: date("2026-08-27 23:00:00"),
            end: date("2026-08-28 01:00:00"),
            energyKWh: 0.02,
            averagePowerW: 10,
            mode: .charging
        )
        store.recordSleepSegment(segment)
        store.flush()

        let reloaded = BatteryHistoryStore(settings: settings, fileURL: fileURL)
        XCTAssertEqual(reloaded.sleepSegments, [segment])
    }

    func testV3SleepSegmentWithoutMeasurementMethodDefaultsToFallback() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let json = """
        {
          "version": 3,
          "samples": [],
          "dailySummaries": [],
          "sleepSegments": [
            {
              "id": "00000000-0000-0000-0000-000000000002",
              "start": "2026-08-27T10:00:00Z",
              "end": "2026-08-27T11:00:00Z",
              "energyKWh": 0.02,
              "averagePowerW": 20,
              "mode": "discharging"
            }
          ]
        }
        """
        try Data(json.utf8).write(to: fileURL)

        let store = BatteryHistoryStore(
            settings: AppSettings(defaults: defaults),
            fileURL: fileURL
        )

        XCTAssertEqual(store.sleepSegments.first?.measurementMethod, .fallbackEstimate)
    }

    func testDuplicateSleepSegmentIsCountedOnlyOnce() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = BatteryHistoryStore(
            settings: AppSettings(defaults: defaults),
            fileURL: fileURL
        )
        let segment = SleepSegment(
            id: UUID(),
            start: date("2026-08-27 10:00:00"),
            end: date("2026-08-27 11:00:00"),
            energyKWh: 0.02,
            averagePowerW: 20,
            mode: .discharging
        )

        store.recordSleepSegment(segment)
        store.recordSleepSegment(segment)

        XCTAssertEqual(store.sleepSegments, [segment])
    }

    func testSleepSegmentDoesNotRecordWhenHistoryIsDisabled() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        settings.recordHistory = false
        let store = BatteryHistoryStore(settings: settings, fileURL: fileURL)
        let segment = SleepSegment(
            id: UUID(),
            start: date("2026-08-27 10:00:00"),
            end: date("2026-08-27 11:00:00"),
            energyKWh: 0.02,
            averagePowerW: 20,
            mode: .discharging
        )

        store.recordSleepSegment(segment)

        XCTAssertTrue(store.sleepSegments.isEmpty)
    }

    private struct PersistedHistory: Decodable {
        let samples: [HistorySample]
    }

    private func snapshot(at timestamp: Date, cycleCount: Int) -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        snapshot.timestamp = timestamp
        snapshot.isPresent = true
        snapshot.state = .discharging
        snapshot.percent = 50
        snapshot.voltage = 12
        snapshot.current = -2
        snapshot.cycleCount = cycleCount
        return snapshot
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }
}
