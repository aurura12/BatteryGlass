import Foundation
import XCTest
@testable import BatteryGlass

@MainActor
final class LongTermHistoryTests: XCTestCase {
    func testLegacyMigrationPreservesAllDatesSummariesAndBackup() throws {
        let context = try Context()
        defer { context.cleanup() }
        let today = Calendar.current.startOfDay(for: context.now)
        let oldest = Calendar.current.date(byAdding: .year, value: -5, to: today)!.addingTimeInterval(3_600)
        let yesterday = today.addingTimeInterval(-60)
        let points = [
            sample(at: oldest), sample(at: oldest.addingTimeInterval(55)), sample(at: oldest.addingTimeInterval(60)),
            sample(at: yesterday), sample(at: yesterday.addingTimeInterval(55)),
            sample(at: today.addingTimeInterval(5)), sample(at: today.addingTimeInterval(10))
        ]
        let summaries = [summary(day: oldest, energy: 0.123), summary(day: yesterday, energy: 0.456)]
        let original = try context.writeLegacy(samples: points, summaries: summaries)
        let store = context.makeStore()

        XCTAssertEqual(try Data(contentsOf: context.backupURL), original)
        XCTAssertEqual(store.allSummaries(), summaries)
        XCTAssertEqual(store.samples(forDay: oldest), [points[1], points[2]])
        XCTAssertEqual(store.samples(forDay: yesterday), [points[4]])
        XCTAssertEqual(store.samples(forDay: today), Array(points.suffix(2)))
        XCTAssertEqual(store.samples.count, 3) // Today and one energy-integration boundary.
        XCTAssertEqual(store.availableDays(), [Calendar.current.startOfDay(for: oldest), Calendar.current.startOfDay(for: yesterday), today])
        XCTAssertEqual(try store.allCurveSamples(), [points[1], points[2], points[4], points[5], points[6]])
        store.flush()

        let reloaded = context.makeStore()
        XCTAssertEqual(try reloaded.allCurveSamples(), try store.allCurveSamples())
        XCTAssertEqual(reloaded.allSummaries(), summaries)
        XCTAssertEqual(try Data(contentsOf: context.backupURL), original)
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: context.fileURL)) as! [String: Any]
        XCTAssertEqual(payload["version"] as? Int, 8)
    }

    func testMidnightArchivesYesterdayAndPreservesFineSamplesAndEnergyAfterRestart() throws {
        let context = try Context()
        defer { context.cleanup() }
        let midnight = Calendar.current.startOfDay(for: context.now)
        context.now = midnight.addingTimeInterval(-60)
        let store = context.makeStore()
        for offset in [-60.0, -30, -5, 5, 10] {
            context.now = midnight.addingTimeInterval(offset)
            store.record(snapshot(at: context.now))
        }
        store.flush()

        XCTAssertEqual(store.samples(forDay: midnight.addingTimeInterval(-60)).map(\.timestamp), [midnight.addingTimeInterval(-5)])
        XCTAssertEqual(store.samples(forDay: midnight).map(\.timestamp), [midnight.addingTimeInterval(5), midnight.addingTimeInterval(10)])
        let before = store.allSummaries()
        XCTAssertEqual(before[0].sampleCount, 3)
        XCTAssertEqual(before[0].energyKWh ?? -1, 20 * 60 / 3_600_000, accuracy: 1e-10)
        XCTAssertEqual(before[1].energyKWh ?? -1, 20 * 10 / 3_600_000, accuracy: 1e-10)

        let reloaded = context.makeStore()
        XCTAssertEqual(reloaded.allSummaries(), before)
        context.now = midnight.addingTimeInterval(15)
        reloaded.record(snapshot(at: context.now))
        reloaded.flush()
        XCTAssertEqual(reloaded.allSummaries()[0], before[0])
        XCTAssertEqual(reloaded.allSummaries()[1].energyKWh ?? -1, 20 * 15 / 3_600_000, accuracy: 1e-10)
        XCTAssertEqual(reloaded.samples(forDay: midnight).count, 3)
    }

    func testRestartBeforeFirstTodaySampleKeepsMidnightEnergyBoundary() throws {
        let context = try Context()
        defer { context.cleanup() }
        let midnight = Calendar.current.startOfDay(for: context.now)
        context.now = midnight.addingTimeInterval(-5)
        let store = context.makeStore()
        store.record(snapshot(at: context.now))
        store.flush()
        context.now = midnight.addingTimeInterval(5)
        let reloaded = context.makeStore()
        reloaded.record(snapshot(at: context.now))
        reloaded.flush()
        XCTAssertEqual(reloaded.allSummaries().last?.energyKWh ?? -1, 20 * 5 / 3_600_000, accuracy: 1e-10)
        XCTAssertEqual(reloaded.samples(forDay: midnight.addingTimeInterval(-5)).count, 1)
    }

    func testArchiveBeyondOldFileAndSampleLimitsLoadsOnlyRequestedDay() throws {
        let context = try Context()
        defer { context.cleanup() }
        let oldest = Calendar.current.date(byAdding: .day, value: -200, to: Calendar.current.startOfDay(for: context.now))!
        let count = HistoryLoadLimits.maxHistorySamples + 100
        let points = (0..<count).map { sample(at: oldest.addingTimeInterval(Double($0) * 60)) }
        try context.archive.store(points)
        let size = try FileManager.default.attributesOfItem(atPath: context.archive.fileURL.path)[.size] as! NSNumber
        XCTAssertGreaterThan(size.intValue, HistoryLoadLimits.maxHistoryFileBytes)
        try context.writeLegacy(samples: [sample(at: context.now)])
        let store = context.makeStore()
        XCTAssertEqual(store.samples.count, 1)
        XCTAssertGreaterThan(store.availableDays().count, 60)
        XCTAssertEqual(store.samples(forDay: oldest).count, 1_440)
        XCTAssertEqual(store.samples(forDay: context.now).count, 1)
        store.flush()
        let reloaded = context.makeStore()
        XCTAssertEqual(reloaded.samples.count, 1)
        XCTAssertEqual(reloaded.samples(forDay: oldest).count, 1_440)
    }

    func testClearRemovesArchiveAndMigrationBackupAndStartsRecordingAgain() throws {
        let context = try Context()
        defer { context.cleanup() }
        let old = context.now.addingTimeInterval(-30 * 86_400)
        try context.writeLegacy(samples: [sample(at: old), sample(at: context.now)])
        let store = context.makeStore()
        XCTAssertFalse(try store.allCurveSamples().isEmpty)
        _ = store.samples(forDay: old) // Populate the chart cache before clearing.
        store.clearHistory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.archive.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.backupURL.path))
        XCTAssertTrue(store.availableDays().isEmpty)
        XCTAssertTrue(store.samples(forDay: old).isEmpty)
        XCTAssertTrue(try store.allCurveSamples().isEmpty)
        store.record(snapshot(at: context.now))
        store.flush()
        XCTAssertEqual(context.makeStore().samples.count, 1)
        XCTAssertTrue(context.makeStore().samples(forDay: old).isEmpty)
    }

    func testFailedArchiveMigrationLeavesOriginalAndAllSamplesAvailableForRetry() throws {
        let context = try Context()
        defer { context.cleanup() }
        let old = context.now.addingTimeInterval(-30 * 86_400)
        let points = [sample(at: old), sample(at: old.addingTimeInterval(60)), sample(at: context.now)]
        let original = try context.writeLegacy(samples: points)
        // A directory at the DB path forces a real filesystem failure without permissions tricks.
        try FileManager.default.createDirectory(at: context.archive.fileURL, withIntermediateDirectories: true)
        let store = context.makeStore()
        store.flush()
        XCTAssertEqual(try Data(contentsOf: context.fileURL), original)
        XCTAssertEqual(store.samples.count, 3)
        XCTAssertEqual(store.samples(forDay: old).count, 2)
        try FileManager.default.removeItem(at: context.archive.fileURL)
        store.flush()
        let reloaded = context.makeStore()
        XCTAssertEqual(try reloaded.allCurveSamples(), points)
        XCTAssertEqual(reloaded.samples(forDay: old).count, 2)
    }

    func testInvalidLiveFileIsPreservedInsteadOfOverwrittenByNewRecording() throws {
        let context = try Context()
        defer { context.cleanup() }
        let original = Data("invalid history".utf8)
        try original.write(to: context.fileURL)
        let store = context.makeStore()
        store.record(snapshot(at: context.now))
        store.flush()
        XCTAssertEqual(try Data(contentsOf: context.fileURL), original)
    }

    private func sample(at timestamp: Date) -> HistorySample {
        HistorySample(timestamp: timestamp, power: -20, consumptionPowerW: 20, percent: 50, cycleCount: 1, healthPercent: 98)
    }

    private func snapshot(at timestamp: Date) -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        snapshot.timestamp = timestamp
        snapshot.isPresent = true
        snapshot.state = .discharging
        snapshot.percent = 50
        snapshot.voltage = 10
        snapshot.current = -2
        snapshot.temperatureCelsius = 35.2
        return snapshot
    }

    private func summary(day: Date, energy: Double) -> DailySummary {
        DailySummary(dayKey: BatteryFormatters.dayKey(for: day), date: Calendar.current.startOfDay(for: day), sampleCount: 12, maxCycleCount: 1, minHealthPercent: 98, energyKWh: energy, averagePower: -20, maxPower: -20, minPower: -20, energyQuality: DailyEnergyQuality())
    }

    private struct LegacyPayload: Codable {
        var version = 6
        var samples: [HistorySample]
        var dailySummaries: [DailySummary]
    }

    @MainActor
    private final class Context {
        let directory: URL
        let fileURL: URL
        let archive: HistorySampleArchive
        let backupURL: URL
        let suiteName = "BatteryGlassLongTermTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        var now = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryGlassLongTerm-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("history.json")
            archive = HistorySampleArchive(fileURL: directory.appendingPathComponent("history.sqlite"))
            backupURL = directory.appendingPathComponent("history.legacy.json")
            defaults = UserDefaults(suiteName: suiteName)!
        }

        func makeStore() -> BatteryHistoryStore {
            BatteryHistoryStore(settings: AppSettings(defaults: defaults), fileURL: fileURL, now: { self.now })
        }

        @discardableResult
        func writeLegacy(samples: [HistorySample], summaries: [DailySummary] = []) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(LegacyPayload(samples: samples, dailySummaries: summaries))
            try data.write(to: fileURL)
            return data
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
