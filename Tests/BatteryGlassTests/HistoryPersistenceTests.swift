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

    func testLowerBoundSleepSegmentEnergyIsCountedExactlyOnce() {
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
        // 起点锚定在「当天 10:00」而不是 `Date()`：若直接用当前时刻，在临近本地午夜
        // 运行时间隔会跨天，能量被按天切分，本用例会假失败（实测 23:12 运行时只剩
        // 跨天前的约 48 分钟能量）。
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(10 * 3_600)
        let end = start.addingTimeInterval(3600)
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

        // 睡前未插电、醒时已插电：能量只是下界，并带边界电源变化方向。
        let segment = SleepSegment(
            id: UUID(),
            start: start,
            end: end,
            energyKWh: 0.0142,
            averagePowerW: 14.2,
            mode: .charging,
            hasUnobservedSource: true,
            boundaryPowerChange: .batteryToAdapter
        )
        store.recordSleepSegment(segment)
        store.recordSleepSegment(segment)

        // 低估值标记不改变去重与累加：只记一次区间、只加一次能量。
        XCTAssertEqual(store.sleepSegments.count, 1)
        XCTAssertEqual(store.allSummaries().first?.energyKWh ?? 0, 0.0142, accuracy: 0.0000001)
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
        // v3 fixture 里没有 v5 新增的键：低估值默认 false，边界电源变化默认 nil。
        XCTAssertEqual(store.sleepSegments.first?.hasUnobservedSource, false)
        XCTAssertNil(store.sleepSegments.first?.boundaryPowerChange)
    }

    func testSleepSegmentWithSourceChangeRoundTripsThroughV5Payload() throws {
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

        // 睡前未插电、醒时已插电：能量只是下界，边界电源变化方向为电池→插座。
        let segment = SleepSegment(
            id: UUID(),
            start: date("2026-08-27 23:00:00"),
            end: date("2026-08-28 01:00:00"),
            energyKWh: 0.0122,
            averagePowerW: 6.1,
            mode: .charging,
            measurementMethod: .fallbackEstimate,
            isCalibrated: false,
            hasUnobservedSource: true,
            boundaryPowerChange: .batteryToAdapter
        )
        store.recordSleepSegment(segment)
        store.flush()

        let reloaded = BatteryHistoryStore(settings: settings, fileURL: fileURL)
        XCTAssertEqual(reloaded.sleepSegments, [segment])
        XCTAssertEqual(reloaded.sleepSegments.first?.boundaryPowerChange, .batteryToAdapter)
        XCTAssertTrue(reloaded.sleepSegments.first?.hasUnobservedSource == true)
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

    func testRecordDoesNotPersistTemperatureOnSample() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = BatteryHistoryStore(settings: AppSettings(defaults: defaults), fileURL: fileURL)
        var snapshot = BatterySnapshot()
        snapshot.isPresent = true
        snapshot.state = .discharging
        snapshot.percent = 50
        snapshot.temperatureCelsius = 35.2
        snapshot.cycleCount = 1
        store.record(snapshot)
        store.flush()

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(PersistedHistory.self, from: data)
        XCTAssertNotNil(payload.samples.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let samples = try XCTUnwrap(json["samples"] as? [[String: Any]])
        XCTAssertNil(samples.last?["temperatureCelsius"])
    }

    func testLegacyTemperatureFieldIsDiscardedWhenSampleIsReencoded() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let sampleJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","timestamp":"2026-08-27T10:00:00Z","power":-20,"consumptionPowerW":24,"percent":50,"cycleCount":1,"healthPercent":100,"temperatureCelsius":35.2}
        """
        let sample = try decoder.decode(HistorySample.self, from: Data(sampleJSON.utf8))
        let encoded = try JSONEncoder().encode(sample)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["temperatureCelsius"])
    }

    func testOpenSleepIntervalSurvivesExitAndClosesOnNextLaunch() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingPathExtension().appendingPathExtension("sqlite"))
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        let start = Date().addingTimeInterval(-8 * 60 * 60)
        let firstRun = BatteryHistoryStore(settings: settings, fileURL: fileURL)
        NotificationCenter.default.post(
            name: .sleepIntervalStarted, object: nil, userInfo: ["start": start]
        )
        firstRun.flush()

        let secondRun = BatteryHistoryStore(settings: settings, fileURL: fileURL)
        let wake = Date()
        secondRun.record(snapshot(at: wake, cycleCount: 10))

        XCTAssertEqual(secondRun.sleepIntervals.count, 1)
        let interval = try XCTUnwrap(secondRun.sleepIntervals.first)
        XCTAssertEqual(interval.start.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(interval.end.timeIntervalSince1970, wake.timeIntervalSince1970, accuracy: 1)
        // 睡眠期间没有观测，必须标成「未测量的睡眠」，而不是采样缺口。
        let todayKey = BatteryFormatters.dayKey(for: wake)
        let summary = secondRun.allSummaries().first { $0.dayKey == todayKey }
        XCTAssertEqual(summary?.energyQuality?.hasUnmeasuredSleepEnergy, true)
        XCTAssertNotEqual(summary?.energyQuality?.hasSamplingGaps, true)
    }

    func testRecoveredSleepIntervalIsCappedAtOneDay() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingPathExtension().appendingPathExtension("sqlite"))
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        let start = Date().addingTimeInterval(-72 * 60 * 60)
        let firstRun = BatteryHistoryStore(settings: settings, fileURL: fileURL)
        NotificationCenter.default.post(
            name: .sleepIntervalStarted, object: nil, userInfo: ["start": start]
        )
        firstRun.flush()

        let secondRun = BatteryHistoryStore(settings: settings, fileURL: fileURL)
        secondRun.record(snapshot(at: Date(), cycleCount: 10))

        let interval = try XCTUnwrap(secondRun.sleepIntervals.first)
        XCTAssertEqual(interval.end.timeIntervalSince(interval.start), 24 * 60 * 60, accuracy: 1)
    }

    func testCorruptHistoryFileDisablesPersistenceWithoutTouchingIt() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingPathExtension().appendingPathExtension("sqlite"))
            defaults.removePersistentDomain(forName: suiteName)
        }
        let corrupt = "{ not valid history"
        try corrupt.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = BatteryHistoryStore(settings: AppSettings(defaults: defaults), fileURL: fileURL)
        XCTAssertNotNil(store.persistenceIssue)

        store.record(snapshot(at: Date(), cycleCount: 3))
        store.flush()

        XCTAssertTrue(store.samples.isEmpty)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), corrupt)
    }

    func testBoundedFileReaderRejectsOversizedFileAndAcceptsExactLimit() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let payload = Data(repeating: 0x41, count: 4096)
        try payload.write(to: fileURL)

        XCTAssertEqual(BoundedFileReader.read(at: fileURL, maximumBytes: 4096), payload)
        XCTAssertNil(BoundedFileReader.read(at: fileURL, maximumBytes: 4095))
    }

    func testClearHistoryFailureKeepsDataInsteadOfReportingSuccess() throws {
        if getuid() == 0 { throw XCTSkip("root 可绕过目录权限，无法模拟删除失败") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("history.json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = BatteryHistoryStore(settings: AppSettings(defaults: defaults), fileURL: fileURL)
        store.record(snapshot(at: Date(), cycleCount: 5))
        store.flush()
        // 归档文件存在且父目录只读：删除必然失败。
        let archiveURL = fileURL.deletingPathExtension().appendingPathExtension("sqlite")
        XCTAssertTrue(FileManager.default.createFile(atPath: archiveURL.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        XCTAssertFalse(store.clearHistory())
        XCTAssertFalse(store.samples.isEmpty, "删除失败时不能清空内存数据")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSamplesAsyncLoadsArchivedDayWithoutBlockingMainThread() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingPathExtension().appendingPathExtension("sqlite"))
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        var now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let yesterdayNoon = now.addingTimeInterval(-24 * 60 * 60)
        let store = BatteryHistoryStore(settings: settings, fileURL: fileURL, now: { now })
        for index in 0..<3 {
            now = now.addingTimeInterval(5)
            store.record(snapshot(at: yesterdayNoon.addingTimeInterval(Double(index) * 5), cycleCount: index))
        }
        store.flush()

        let asyncStore = BatteryHistoryStore(settings: settings, fileURL: fileURL, now: { now })
        let loaded = await asyncStore.samplesAsync(forDay: yesterdayNoon)

        let syncStore = BatteryHistoryStore(settings: settings, fileURL: fileURL, now: { now })
        let expected = syncStore.samples(forDay: yesterdayNoon)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(loaded.map { $0.id }, expected.map { $0.id })
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
