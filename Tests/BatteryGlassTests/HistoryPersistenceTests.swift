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

    private struct PersistedHistory: Decodable {
        let samples: [HistorySample]
    }
}
