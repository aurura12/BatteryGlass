import Foundation
import XCTest
@testable import BatteryGlass

/// 采样断点标记的端到端行为：短促读数缺失不点亮整天、长时间断点要点亮、
/// 加载时会用回填后的样本重算今天（可自愈）。
@MainActor
final class SamplingGapQualityTests: XCTestCase {
    private var base: Date = Calendar.current.startOfDay(for: Date())
        .addingTimeInterval(12 * 60 * 60)

    private func makeStore(
        fileURL: URL,
        settings: AppSettings,
        now: @escaping () -> Date
    ) -> BatteryHistoryStore {
        BatteryHistoryStore(settings: settings, fileURL: fileURL, now: now)
    }

    private func makeSettings() -> (settings: AppSettings, defaults: UserDefaults, suiteName: String) {
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (AppSettings(defaults: defaults), defaults, suiteName)
    }

    private func dischargingSnapshot(at date: Date, current: Double) -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        snapshot.timestamp = date
        snapshot.isPresent = true
        snapshot.state = .discharging
        snapshot.percent = 50
        snapshot.voltage = 12
        snapshot.current = current
        return snapshot
    }

    private var todayKey: String { BatteryFormatters.dayKey(for: base) }

    private func todaySummary(in store: BatteryHistoryStore) -> DailySummary? {
        store.allSummaries().first { $0.dayKey == todayKey }
    }

    func testShortMissingReadingEpisodeDoesNotFlagToday() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let (settings, defaults, suiteName) = makeSettings()
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(
                at: fileURL.deletingPathExtension().appendingPathExtension("sqlite")
            )
            defaults.removePersistentDomain(forName: suiteName)
        }

        var clock = base
        let store = makeStore(fileURL: fileURL, settings: settings, now: { clock })

        // 首尾各有可积分区间（有能量），中间 15 秒读数缺失（3 条相邻区间各 5 秒），
        // 累计远低于 60 秒阈值 → 不应点亮整天告警。
        store.record(dischargingSnapshot(at: base, current: -2))
        clock = base.addingTimeInterval(5)
        store.record(dischargingSnapshot(at: clock, current: -2))
        for offset in [10.0, 15.0] {
            clock = base.addingTimeInterval(offset)
            store.record(dischargingSnapshot(at: clock, current: 0))
        }
        for offset in [20.0, 25.0] {
            clock = base.addingTimeInterval(offset)
            store.record(dischargingSnapshot(at: clock, current: -2))
        }

        let summary = todaySummary(in: store)
        XCTAssertNotNil(summary?.energyKWh)
        XCTAssertEqual(summary?.energyQuality?.hasSamplingGaps ?? false, false)
        XCTAssertEqual(summary?.needsEnergyAttention, false)
    }

    func testLongGapFlagsToday() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let (settings, defaults, suiteName) = makeSettings()
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(
                at: fileURL.deletingPathExtension().appendingPathExtension("sqlite")
            )
            defaults.removePersistentDomain(forName: suiteName)
        }

        var clock = base
        let store = makeStore(fileURL: fileURL, settings: settings, now: { clock })
        store.record(dischargingSnapshot(at: base, current: -2))

        // 5 分钟没有记录（例如退出期间），远超 60 秒 → 当天标记为不完整。
        clock = base.addingTimeInterval(300)
        store.record(dischargingSnapshot(at: clock, current: -2))

        XCTAssertEqual(todaySummary(in: store)?.energyQuality?.hasSamplingGaps, true)
    }

    func testAccumulatedMissingReadingsEventuallyFlagToday() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let (settings, defaults, suiteName) = makeSettings()
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(
                at: fileURL.deletingPathExtension().appendingPathExtension("sqlite")
            )
            defaults.removePersistentDomain(forName: suiteName)
        }

        var clock = base
        let store = makeStore(fileURL: fileURL, settings: settings, now: { clock })
        store.record(dischargingSnapshot(at: base, current: -2))

        // 相邻样本间距正常（5 秒），但连续约 12 分钟读不到功率：
        // 单次不足为奇，累计跨过门槛后应当告警。
        for index in 1...140 {
            clock = base.addingTimeInterval(Double(index) * 5)
            if index == 140 {
                // 末尾补一条有效读数，保证当天有可积分区间（能量不为空）。
                store.record(dischargingSnapshot(at: clock, current: -2))
            } else {
                store.record(dischargingSnapshot(at: clock, current: 0))
            }
        }

        XCTAssertEqual(todaySummary(in: store)?.energyQuality?.hasSamplingGaps, true)
    }

    func testLoadClearsStaleSamplingGapFlagForToday() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let (settings, defaults, suiteName) = makeSettings()
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(
                at: fileURL.deletingPathExtension().appendingPathExtension("sqlite")
            )
            defaults.removePersistentDomain(forName: suiteName)
        }

        // 落盘时今天被标了断点，但样本现在是连续有效的（例如功率读数已由诊断日志回填）。
        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "version": 7,
            "samples": [
                sampleJSON(at: base, formatter: formatter),
                sampleJSON(at: base.addingTimeInterval(5), formatter: formatter)
            ],
            "dailySummaries": [
                [
                    "dayKey": todayKey,
                    "date": formatter.string(from: base),
                    "sampleCount": 2,
                    "maxCycleCount": 1,
                    "energyKWh": 0.1,
                    "averagePower": -24.0,
                    "maxPower": -24.0,
                    "minPower": -24.0,
                    "energyQuality": [
                        "hasSamplingGaps": true,
                        "hasEstimatedSleepEnergy": false,
                        "hasUncalibratedCounterEnergy": false,
                        "hasLowerBoundSleepEnergy": false,
                        "hasUnknownHistoricalCoverage": false
                    ]
                ]
            ],
            "sleepSegments": [],
            "sleepIntervals": []
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: fileURL)

        let store = makeStore(fileURL: fileURL, settings: settings, now: { self.base })

        XCTAssertEqual(todaySummary(in: store)?.energyQuality?.hasSamplingGaps, false)
    }

    func testOvernightGapFlagsBothTheDepartureDayAndToday() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlass-\(UUID().uuidString).json")
        let (settings, defaults, suiteName) = makeSettings()
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(
                at: fileURL.deletingPathExtension().appendingPathExtension("sqlite")
            )
            defaults.removePersistentDomain(forName: suiteName)
        }

        // 昨晚 22:50 退出，今早 09:00 启动：中间 10 小时没在记录。
        let yesterdayEvening = base.addingTimeInterval(-11 * 60 * 60)
        let yesterdayKey = BatteryFormatters.dayKey(for: yesterdayEvening)
        var clock = yesterdayEvening
        let firstRun = makeStore(fileURL: fileURL, settings: settings, now: { clock })
        firstRun.record(dischargingSnapshot(at: yesterdayEvening, current: -2))
        firstRun.flush()

        clock = base.addingTimeInterval(-3 * 60 * 60)
        let secondRun = makeStore(fileURL: fileURL, settings: settings, now: { clock })
        secondRun.record(dischargingSnapshot(at: clock, current: -2))

        let yesterday = secondRun.allSummaries().first { $0.dayKey == yesterdayKey }
        XCTAssertEqual(
            yesterday?.energyQuality?.hasSamplingGaps, true,
            "跨午夜断点中属于昨天的部分必须标记，否则昨天会一直显示为完整"
        )
        XCTAssertEqual(todaySummary(in: secondRun)?.energyQuality?.hasSamplingGaps, true)
    }

    private func sampleJSON(at date: Date, formatter: ISO8601DateFormatter) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "timestamp": formatter.string(from: date),
            "power": -24.0,
            "consumptionPowerW": 24.0,
            "percent": 50.0,
            "cycleCount": 1,
            "healthPercent": 100.0
        ]
    }
}
