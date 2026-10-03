import AppKit
import Foundation
import XCTest
@testable import BatteryGlass

@MainActor
final class HistoryAccountingBoundaryTests: XCTestCase {
    func testRecentRangesKeepCalendarBoundariesWhenDaysAreMissing() throws {
        let context = try Context()
        defer { context.cleanup() }
        let today = Calendar.current.startOfDay(for: context.now)

        for count in [7, 14, 30, 90] {
            let offsets = [-count, 1 - count, -1, 0, 1]
            let summaries = offsets.map { offset in
                summary(on: Calendar.current.date(byAdding: .day, value: offset, to: today)!)
            }
            let url = context.directory.appendingPathComponent("range-\(count).json")
            try context.write(summaries: summaries, to: url)
            let store = context.makeStore(fileURL: url)

            XCTAssertEqual(store.summaries(lastDays: count).map(\.dayKey), Array(summaries[1...3]).map(\.dayKey))
            XCTAssertEqual(store.summaries(lastDays: 1).map(\.dayKey), [BatteryFormatters.dayKey(for: today)])
            XCTAssertTrue(store.summaries(lastDays: 0).isEmpty)
            XCTAssertTrue(store.summaries(lastDays: -1).isEmpty)
        }
    }

    func testTerminationSettlesPendingSleepBeforeSnapshotIsWrittenAndOnlyOnce() throws {
        let context = try Context()
        defer { context.cleanup() }
        let end = context.now
        let start = end.addingTimeInterval(-3600)
        var pending: SleepSegment? = try XCTUnwrap(SleepEnergyCalculator.segment(from: .init(
            sleepStart: start, capacityBeforeMAh: 5000, voltageBeforeV: 12,
            adapterConnectedBefore: false, wakeTime: end,
            capacityAfterMAh: 4000, voltageAfterV: 12,
            adapterConnectedAfter: false, maintenanceDirectPowerW: nil
        )))
        let store = context.makeStore(finishPendingSleepEnergy: {
            guard let segment = pending else { return }
            pending = nil
            NotificationCenter.default.post(
                name: .sleepSegmentRecorded, object: nil, userInfo: ["segment": segment]
            )
        })
        store.recordSleepInterval(start: start, end: end)
        XCTAssertTrue(store.sleepSegments.isEmpty)

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        let saved = try context.read()
        XCTAssertEqual(saved.sleepSegments.count, 1)
        XCTAssertEqual(try XCTUnwrap(saved.dailySummaries.last?.energyKWh), 0.012, accuracy: 1e-10)
        XCTAssertFalse(try XCTUnwrap(saved.dailySummaries.last?.energyQuality).hasUnmeasuredSleepEnergy)
    }

    func testClearCancelsPendingSleepAndRejectsAlreadyQueuedOldEvents() throws {
        let context = try Context()
        defer { context.cleanup() }
        let clearedAt = context.now
        let start = clearedAt.addingTimeInterval(-3600)
        let oldSegment = segment(start: start, end: clearedAt.addingTimeInterval(-5))
        var pending: SleepSegment? = oldSegment
        let store = context.makeStore(
            finishPendingSleepEnergy: {
                guard let segment = pending else { return }
                pending = nil
                NotificationCenter.default.post(
                    name: .sleepSegmentRecorded, object: nil, userInfo: ["segment": segment]
                )
            },
            cancelPendingSleepEnergy: { pending = nil }
        )
        store.recordSleepInterval(start: oldSegment.start, end: oldSegment.end)
        store.clearHistory()

        NotificationCenter.default.post(
            name: .sleepSegmentRecorded, object: nil, userInfo: ["segment": oldSegment]
        )
        store.recordSleepInterval(start: oldSegment.start, end: oldSegment.end)
        store.record(snapshot(at: clearedAt.addingTimeInterval(-5)))
        store.flush()

        XCTAssertNil(pending)
        XCTAssertTrue(store.samples.isEmpty)
        XCTAssertTrue(store.sleepSegments.isEmpty)
        XCTAssertTrue(store.sleepIntervals.isEmpty)
        XCTAssertTrue(store.allSummaries().isEmpty)

        store.record(snapshot(at: clearedAt))
        context.now = clearedAt.addingTimeInterval(5)
        store.record(snapshot(at: context.now))
        XCTAssertEqual(try XCTUnwrap(store.allSummaries().last?.energyKWh), 24 * 5 / 3_600_000, accuracy: 1e-10)
        let newSegment = segment(start: context.now, end: context.now.addingTimeInterval(60))
        store.recordSleepSegment(newSegment)
        XCTAssertEqual(store.sleepSegments, [newSegment])
    }

    func testClearRemovesKnownRepairBackupsAndPreservesOtherFiles() throws {
        let context = try Context()
        defer { context.cleanup() }
        let backups = ["20260930T173450+0800", "20261001T090000+0800"].map {
            context.fileURL.appendingPathExtension("before-counter-unit-repair-\($0)")
        }
        let unrelated = context.fileURL.appendingPathExtension("before-other-edit")
        let directory = context.fileURL.appendingPathExtension("before-counter-unit-repair-folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in backups + [unrelated] { try Data("backup".utf8).write(to: url) }

        context.makeStore().clearHistory()

        for url in backups { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnobservableLongSleepWarnsWithoutInventingEnergyAndSurvivesRestart() throws {
        let context = try Context()
        defer { context.cleanup() }
        let start = context.now
        let end = start.addingTimeInterval(3600)
        let store = context.makeStore()
        store.record(snapshot(at: start))
        let unobservable = SleepEnergyCalculator.segment(from: .init(
            sleepStart: start, capacityBeforeMAh: 4000, voltageBeforeV: 12,
            adapterConnectedBefore: false, wakeTime: end,
            capacityAfterMAh: 4000, voltageAfterV: 12,
            adapterConnectedAfter: true, maintenanceDirectPowerW: 20,
            maintenanceAdapterInputPowerW: 20
        ))
        XCTAssertNil(unobservable)
        store.recordSleepInterval(start: start, end: end)
        context.now = end
        store.record(snapshot(at: end))
        context.now = end.addingTimeInterval(5)
        store.record(snapshot(at: context.now))
        store.flush()

        let day = try XCTUnwrap(store.allSummaries().last)
        XCTAssertEqual(try XCTUnwrap(day.energyKWh), 24 * 5 / 3_600_000, accuracy: 1e-10)
        XCTAssertTrue(day.needsEnergyAttention)
        XCTAssertTrue(try XCTUnwrap(day.energyQuality).hasUnmeasuredSleepEnergy)

        let reloaded = context.makeStore()
        XCTAssertEqual(reloaded.allSummaries().last?.energyKWh, day.energyKWh)
        XCTAssertTrue(reloaded.allSummaries().last?.energyQuality?.hasUnmeasuredSleepEnergy == true)
    }

    func testSettlementClearsMissingFlagOnlyWhenEveryLongSleepIsCovered() throws {
        let context = try Context()
        defer { context.cleanup() }
        let store = context.makeStore()
        let first = context.now.addingTimeInterval(-7200)
        let second = context.now.addingTimeInterval(-3600)
        store.recordSleepInterval(start: first, end: first.addingTimeInterval(60))
        store.recordSleepInterval(start: second, end: second.addingTimeInterval(60))
        store.recordSleepSegment(segment(start: first, end: first.addingTimeInterval(60)))
        XCTAssertTrue(store.allSummaries().last?.energyQuality?.hasUnmeasuredSleepEnergy == true)

        store.recordSleepSegment(segment(start: second, end: second.addingTimeInterval(60)))

        let quality = try XCTUnwrap(store.allSummaries().last?.energyQuality)
        XCTAssertFalse(quality.hasUnmeasuredSleepEnergy)
        XCTAssertTrue(quality.hasEstimatedSleepEnergy)
        XCTAssertTrue(store.allSummaries().last?.needsEnergyAttention == true)
    }

    func testUnsettledCrossMidnightSleepFlagsBothDaysAndSettlementDoesNotDoubleCount() throws {
        let context = try Context()
        defer { context.cleanup() }
        let midnight = Calendar.current.startOfDay(for: context.now)
        let start = midnight.addingTimeInterval(-1800)
        let end = midnight.addingTimeInterval(1800)
        let store = context.makeStore()
        store.recordSleepInterval(start: start, end: end)
        XCTAssertEqual(store.allSummaries().count, 2)
        XCTAssertTrue(store.allSummaries().allSatisfy { $0.energyQuality?.hasUnmeasuredSleepEnergy == true })

        let measured = segment(start: start, end: end, energy: 0.04)
        store.recordSleepSegment(measured)
        store.recordSleepSegment(measured)
        store.flush()

        XCTAssertEqual(store.allSummaries().compactMap(\.energyKWh), [0.02, 0.02])
        XCTAssertTrue(store.allSummaries().allSatisfy { $0.energyQuality?.hasUnmeasuredSleepEnergy == false })
        let reloaded = context.makeStore()
        XCTAssertEqual(reloaded.allSummaries().compactMap(\.energyKWh), [0.02, 0.02])
    }

    func testPartialSleepSegmentCannotHideTheRemainingUnmeasuredInterval() throws {
        let context = try Context()
        defer { context.cleanup() }
        let start = context.now.addingTimeInterval(-3600)
        let store = context.makeStore()
        store.recordSleepInterval(start: start, end: context.now)
        store.recordSleepSegment(segment(start: start, end: start.addingTimeInterval(60)))
        XCTAssertTrue(store.allSummaries().last?.energyQuality?.hasUnmeasuredSleepEnergy == true)
    }

    func testLoadBackfillsMissingSleepWarningWithoutRecalculatingAnOldTotal() throws {
        let context = try Context()
        defer { context.cleanup() }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: context.now)!
        let saved = summary(on: yesterday, energy: 0.789)
        try context.write(
            summaries: [saved],
            intervals: [SleepInterval(start: yesterday, end: yesterday.addingTimeInterval(3600))]
        )

        let store = context.makeStore()

        XCTAssertEqual(store.allSummaries().first?.energyKWh, saved.energyKWh)
        XCTAssertTrue(store.allSummaries().first?.energyQuality?.hasUnmeasuredSleepEnergy == true)
    }

    private func snapshot(at date: Date) -> BatterySnapshot {
        var snapshot = BatterySnapshot(timestamp: date)
        snapshot.isPresent = true
        snapshot.state = .discharging
        snapshot.voltage = 12
        snapshot.current = -2
        snapshot.percent = 50
        return snapshot
    }

    private func segment(start: Date, end: Date, energy: Double = 0.01) -> SleepSegment {
        SleepSegment(
            id: UUID(), start: start, end: end, energyKWh: energy,
            averagePowerW: energy * 3_600_000 / end.timeIntervalSince(start), mode: .discharging
        )
    }

    private func summary(on date: Date, energy: Double = 1) -> DailySummary {
        DailySummary(
            dayKey: BatteryFormatters.dayKey(for: date), date: Calendar.current.startOfDay(for: date),
            sampleCount: 10, maxCycleCount: 1, minHealthPercent: 100, energyKWh: energy,
            averagePower: 20, maxPower: 20, minPower: 20, energyQuality: DailyEnergyQuality()
        )
    }

    private struct Payload: Codable {
        var version = 8
        var samples: [HistorySample] = []
        var dailySummaries: [DailySummary]
        var sleepSegments: [SleepSegment] = []
        var sleepIntervals: [SleepInterval] = []
    }

    @MainActor
    private final class Context {
        let directory: URL
        let fileURL: URL
        let defaults: UserDefaults
        let settings: AppSettings
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        var now: Date
        private var stores: [BatteryHistoryStore] = []

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryGlassBoundary-\(UUID().uuidString)")
            fileURL = directory.appendingPathComponent("history.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suiteName)!
            settings = AppSettings(defaults: defaults)
            now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        }

        func makeStore(
            fileURL: URL? = nil,
            finishPendingSleepEnergy: @escaping () -> Void = {},
            cancelPendingSleepEnergy: @escaping () -> Void = {}
        ) -> BatteryHistoryStore {
            let store = BatteryHistoryStore(
                settings: settings, fileURL: fileURL ?? self.fileURL, now: { [unowned self] in self.now },
                finishPendingSleepEnergy: finishPendingSleepEnergy, cancelPendingSleepEnergy: cancelPendingSleepEnergy
            )
            stores.append(store)
            return store
        }

        func write(summaries: [DailySummary], intervals: [SleepInterval] = [], to url: URL? = nil) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let payload = Payload(dailySummaries: summaries, sleepIntervals: intervals)
            try encoder.encode(payload).write(to: url ?? fileURL)
        }

        func read() throws -> Payload {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Payload.self, from: Data(contentsOf: fileURL))
        }

        func cleanup() {
            for store in stores { store.flush() }
            stores = []
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
