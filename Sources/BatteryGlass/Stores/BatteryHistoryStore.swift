import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class BatteryHistoryStore {
    private(set) var samples: [HistorySample] = []
    private(set) var dailySummaries: [DailySummary] = []
    private(set) var sleepSegments: [SleepSegment] = []

    private let settings: AppSettings
    private let fileURL: URL
    private var observer: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var sleepSegmentObserver: NSObjectProtocol?
    private var lastRecord = Date.distantPast
    private var lastCycleCount = -1
    private var lastHealth: Double?
    private var lastRecordedSample: HistorySample?
    private var lastSamplesPrunedDay: Date?
    private let persistenceQueue = DispatchQueue(
        label: "com.batteryglass.history-persistence",
        qos: .utility
    )
    private var lastPersistenceScheduledAt = Date.distantPast
    private let persistenceInterval: TimeInterval = 15

    init(settings: AppSettings, fileURL: URL? = nil) {
        self.settings = settings
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = base.appendingPathComponent("BatteryGlass/history.json", isDirectory: false)
        }
        load()

        observer = NotificationCenter.default.addObserver(
            forName: .batterySnapshotUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let snapshot = notification.userInfo?["snapshot"] as? BatterySnapshot else { return }
            MainActor.assumeIsolated {
                self?.record(snapshot)
            }
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush()
            }
        }

        sleepSegmentObserver = NotificationCenter.default.addObserver(
            forName: .sleepSegmentRecorded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let segment = notification.userInfo?["segment"] as? SleepSegment else { return }
            MainActor.assumeIsolated {
                self?.recordSleepSegment(segment)
            }
        }
    }

    func record(_ snapshot: BatterySnapshot) {
        guard settings.recordHistory, snapshot.isPresent else { return }

        let now = Date()
        let significantChange = snapshot.cycleCount != lastCycleCount || snapshot.healthPercent != lastHealth
        guard now.timeIntervalSince(lastRecord) >= 5 || significantChange else { return }

        lastRecord = now
        lastCycleCount = snapshot.cycleCount
        lastHealth = snapshot.healthPercent

        let sample = HistorySample(
            timestamp: snapshot.timestamp,
            power: snapshot.power,
            consumptionPowerW: snapshot.consumptionPowerW,
            percent: snapshot.percent,
            cycleCount: snapshot.cycleCount,
            healthPercent: snapshot.healthPercent
        )

        samples.append(sample)
        updateSummary(with: sample)

        if let previous = lastRecordedSample {
            let intervalEnergy = EnergyCalculator.dailyEnergyKWh(samples: [previous, sample])
            for (dayKey, energy) in intervalEnergy {
                addEnergy(energy, to: dayKey)
            }
        }
        lastRecordedSample = sample
        pruneHistory()
        persist()
    }

    func samplesForDay(_ date: Date) -> [HistorySample] {
        HistoryRetention.samples(forDay: date, from: samples)
    }

    /// 记录一次待机区间：将其能量按跨天比例并入每日耗电量，并持久化。
    func recordSleepSegment(_ segment: SleepSegment) {
        sleepSegments.append(segment)
        sleepSegments.sort { $0.start < $1.start }
        addSleepEnergy(segment.energyKWh, from: segment.start, to: segment.end)
        persist()
    }

    func summaries(lastDays: Int) -> [DailySummary] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -lastDays, to: Date()) else {
            return dailySummaries
        }
        return dailySummaries
            .filter { $0.date >= cutoff }
            .suffix(lastDays)
            .map { $0 }
    }

    func allSummaries() -> [DailySummary] {
        dailySummaries
    }

    func clearHistory() {
        samples = []
        dailySummaries = []
        sleepSegments = []
        lastRecordedSample = nil
        lastSamplesPrunedDay = nil
        lastPersistenceScheduledAt = .distantPast
        persistenceQueue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// 退出前同步写入最新快照，避免异步保存尚未执行就结束进程。
    func flush() {
        let payload = makePayload()
        let fileURL = self.fileURL
        persistenceQueue.sync {
            Self.write(payload, to: fileURL)
        }
    }

    // MARK: - 持久化

    private struct HistoryPayload: Codable, Sendable {
        var version: Int
        var samples: [HistorySample]
        var dailySummaries: [DailySummary]
        // v3 新增；可选以兼容 v2 旧文件（缺失时解码为 nil）。
        var sleepSegments: [SleepSegment]?
    }

    private func load() {
        guard let data = BoundedFileReader.read(
            at: fileURL,
            maximumBytes: HistoryLoadLimits.maxHistoryFileBytes
        ) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(HistoryPayload.self, from: data) else { return }
        guard HistoryLoadLimits.acceptsHistory(
            sampleCount: payload.samples.count,
            summaryCount: payload.dailySummaries.count
        ) else { return }
        samples = payload.samples
        if payload.version >= 2 {
            dailySummaries = payload.dailySummaries
        } else {
            dailySummaries = summaries(from: samples)
        }
        if payload.version >= 3 {
            sleepSegments = payload.sleepSegments ?? []
        }
        let sanitizedSummaries = DailyEnergySummaryPolicy.markSparseLegacySummariesIncomplete(
            dailySummaries,
            todayKey: BatteryFormatters.dayKey(for: Date())
        )
        let summariesChanged = sanitizedSummaries != dailySummaries
        dailySummaries = sanitizedSummaries

        let recovery = HistorySampleRecovery.backfillConsumptionPower(
            in: samples,
            from: PowerDiagnosticsHistoryLoader.load()
        )
        if recovery.didChange {
            samples = recovery.samples
            updateEnergySummaries(
                from: samples,
                allowedDayKeys: [BatteryFormatters.dayKey(for: Date())]
            )
        }

        lastRecordedSample = samples.last
        lastSamplesPrunedDay = nil
        pruneHistory()

        if recovery.didChange || summariesChanged {
            flush()
        }
    }

    private func persist() {
        let now = Date()
        guard now.timeIntervalSince(lastPersistenceScheduledAt) >= persistenceInterval else { return }
        lastPersistenceScheduledAt = now

        let payload = makePayload()
        let fileURL = self.fileURL
        persistenceQueue.async {
            Self.write(payload, to: fileURL)
        }
    }

    private func makePayload() -> HistoryPayload {
        HistoryPayload(
            version: 3,
            samples: samples,
            dailySummaries: dailySummaries,
            sleepSegments: sleepSegments
        )
    }

    nonisolated private static func write(_ payload: HistoryPayload, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("BatteryGlass: 历史记录保存失败 - %@", error.localizedDescription)
        }
    }

    private func pruneHistory() {
        dailySummaries = DailyEnergySummaryPolicy.retainedSummaries(dailySummaries)

        let today = Calendar.current.startOfDay(for: Date())
        guard lastSamplesPrunedDay != today else { return }
        samples = HistoryRetention.samplesForCurrentDay(samples, now: Date())
        lastSamplesPrunedDay = today
    }

    private func summaries(from samples: [HistorySample]) -> [DailySummary] {
        let energyByDay = EnergyCalculator.dailyEnergyKWh(samples: samples)
        var grouped: [String: [HistorySample]] = [:]
        for sample in samples {
            grouped[BatteryFormatters.dayKey(for: sample.timestamp), default: []].append(sample)
        }

        dailySummaries = grouped.keys.sorted().compactMap { key in
            guard let samples = grouped[key], !samples.isEmpty else { return nil }
            let powers = samples.map(\.power)
            return DailySummary(
                dayKey: key,
                date: BatteryFormatters.dayKeyDate(key) ?? samples[0].timestamp,
                sampleCount: samples.count,
                maxCycleCount: samples.map(\.cycleCount).max() ?? 0,
                minHealthPercent: samples.compactMap(\.healthPercent).min(),
                energyKWh: energyByDay[key],
                averagePower: powers.reduce(0, +) / Double(powers.count),
                maxPower: powers.max() ?? 0,
                minPower: powers.min() ?? 0
            )
        }
        return dailySummaries
    }

    private func updateEnergySummaries(from samples: [HistorySample], allowedDayKeys: Set<String>) {
        let energyByDay = EnergyCalculator.dailyEnergyKWh(samples: samples)
        dailySummaries = DailyEnergySummaryPolicy.reconcile(
            summaries: dailySummaries,
            recalculatedEnergy: energyByDay,
            allowedDayKeys: allowedDayKeys
        )
    }

    private func updateSummary(with sample: HistorySample) {
        let key = BatteryFormatters.dayKey(for: sample.timestamp)
        if let index = dailySummaries.firstIndex(where: { $0.dayKey == key }) {
            var summary = dailySummaries[index]
            let count = Double(summary.sampleCount)
            summary.averagePower = (summary.averagePower * count + sample.power) / (count + 1)
            summary.sampleCount += 1
            summary.maxCycleCount = max(summary.maxCycleCount, sample.cycleCount)
            if let health = sample.healthPercent {
                summary.minHealthPercent = min(summary.minHealthPercent ?? health, health)
            }
            summary.maxPower = max(summary.maxPower, sample.power)
            summary.minPower = min(summary.minPower, sample.power)
            dailySummaries[index] = summary
        } else {
            dailySummaries.append(
                DailySummary(
                    dayKey: key,
                    date: BatteryFormatters.dayKeyDate(key) ?? sample.timestamp,
                    sampleCount: 1,
                    maxCycleCount: sample.cycleCount,
                    minHealthPercent: sample.healthPercent,
                    energyKWh: nil,
                    averagePower: sample.power,
                    maxPower: sample.power,
                    minPower: sample.power
                )
            )
            dailySummaries.sort { $0.date < $1.date }
        }
    }

    private func addEnergy(_ energy: Double, to dayKey: String) {
        guard energy.isFinite, energy >= 0 else { return }
        guard let index = dailySummaries.firstIndex(where: { $0.dayKey == dayKey }) else { return }
        dailySummaries[index].energyKWh = (dailySummaries[index].energyKWh ?? 0) + energy
    }

    /// 把待机区间能量按跨天时长比例拆分到对应日期。
    private func addSleepEnergy(_ energyKWh: Double, from start: Date, to end: Date) {
        let split = SleepEnergyCalculator.dailyEnergySplit(energyKWh: energyKWh, from: start, to: end)
        for (dayKey, energy) in split {
            addEnergy(energy, to: dayKey)
        }
    }
}

enum HistoryRetention {
    static func samples(
        forDay date: Date,
        from samples: [HistorySample],
        calendar: Calendar = .current
    ) -> [HistorySample] {
        let dayStart = calendar.startOfDay(for: date)
        guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }

        return samples.filter { sample in
            sample.timestamp >= dayStart && sample.timestamp < nextDayStart
        }
    }

    static func samplesForCurrentDay(
        _ samples: [HistorySample],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HistorySample] {
        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart),
              let previousDayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else {
            return samples
        }
        let previousDaySample = samples
            .filter { $0.timestamp >= previousDayStart && $0.timestamp < todayStart }
            .max { $0.timestamp < $1.timestamp }

        return samples
            .filter { $0.timestamp >= todayStart && $0.timestamp < tomorrowStart }
            .appendingIfNeeded(previousDaySample)
            .sorted { $0.timestamp < $1.timestamp }
    }
}

private extension Array where Element == HistorySample {
    func appendingIfNeeded(_ sample: HistorySample?) -> [HistorySample] {
        guard let sample, !contains(where: { $0.id == sample.id }) else { return self }
        return self + [sample]
    }
}
