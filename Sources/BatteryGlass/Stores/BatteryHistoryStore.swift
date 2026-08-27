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
        if samples.count > 6000 {
            samples.removeFirst(samples.count - 6000)
        }
        rebuildSummaries()
        persist()
    }

    func samplesForDay(_ date: Date) -> [HistorySample] {
        let key = BatteryFormatters.dayKey(for: date)
        return samples.filter { BatteryFormatters.dayKey(for: $0.timestamp) == key }
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
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 持久化

    private struct HistoryPayload: Codable {
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
        rebuildSummaries()
        prune()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = HistoryPayload(
                version: 1,
                samples: samples,
                dailySummaries: dailySummaries
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

    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) else { return }
        let kept = samples.filter { $0.timestamp >= cutoff }
        if kept.count != samples.count {
            samples = kept
            rebuildSummaries()
            persist()
        }
    }

    private func rebuildSummaries() {
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
    }
}
