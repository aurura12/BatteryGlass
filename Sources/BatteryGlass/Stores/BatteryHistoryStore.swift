import Foundation
import Observation

@MainActor
@Observable
final class BatteryHistoryStore {
    private(set) var samples: [HistorySample] = []
    private(set) var dailySummaries: [DailySummary] = []

    private let settings: AppSettings
    private let fileURL: URL
    private var observer: NSObjectProtocol?
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

    init(settings: AppSettings) {
        self.settings = settings
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = base.appendingPathComponent("BatteryGlass/history.json", isDirectory: false)
        load()

        observer = NotificationCenter.default.addObserver(
            forName: .batterySnapshotUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let snapshot = notification.userInfo?["snapshot"] as? BatterySnapshot else { return }
            Task { @MainActor in
                self?.record(snapshot)
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

    func summaries(lastDays: Int) -> [DailySummary] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -lastDays, to: Date()) else {
            return dailySummaries
        }
        return dailySummaries
            .filter { $0.date >= cutoff }
            .suffix(lastDays)
            .map { $0 }
    }

    func clearHistory() {
        samples = []
        dailySummaries = []
        lastRecordedSample = nil
        lastSamplesPrunedDay = nil
        lastPersistenceScheduledAt = .distantPast
        persistenceQueue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - 持久化

    private struct HistoryPayload: Codable, Sendable {
        var version: Int
        var samples: [HistorySample]
        var dailySummaries: [DailySummary]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(HistoryPayload.self, from: data) else { return }
        samples = payload.samples
        if payload.version >= 2 {
            dailySummaries = payload.dailySummaries
        } else {
            dailySummaries = summaries(from: samples)
        }
        lastRecordedSample = samples.last
        lastSamplesPrunedDay = nil
        pruneHistory()
    }

    private func persist() {
        let now = Date()
        guard now.timeIntervalSince(lastPersistenceScheduledAt) >= persistenceInterval else { return }
        lastPersistenceScheduledAt = now

        let payload = HistoryPayload(
            version: 2,
            samples: samples,
            dailySummaries: dailySummaries
        )
        let fileURL = self.fileURL
        persistenceQueue.async {
            Self.write(payload, to: fileURL)
        }
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
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) else { return }
        dailySummaries = dailySummaries.filter { $0.date >= cutoff }

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
