import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class BatteryHistoryStore {
    private(set) var samples: [HistorySample] = []
    private(set) var dailySummaries: [DailySummary] = []
    private(set) var sleepSegments: [SleepSegment] = []
    private(set) var sleepIntervals: [SleepInterval] = []

    private let settings: AppSettings
    private let fileURL: URL
    private var observer: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var sleepSegmentObserver: NSObjectProtocol?
    private var sleepIntervalStartedObserver: NSObjectProtocol?
    private var sleepIntervalEndedObserver: NSObjectProtocol?
    private var activeSleepStart: Date?
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

        sleepIntervalStartedObserver = NotificationCenter.default.addObserver(
            forName: .sleepIntervalStarted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let start = notification.userInfo?["start"] as? Date else { return }
            MainActor.assumeIsolated {
                self?.beginSleepInterval(at: start)
            }
        }

        sleepIntervalEndedObserver = NotificationCenter.default.addObserver(
            forName: .sleepIntervalEnded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let start = notification.userInfo?["start"] as? Date,
                  let end = notification.userInfo?["end"] as? Date else { return }
            MainActor.assumeIsolated {
                self?.recordSleepInterval(start: start, end: end)
                self?.activeSleepStart = nil
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
            let excludedIntervals = currentExcludedSleepIntervals
            let intervalEnergy = EnergyCalculator.dailyEnergyKWh(
                samples: [previous, sample],
                excludedIntervals: excludedIntervals
            )
            for (dayKey, energy) in intervalEnergy {
                addEnergy(energy, to: dayKey)
                updateEnergyQuality(for: dayKey) { _ in }
            }
            let duration = sample.timestamp.timeIntervalSince(previous.timestamp)
            let overlapsKnownSleep = excludedIntervals.contains {
                $0.overlaps(previous.timestamp, sample.timestamp)
            }
            if duration > EnergyCalculator.maximumGap, !overlapsKnownSleep {
                markSamplingGap(from: previous.timestamp, to: sample.timestamp)
            }
        }
        lastRecordedSample = sample
        pruneHistory()
        persist()
    }

    /// 记录一次待机区间：将其能量按跨天比例并入每日耗电量，并持久化。
    func recordSleepSegment(_ segment: SleepSegment) {
        guard settings.recordHistory else { return }
        guard !sleepSegments.contains(where: { $0.id == segment.id }) else { return }

        sleepSegments.append(segment)
        sleepSegments.sort { $0.start < $1.start }
        addSleepEnergy(segment)
        // Persist after the segment and its daily energy are in memory. Calling the interval
        // recorder first could schedule a snapshot before the segment, then hit the throttle.
        recordSleepInterval(start: segment.start, end: segment.end)
        persist()
    }

    /// Opens a boundary before the wake snapshot arrives so no sample pair can bridge sleep.
    private func beginSleepInterval(at start: Date) {
        guard settings.recordHistory else { return }
        activeSleepStart = start
    }

    /// Persists a boundary without adding energy; a short sleep intentionally remains unknown.
    func recordSleepInterval(start: Date, end: Date) {
        guard settings.recordHistory, end > start else { return }
        guard !sleepIntervals.contains(where: { $0.start == start && $0.end == end }) else { return }

        sleepIntervals.append(SleepInterval(start: start, end: end))
        sleepIntervals.sort { $0.start < $1.start }
        persist()
    }

    func summaries(lastDays: Int) -> [DailySummary] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -lastDays, to: Date()) else {
            return dailySummaries
        }
        let cutoffKey = BatteryFormatters.dayKey(for: cutoff)
        return dailySummaries
            .filter { $0.dayKey >= cutoffKey }
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
        sleepIntervals = []
        activeSleepStart = nil
        lastRecordedSample = nil
        lastSamplesPrunedDay = nil
        lastPersistenceScheduledAt = .distantPast
        // 重置采样节流与显著变化基准，清空后立即恢复记录，避免头几条样本被跳过。
        lastRecord = .distantPast
        lastCycleCount = -1
        lastHealth = nil
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
        // v4 新增；可选以兼容 v2/v3 旧文件。
        var sleepIntervals: [SleepInterval]?
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
            // 统一按日期升序，保证依赖顺序的 suffix/UI 取最近 N 天正确。
            dailySummaries = payload.dailySummaries.sorted { $0.dayKey < $1.dayKey }
        } else {
            dailySummaries = summaries(from: samples)
        }
        if payload.version >= 3 {
            sleepSegments = payload.sleepSegments ?? []
        }
        sleepIntervals = (payload.sleepIntervals ?? []).filter { $0.end > $0.start }
        let sanitizedSummaries = DailyEnergySummaryPolicy.markSparseLegacySummariesIncomplete(
            dailySummaries,
            todayKey: BatteryFormatters.dayKey(for: Date()),
            dayKeysWithSleepEnergy: dayKeysWithSleepEnergy(in: dailySummaries)
        )
        let summariesChanged = sanitizedSummaries != dailySummaries
        dailySummaries = sanitizedSummaries
        let qualityBackfilled = markLegacyEnergyQualityUnknown()
        let sleepEnergyRestored = restoreMissingSleepEnergyFromSegments()
        let samplingGapsBackfilled = markKnownSamplingGaps(in: samples)

        let recovery = HistorySampleRecovery.backfillConsumptionPower(
            in: samples,
            from: PowerDiagnosticsHistoryLoader.load()
        )
        if recovery.didChange {
            samples = recovery.samples
            let recalculatedDayKeys = updateEnergySummaries(
                from: samples,
                allowedDayKeys: [BatteryFormatters.dayKey(for: Date())]
            )
            // 只有重算确实覆盖了今天，才需要把睡眠份额补回去。若今天没有可积分的
            // 相邻样本，reconcile 会保留已持久化的日值；再次累加睡眠份额会造成重计。
            let todayKey = BatteryFormatters.dayKey(for: Date())
            if recalculatedDayKeys.contains(todayKey) {
                restoreSleepEnergy(forToday: Date())
            }
        }

        lastRecordedSample = samples.last
        lastSamplesPrunedDay = nil
        pruneHistory()

        if recovery.didChange || summariesChanged || qualityBackfilled
            || sleepEnergyRestored || samplingGapsBackfilled {
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
            version: 5,
            samples: samples,
            dailySummaries: dailySummaries,
            sleepSegments: sleepSegments,
            sleepIntervals: sleepIntervals
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
        let energyByDay = EnergyCalculator.dailyEnergyKWh(
            samples: samples,
            excludedIntervals: sleepIntervals
        )
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

    private func updateEnergySummaries(
        from samples: [HistorySample],
        allowedDayKeys: Set<String>
    ) -> Set<String> {
        let energyByDay = EnergyCalculator.dailyEnergyKWh(
            samples: samples,
            excludedIntervals: sleepIntervals
        )
        dailySummaries = DailyEnergySummaryPolicy.reconcile(
            summaries: dailySummaries,
            recalculatedEnergy: energyByDay,
            allowedDayKeys: allowedDayKeys
        )
        return Set(energyByDay.keys).intersection(allowedDayKeys)
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
            dailySummaries.sort { $0.dayKey < $1.dayKey }
        }
    }

    private func addEnergy(_ energy: Double, to dayKey: String, creatingMissingSummary: Bool = false) {
        guard energy.isFinite, energy >= 0 else { return }
        if let index = dailySummaries.firstIndex(where: { $0.dayKey == dayKey }) {
            dailySummaries[index].energyKWh = (dailySummaries[index].energyKWh ?? 0) + energy
            return
        }
        guard creatingMissingSummary, ensureDailySummary(for: dayKey) != nil,
              let index = dailySummaries.firstIndex(where: { $0.dayKey == dayKey }) else {
            return
        }
        dailySummaries[index].energyKWh = energy
    }

    /// Split sleep energy and provenance across the local days touched by the segment.
    private func addSleepEnergy(_ segment: SleepSegment) {
        let split = dailyEnergySplit(for: segment)
        for (dayKey, energy) in split {
            addEnergy(energy, to: dayKey, creatingMissingSummary: true)
            markSleepEnergyQuality(segment, for: dayKey)
        }
    }

    @discardableResult
    private func ensureDailySummary(for dayKey: String) -> Int? {
        if let index = dailySummaries.firstIndex(where: { $0.dayKey == dayKey }) {
            return index
        }
        guard let date = BatteryFormatters.dayKeyDate(dayKey) else { return nil }
        dailySummaries.append(
            DailySummary(
                dayKey: dayKey,
                date: date,
                sampleCount: 0,
                maxCycleCount: 0,
                minHealthPercent: nil,
                energyKWh: nil,
                averagePower: 0,
                maxPower: 0,
                minPower: 0
            )
        )
        dailySummaries.sort { $0.dayKey < $1.dayKey }
        return dailySummaries.firstIndex(where: { $0.dayKey == dayKey })
    }

    @discardableResult
    private func updateEnergyQuality(
        for dayKey: String,
        _ update: (inout DailyEnergyQuality) -> Void
    ) -> Bool {
        guard let index = ensureDailySummary(for: dayKey) else { return false }
        let previousQuality = dailySummaries[index].energyQuality
        var quality = previousQuality ?? DailyEnergyQuality()
        update(&quality)
        guard previousQuality != quality else { return false }
        dailySummaries[index].energyQuality = quality
        return true
    }

    @discardableResult
    private func markSamplingGap(from start: Date, to end: Date) -> Bool {
        var changed = false
        for dayKey in EnergyCalculator.dayKeys(from: start, to: end) {
            changed = updateEnergyQuality(for: dayKey) { $0.hasSamplingGaps = true } || changed
        }
        return changed
    }

    private func markKnownSamplingGaps(in samples: [HistorySample]) -> Bool {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var changed = false
        for pair in zip(sorted, sorted.dropFirst()) {
            let start = pair.0.timestamp
            let end = pair.1.timestamp
            guard end.timeIntervalSince(start) > EnergyCalculator.maximumGap,
                  !sleepIntervals.contains(where: { $0.overlaps(start, end) }) else {
                continue
            }
            changed = markSamplingGap(from: start, to: end) || changed
        }
        return changed
    }

    private func markSleepEnergyQuality(_ segment: SleepSegment, for dayKey: String) {
        updateEnergyQuality(for: dayKey) { quality in
            quality.hasEstimatedSleepEnergy = quality.hasEstimatedSleepEnergy
                || segment.measurementMethod == .fallbackEstimate
            quality.hasUncalibratedCounterEnergy = quality.hasUncalibratedCounterEnergy
                || (segment.measurementMethod == .telemetryCounter && !segment.isCalibrated)
            quality.hasLowerBoundSleepEnergy = quality.hasLowerBoundSleepEnergy
                || segment.hasUnobservedSource
        }
    }

    /// Old payloads have no provenance. Preserve that uncertainty while new observations accrue.
    private func markLegacyEnergyQualityUnknown() -> Bool {
        var changed = false
        for index in dailySummaries.indices
        where dailySummaries[index].energyKWh != nil && dailySummaries[index].energyQuality == nil {
            dailySummaries[index].energyQuality = DailyEnergyQuality(
                hasUnknownHistoricalCoverage: true
            )
            changed = true
        }
        return changed
    }

    /// Rebuild sleep-only days and values erased by older sparse-summary cleanup.
    /// Existing non-nil totals already include the segment and are left untouched.
    private func restoreMissingSleepEnergyFromSegments() -> Bool {
        var restoredDayKeys: Set<String> = []
        var restored = false
        for segment in sleepSegments {
            let split = dailyEnergySplit(for: segment)
            for (dayKey, energy) in split {
                if let index = ensureDailySummary(for: dayKey) {
                    if dailySummaries[index].energyKWh == nil {
                        dailySummaries[index].energyKWh = energy
                        restoredDayKeys.insert(dayKey)
                        restored = true
                    } else if restoredDayKeys.contains(dayKey) {
                        dailySummaries[index].energyKWh = (dailySummaries[index].energyKWh ?? 0) + energy
                        restored = true
                    }
                }
                markSleepEnergyQuality(segment, for: dayKey)
            }
        }
        return restored
    }

    private func dailyEnergySplit(for segment: SleepSegment) -> [String: Double] {
        segment.dailyEnergyByDayKey ?? SleepEnergyCalculator.dailyEnergySplit(
            energyKWh: segment.energyKWh,
            from: segment.start,
            to: segment.end
        )
    }

    private func dayKeysWithSleepEnergy(in summaries: [DailySummary]) -> Set<String> {
        var keys = Set(sleepSegments.flatMap { segment in
            dailyEnergySplit(for: segment).keys
        })
        // A persisted summary.date is an absolute midnight from the timezone active when it
        // was written. Protect matching sleep days even if the current timezone has changed.
        for summary in summaries {
            let dayStart = summary.date
            let dayEnd = dayStart.addingTimeInterval(26 * 60 * 60)
            if sleepSegments.contains(where: { $0.start < dayEnd && $0.end > dayStart }) {
                keys.insert(summary.dayKey)
            }
        }
        return keys
    }

    private var currentExcludedSleepIntervals: [SleepInterval] {
        var intervals = sleepIntervals
        if let activeSleepStart {
            intervals.append(
                SleepInterval(start: activeSleepStart, end: .distantFuture)
            )
        }
        return intervals
    }

    /// 把与今天有交集的待机区间能量补回今日汇总。
    /// 用于全量重算（如诊断回填）覆盖今天的 energyKWh 之后，该重算值不含待机能量。
    /// 只补今天份额：昨天/更早的汇总未被重算覆盖，其待机能量仍在原值中，重复累加会造成虚高。
    private func restoreSleepEnergy(forToday now: Date) {
        let todayKey = BatteryFormatters.dayKey(for: now)
        let todayStart = Calendar.current.startOfDay(for: now)
        for segment in sleepSegments where segment.end > todayStart {
            let split = dailyEnergySplit(for: segment)
            if let energy = split[todayKey] {
                addEnergy(energy, to: todayKey)
                markSleepEnergyQuality(segment, for: todayKey)
            }
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
