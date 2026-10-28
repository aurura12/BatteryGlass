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
    private(set) var archivedDays: [Date] = []

    private let settings: AppSettings
    private let fileURL: URL
    private let archive: HistorySampleArchive
    private let currentDate: () -> Date
    private let finishPendingSleepEnergy: () -> Void
    private let cancelPendingSleepEnergy: () -> Void
    private var historyClearedAt: Date?
    private var needsLegacyBackup = false
    private var canPersist = true
    /// 历史文件无法读取时的用户可见原因；非 nil 表示本次运行不会写入新记录。
    private(set) var persistenceIssue: String?
    @ObservationIgnored private var cachedArchiveDay: Date?
    @ObservationIgnored private var cachedArchiveSamples: [HistorySample] = []
    @ObservationIgnored private var cachedMergedSamples: [HistorySample] = []
    @ObservationIgnored private var cachedLiveCount = -1
    @ObservationIgnored private var cachedLiveLastID: UUID?
    @ObservationIgnored private var cachedAsOfDay: Date?
    @ObservationIgnored private var cachedAvailableDays: [Date] = []
    @ObservationIgnored private var cachedAvailableDaysCount = -1
    @ObservationIgnored private var cachedAvailableDaysLastID: UUID?
    @ObservationIgnored private var cachedArchivedDayCount = -1
    private var observer: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var sleepSegmentObserver: NSObjectProtocol?
    private var sleepIntervalStartedObserver: NSObjectProtocol?
    private var sleepIntervalEndedObserver: NSObjectProtocol?
    private var activeSleepStart: Date?
    /// 上次运行在睡眠中退出时留下的区间起点，等本次运行的第一条样本把它关闭。
    private var pendingSleepIntervalStart: Date?
    /// 跨进程恢复的睡眠区间上限：更长的离线时间按采样缺口处理，避免把关机数天当成一觉。
    private static let maximumRecoveredSleepInterval: TimeInterval = 24 * 60 * 60
    /// 按日累计的「未被积分覆盖的时长」，按成因分开记；跨天区间按比例拆分。
    /// 只有 `needsWarning` 成立才把当天标为采样断点。
    private var unaccountedByDay: [String: EnergyCalculator.DailyUnaccountedTime] = [:]
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

    /// 往日样本的降采样间隔：今天保持原生 ~5 秒精度，往日 1 分钟一条。
    private static let olderSampleResolution: TimeInterval = 60

    init(
        settings: AppSettings,
        fileURL: URL? = nil,
        now: @escaping () -> Date = { Date() },
        finishPendingSleepEnergy: @escaping () -> Void = {},
        cancelPendingSleepEnergy: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.currentDate = now
        self.finishPendingSleepEnergy = finishPendingSleepEnergy
        self.cancelPendingSleepEnergy = cancelPendingSleepEnergy
        let resolvedURL: URL
        if let fileURL {
            resolvedURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            resolvedURL = base.appendingPathComponent("BatteryGlass/history.json", isDirectory: false)
        }
        self.fileURL = resolvedURL
        self.archive = HistorySampleArchive(fileURL: resolvedURL.deletingPathExtension().appendingPathExtension("sqlite"))
        do {
            archivedDays = try archive.availableDays()
        } catch {
            NSLog("BatteryGlass: 曲线归档读取失败 - %@", error.localizedDescription)
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
        guard settings.recordHistory, snapshot.isPresent,
              acceptsHistory(startingAt: snapshot.timestamp) else { return }
        // 读不到旧文件时不能继续在内存里累积：那些样本既不会落盘，
        // 退出时还会连同旧数据一起丢失，只会让界面误以为仍在正常记录。
        guard canPersist else { return }

        let now = currentDate()
        closePendingSleepInterval(at: snapshot.timestamp)
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
            if duration > 0, !overlapsKnownSleep {
                recordUnaccountedTime(from: previous, to: sample)
            }
        }
        lastRecordedSample = sample
        pruneHistory()
        persist()
    }

    /// 记录一次待机区间：将其能量按跨天比例并入每日耗电量，并持久化。
    func recordSleepSegment(_ segment: SleepSegment) {
        guard settings.recordHistory, segment.end > segment.start,
              segment.energyKWh.isFinite, segment.energyKWh > 0,
              acceptsHistory(startingAt: segment.start) else { return }
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
        guard settings.recordHistory, acceptsHistory(startingAt: start) else { return }
        activeSleepStart = start
    }

    /// Persists a boundary without adding energy; a short sleep intentionally remains unknown.
    func recordSleepInterval(start: Date, end: Date) {
        guard settings.recordHistory, end > start,
              acceptsHistory(startingAt: start) else { return }

        if !sleepIntervals.contains(where: { $0.start == start && $0.end == end }) {
            sleepIntervals.append(SleepInterval(start: start, end: end))
            sleepIntervals.sort { $0.start < $1.start }
        }
        reconcileUnmeasuredSleepEnergyQuality()
        persist()
    }

    /// 关闭上次运行遗留的睡眠区间。
    ///
    /// 应用在睡眠中退出（系统重启、更新）时只能留下起点：唤醒时刻与维持功耗都没有观测。
    /// 下次启动的第一条样本即视为该区间的结束点，把它记成「未测量的睡眠」——既不把整段
    /// 离线时间算进能耗，也不会被误判成采样缺口。
    private func closePendingSleepInterval(at date: Date) {
        guard let start = pendingSleepIntervalStart else { return }
        pendingSleepIntervalStart = nil
        let end = min(date, start.addingTimeInterval(Self.maximumRecoveredSleepInterval))
        guard end > start else { return }
        recordSleepInterval(start: start, end: end)
    }

    func summaries(lastDays: Int) -> [DailySummary] {
        guard lastDays > 0 else { return [] }
        let today = Calendar.current.startOfDay(for: currentDate())
        guard let cutoff = Calendar.current.date(byAdding: .day, value: 1 - lastDays, to: today) else {
            return []
        }
        let cutoffKey = BatteryFormatters.dayKey(for: cutoff)
        let todayKey = BatteryFormatters.dayKey(for: today)
        return dailySummaries
            .filter { $0.dayKey >= cutoffKey && $0.dayKey <= todayKey }
    }

    func allSummaries() -> [DailySummary] {
        dailySummaries
    }

    /// Dates come from the archive index and the small live buffer, not all historical rows.
    func availableDays() -> [Date] {
        if cachedAvailableDaysCount != samples.count || cachedAvailableDaysLastID != samples.last?.id
            || cachedArchivedDayCount != archivedDays.count {
            cachedAvailableDays = Array(Set(archivedDays + HistoryRetention.availableDays(from: samples))).sorted()
            cachedAvailableDaysCount = samples.count
            cachedAvailableDaysLastID = samples.last?.id
            cachedArchivedDayCount = archivedDays.count
        }
        return cachedAvailableDays
    }

    /// Keep one archived day in memory. The live buffer remains observable for today's chart.
    func samples(forDay day: Date) -> [HistorySample] {
        let start = Calendar.current.startOfDay(for: day)
        if cachedArchiveDay != start {
            do {
                cachedArchiveSamples = try persistenceQueue.sync { try archive.samples(forDay: start) }
                cachedArchiveDay = start
                cachedLiveCount = -1
            } catch {
                NSLog("BatteryGlass: 曲线读取失败 - %@", error.localizedDescription)
                cachedArchiveSamples = []
                // 记住这次失败：否则每次进入该日都会重新打开 SQLite、全表扫描再失败，
                // 把偶发错误固化成反复的同步 IO。重启或切换日期后可再试。
                cachedArchiveDay = start
                cachedLiveCount = -1
            }
        }
        let today = Calendar.current.startOfDay(for: currentDate())
        if cachedLiveCount != samples.count || cachedLiveLastID != samples.last?.id || cachedAsOfDay != today {
            cachedMergedSamples = mergedSamples(
                cachedArchiveSamples, HistoryRetention.samples(forDay: start, from: samples)
            )
            cachedLiveCount = samples.count
            cachedLiveLastID = samples.last?.id
            cachedAsOfDay = today
        }
        return cachedMergedSamples
    }

    /// 异步读取某天样本：归档查询在持久化队列执行，避免放大窗口在 `body` 里同步等待
    /// 写事务（归档导入或 `history.json` 原子替换期间最长可阻塞 `busy_timeout`）。
    /// 结果写回与同步路径相同的缓存，持续刷新时不会重复解码。
    func samplesAsync(forDay day: Date) async -> [HistorySample] {
        let start = Calendar.current.startOfDay(for: day)
        if cachedArchiveDay != start {
            let archive = self.archive
            let loaded: [HistorySample]? = await withCheckedContinuation { continuation in
                persistenceQueue.async {
                    do {
                        continuation.resume(returning: try archive.samples(forDay: start))
                    } catch {
                        NSLog("BatteryGlass: 曲线异步读取失败 - %@", error.localizedDescription)
                        continuation.resume(returning: nil)
                    }
                }
            }
            guard let loaded else {
                // 读取失败时只展示热层样本，不回落到主线程同步查询；
                // 同时记住本次失败，避免每次刷新都重试同一次查询。
                cachedArchiveDay = start
                cachedArchiveSamples = []
                cachedLiveCount = -1
                return HistoryRetention.retainedSamples(
                    HistoryRetention.samples(forDay: start, from: samples),
                    now: currentDate(),
                    retentionDays: nil,
                    olderResolution: Self.olderSampleResolution
                )
            }
            cachedArchiveSamples = loaded
            cachedArchiveDay = start
            cachedLiveCount = -1
        }
        return samples(forDay: start)
    }

    /// Export explicitly reads the complete archive; normal charting only reads one day.
    func allCurveSamples() throws -> [HistorySample] {
        let archived = try persistenceQueue.sync { try archive.allSamples() }
        return mergedSamples(archived, samples)
    }

    /// 导出的异步版本：全量读取归档、解码、去重与排序都在持久化队列执行，主线程只取一次
    /// 热层快照。多年按分钟归档时同步版本会让设置页在读取期间整段卡死。
    /// 快照取到样本的先后不影响正确性：读取期间新追加的样本至多让导出少最后几秒的数据。
    func allCurveSamplesAsync() async throws -> [HistorySample] {
        let live = samples
        let now = currentDate()
        let olderResolution = Self.olderSampleResolution
        let archive = self.archive
        return try await withCheckedThrowingContinuation { continuation in
            persistenceQueue.async {
                do {
                    let archived = try archive.allSamples()
                    continuation.resume(
                        returning: Self.mergedSamples(
                            archive: archived, live: live,
                            now: now, olderResolution: olderResolution
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func mergedSamples(_ archived: [HistorySample], _ live: [HistorySample]) -> [HistorySample] {
        Self.mergedSamples(
            archive: archived, live: live,
            now: currentDate(), olderResolution: Self.olderSampleResolution
        )
    }

    /// 归档与热层样本的合并（去重 + 按保留策略降采样）。纯计算，导出时放到持久化队列执行，
    /// 避免把几十万条样本的字典与排序压在主线程上。
    nonisolated private static func mergedSamples(
        archive: [HistorySample],
        live: [HistorySample],
        now: Date,
        olderResolution: TimeInterval
    ) -> [HistorySample] {
        var byID = Dictionary(archive.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for sample in live { byID[sample.id] = sample }
        return HistoryRetention.retainedSamples(
            Array(byID.values), now: now, retentionDays: nil,
            olderResolution: olderResolution
        )
    }

    /// 清空全部历史与备份。删除失败时返回 false 并保持内存数据不变：
    /// 否则界面显示"已清空"，而磁盘上的归档仍在，重启后旧曲线会复活。
    @discardableResult
    func clearHistory() -> Bool {
        let failures: [String] = persistenceQueue.sync {
            var failures: [String] = []
            do {
                try archive.remove()
            } catch {
                failures.append("曲线归档：\(error.localizedDescription)")
            }
            for url in [fileURL, Self.legacyBackupURL(for: fileURL)]
            where FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            return failures
        }
        guard failures.isEmpty else {
            NSLog("BatteryGlass: 清空历史失败 - %@", failures.joined(separator: "；"))
            return false
        }
        Self.removeRepairBackups(for: fileURL)
        Self.removeTimestampedLegacyBackups(for: fileURL)

        historyClearedAt = currentDate()
        cancelPendingSleepEnergy()
        samples = []
        dailySummaries = []
        sleepSegments = []
        sleepIntervals = []
        unaccountedByDay = [:]
        activeSleepStart = nil
        pendingSleepIntervalStart = nil
        lastRecordedSample = nil
        lastSamplesPrunedDay = nil
        lastPersistenceScheduledAt = .distantPast
        // 重置采样节流与显著变化基准，清空后立即恢复记录，避免头几条样本被跳过。
        lastRecord = .distantPast
        lastCycleCount = -1
        lastHealth = nil
        archivedDays = []
        cachedArchiveDay = nil
        cachedArchiveSamples = []
        cachedMergedSamples = []
        cachedLiveCount = -1
        cachedAvailableDaysCount = -1
        needsLegacyBackup = false
        canPersist = true
        persistenceIssue = nil
        return true
    }

    private func acceptsHistory(startingAt date: Date) -> Bool {
        historyClearedAt.map { date >= $0 } ?? true
    }

    /// 退出前同步写入最新快照，避免异步保存尚未执行就结束进程。
    func flush() {
        guard canPersist else { return }
        // Complete the wake measurement before taking the persisted snapshot. This also
        // makes termination ordering independent of NotificationCenter observer order.
        finishPendingSleepEnergy()
        let payload = makePayload()
        let fileURL = self.fileURL
        let today = Calendar.current.startOfDay(for: currentDate())
        let didWrite = persistenceQueue.sync {
            Self.write(payload, to: fileURL, archive: archive, today: today, backupLegacy: needsLegacyBackup)
        }
        if didWrite { needsLegacyBackup = false }
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
        // v8 新增；退出时仍处于睡眠则记录区间起点，下次启动用首条样本关闭。
        // 可选字段，旧文件缺失时解码为 nil，无需迁移分支。
        var openSleepStart: Date?
        // v8 删除历史温度字段；旧文件里的 temperatureCelsius 会被 Codable 忽略。
    }

    private func load() {
        do {
            try Self.removeTemperatureHistoryFromLegacyBackup(at: Self.legacyBackupURL(for: fileURL))
        } catch {
            NSLog("BatteryGlass: 清理旧温度备份失败 - %@", error.localizedDescription)
        }
        do {
            try archive.removeTemperatureHistory()
        } catch {
            NSLog("BatteryGlass: 清理旧温度曲线失败 - %@", error.localizedDescription)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = BoundedFileReader.read(
            at: fileURL,
            maximumBytes: HistoryLoadLimits.maxHistoryFileBytes
        ) else {
            disablePersistence(reason: "文件无法读取或超过 20 MB 上限")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(HistoryPayload.self, from: data) else {
            disablePersistence(reason: "文件格式无法解析")
            return
        }
        guard HistoryLoadLimits.acceptsHistory(
            sampleCount: payload.samples.count,
            summaryCount: payload.dailySummaries.count
        ), payload.version <= 8 else {
            disablePersistence(reason: "样本数量超出上限或文件版本过新")
            return
        }
        needsLegacyBackup = payload.version < 7
        let temperatureHistoryNeedsRemoval = payload.version < 8
        samples = payload.samples
        if payload.version >= 2 {
            // 统一按日期升序，保证统计范围和明细展示的顺序一致。
            dailySummaries = payload.dailySummaries.sorted { $0.dayKey < $1.dayKey }
        } else {
            dailySummaries = summaries(from: samples)
        }
        if payload.version >= 3 {
            sleepSegments = payload.sleepSegments ?? []
        }
        sleepIntervals = (payload.sleepIntervals ?? []).filter { $0.end > $0.start }
        pendingSleepIntervalStart = payload.openSleepStart
        let sanitizedSummaries = DailyEnergySummaryPolicy.markSparseLegacySummariesIncomplete(
            dailySummaries,
            todayKey: BatteryFormatters.dayKey(for: currentDate()),
            dayKeysWithSleepEnergy: dayKeysWithSleepEnergy(in: dailySummaries)
        )
        let summariesChanged = sanitizedSummaries != dailySummaries
        dailySummaries = sanitizedSummaries
        let qualityBackfilled = markLegacyEnergyQualityUnknown()
        let sleepEnergyRestored = restoreMissingSleepEnergyFromSegments()
        let unmeasuredSleepBackfilled = reconcileUnmeasuredSleepEnergyQuality()

        let recovery = HistorySampleRecovery.backfillConsumptionPower(
            in: samples,
            from: PowerDiagnosticsHistoryLoader.load()
        )
        if recovery.didChange {
            samples = recovery.samples
            let recalculatedDayKeys = updateEnergySummaries(
                from: samples,
                allowedDayKeys: [BatteryFormatters.dayKey(for: currentDate())]
            )
            // 只有重算确实覆盖了今天，才需要把睡眠份额补回去。若今天没有可积分的
            // 相邻样本，reconcile 会保留已持久化的日值；再次累加睡眠份额会造成重计。
            let todayKey = BatteryFormatters.dayKey(for: currentDate())
            if recalculatedDayKeys.contains(todayKey) {
                restoreSleepEnergy(forToday: currentDate())
            }
        }
        // Check gaps after diagnostics recovery so a sample that was successfully restored
        // does not leave a stale "incomplete" warning on today's summary.
        let samplingGapsBackfilled = applyTodaySamplingGapQuality(in: samples)

        lastRecordedSample = samples.max { $0.timestamp < $1.timestamp }
        lastSamplesPrunedDay = nil
        pruneHistory()

        if recovery.didChange || summariesChanged || qualityBackfilled
            || sleepEnergyRestored || unmeasuredSleepBackfilled
            || samplingGapsBackfilled || temperatureHistoryNeedsRemoval {
            flush()
        }
    }

    /// 只停止本会话写盘，原文件保持原样：它可能来自更新版本，或只是暂时读不出来，
    /// 覆盖会让唯一一份数据永久消失。
    private func disablePersistence(reason: String) {
        canPersist = false
        persistenceIssue = reason
        NSLog("BatteryGlass: 历史记录已停用 - %@", reason)
    }

    private func persist() {
        guard canPersist else { return }
        let now = currentDate()
        guard now.timeIntervalSince(lastPersistenceScheduledAt) >= persistenceInterval else { return }
        lastPersistenceScheduledAt = now

        let payload = makePayload()
        let fileURL = self.fileURL
        let archive = self.archive
        let today = Calendar.current.startOfDay(for: now)
        // Migration must finish synchronously before ordinary background writes can replace
        // the legacy file, even if an earlier attempt failed.
        guard !needsLegacyBackup else { flush(); return }
        persistenceQueue.async {
            Self.write(payload, to: fileURL, archive: archive, today: today, backupLegacy: false)
        }
    }

    private func makePayload() -> HistoryPayload {
        HistoryPayload(
            version: 8,
            samples: samples,
            dailySummaries: dailySummaries,
            sleepSegments: sleepSegments,
            sleepIntervals: sleepIntervals,
            openSleepStart: activeSleepStart ?? pendingSleepIntervalStart
        )
    }

    nonisolated private static func legacyBackupURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("legacy.json")
    }

    nonisolated private static func removeRepairBackups(for fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path) else { return }
        let prefix = fileURL.lastPathComponent + ".before-counter-unit-repair-"
        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: fileURL.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey]
            )
            for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
                guard try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                try FileManager.default.removeItem(at: entry)
            }
        } catch {
            NSLog("BatteryGlass: 历史修复备份清理失败 - %@", error.localizedDescription)
        }
    }

    nonisolated private static func removeTemperatureHistoryFromLegacyBackup(at url: URL) throws {
        guard let data = BoundedFileReader.read(
            at: url,
            maximumBytes: HistoryLoadLimits.maxHistoryFileBytes
        ), data.range(of: Data("\"temperatureCelsius\"".utf8)) != nil else { return }
        guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var samples = payload["samples"] as? [[String: Any]] else { return }

        var changed = false
        for index in samples.indices {
            if samples[index].removeValue(forKey: "temperatureCelsius") != nil {
                changed = true
            }
        }
        guard changed else { return }

        payload["samples"] = samples
        let cleaned = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try cleaned.write(to: url, options: .atomic)
    }

    /// 把迁移前的 `history.json` 另存为 `history.legacy.json`。
    ///
    /// 已有备份时不覆盖：若本次待迁移文件与旧备份内容不同（例如上次迁移遗留的备份），
    /// 另存一份带时间戳的副本，保证任何一次迁移前的原始数据都留得下来。
    nonisolated private static func createLegacyBackup(from fileURL: URL, to backup: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: fileURL, to: backup)
            return
        }
        let source = try Data(contentsOf: fileURL)
        let existing = try Data(contentsOf: backup)
        guard source != existing else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let extra = fileURL.deletingPathExtension()
            .appendingPathExtension("legacy-\(stamp).json")
        guard !FileManager.default.fileExists(atPath: extra.path) else { return }
        try FileManager.default.copyItem(at: fileURL, to: extra)
    }

    /// 清理迁移时另存的带时间戳副本（主备份由调用方删除）。
    nonisolated private static func removeTimestampedLegacyBackups(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        let prefix = fileURL.deletingPathExtension().lastPathComponent + ".legacy-"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    nonisolated private static func liveSamples(_ samples: [HistorySample], today: Date) -> [HistorySample] {
        // The last pre-midnight point is required for energy integration after a restart.
        let previous = samples.last(where: { $0.timestamp < today })
        return (previous.map { [$0] } ?? []) + samples.filter { $0.timestamp >= today }
    }

    @discardableResult
    nonisolated private static func write(
        _ payload: HistoryPayload, to fileURL: URL, archive: HistorySampleArchive,
        today: Date, backupLegacy: Bool
    ) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if backupLegacy {
                let backup = legacyBackupURL(for: fileURL)
                try createLegacyBackup(from: fileURL, to: backup)
                do {
                    try removeTemperatureHistoryFromLegacyBackup(at: backup)
                } catch {
                    // 备份本身已建好；清理温度字段失败不该阻止写入，否则
                    // needsLegacyBackup 永远为真，每 15 秒都同步重试一次整笔写入。
                    NSLog("BatteryGlass: 旧备份温度字段清理失败 - %@", error.localizedDescription)
                }
            }
            // Commit archival rows before replacing the live snapshot. A crash between the
            // two writes is safe: the next attempt upserts the same minute buckets.
            try archive.store(payload.samples.filter { $0.timestamp < today })
            var livePayload = payload
            livePayload.samples = liveSamples(payload.samples, today: today)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(livePayload)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            NSLog("BatteryGlass: 历史记录保存失败 - %@", error.localizedDescription)
            return false
        }
    }

    private func pruneHistory() {
        dailySummaries = DailyEnergySummaryPolicy.retainedSummaries(dailySummaries)

        guard canPersist else { return }
        let today = Calendar.current.startOfDay(for: currentDate())
        guard lastSamplesPrunedDay != today else { return }
        // Retain every historical minute; eviction only removes rows from the live buffer
        // after the archive and new snapshot have both been saved successfully.
        samples = HistoryRetention.retainedSamples(
            samples,
            now: currentDate(),
            retentionDays: nil,
            olderResolution: Self.olderSampleResolution
        )
        let payload = makePayload()
        let didWrite = persistenceQueue.sync {
            Self.write(payload, to: fileURL, archive: archive, today: today, backupLegacy: needsLegacyBackup)
        }
        guard didWrite else { return }
        needsLegacyBackup = false
        let older = samples.filter { $0.timestamp < today }
        archivedDays = Array(Set(archivedDays + HistoryRetention.availableDays(from: older))).sorted()
        samples = Self.liveSamples(samples, today: today)
        cachedArchiveDay = nil
        cachedArchiveSamples = []
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

    /// 累计一段未被积分覆盖的时长（断点或任一端缺功率读数）。
    /// 达到成因对应的门槛才把日期标为采样断点——单次几秒的读数缺失对日合计没有实质影响。
    private func recordUnaccountedTime(from previous: HistorySample, to sample: HistorySample) {
        let duration = sample.timestamp.timeIntervalSince(previous.timestamp)
        guard duration > 0 else { return }
        let accountsForEnergy = duration <= EnergyCalculator.maximumGap
            && EnergyCalculator.isValidPower(previous.consumptionPowerW)
            && EnergyCalculator.isValidPower(sample.consumptionPowerW)
        guard !accountsForEnergy else { return }

        let isGap = duration > EnergyCalculator.maximumGap
        for segment in EnergyCalculator.daySegments(
            from: previous.timestamp,
            to: sample.timestamp
        ) {
            addUnaccounted(segment.seconds, isGap: isGap, to: segment.dayKey)
        }
    }

    private func addUnaccounted(_ seconds: TimeInterval, isGap: Bool, to dayKey: String) {
        var value = unaccountedByDay[dayKey] ?? EnergyCalculator.DailyUnaccountedTime()
        if isGap {
            value.gapSeconds += seconds
        } else {
            value.missingReadingSeconds += seconds
        }
        unaccountedByDay[dayKey] = value
        guard value.needsWarning else { return }
        updateEnergyQuality(for: dayKey) { $0.hasSamplingGaps = true }
    }

    /// 用回填后的样本重算「今天」未被积分覆盖的时长。
    ///
    /// 只判定今天：往日样本已降到 1 分钟一条，间隔本身就接近甚至超过 `maximumGap`，
    /// 据此重算会把往日全部误判成断点。今天始终保持原生精度，因此这里的结论是权威值——
    /// 既避免诊断回填前把已恢复的样本误标成缺口，也让当天状态能随样本补齐而自动消除。
    private func applyTodaySamplingGapQuality(in samples: [HistorySample]) -> Bool {
        let report = EnergyCalculator.unaccountedSecondsByDay(
            samples: samples,
            excludedIntervals: sleepIntervals
        )
        let todayKey = BatteryFormatters.dayKey(for: currentDate())
        // 只保留今天的累计值：往日没有全精度样本，不能据此继续累加。
        let today = report[todayKey] ?? EnergyCalculator.DailyUnaccountedTime()
        unaccountedByDay = [todayKey: today]
        // 没有缺口、当天也没有汇总时不要为了「清除标志」凭空造一条空 summary。
        guard today.needsWarning || dailySummaries.contains(where: { $0.dayKey == todayKey }) else {
            return false
        }
        return updateEnergyQuality(for: todayKey) { quality in
            quality.hasSamplingGaps = today.needsWarning
        }
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

    /// A long sleep without a measured/estimated segment must not look like complete data.
    /// Reconcile again after delayed settlement so only unresolved intervals keep the flag.
    @discardableResult
    private func reconcileUnmeasuredSleepEnergyQuality() -> Bool {
        var unmeasuredDays: Set<String> = []
        for interval in sleepIntervals
        where interval.end.timeIntervalSince(interval.start) >= SleepEnergyCalculator.minimumDuration {
            let isCovered = sleepSegments.contains { segment in
                segment.start <= interval.start && segment.end >= interval.end
                    && segment.energyKWh.isFinite && segment.energyKWh > 0
            }
            if !isCovered {
                unmeasuredDays.formUnion(EnergyCalculator.dayKeys(from: interval.start, to: interval.end))
            }
        }
        let previouslyFlagged = dailySummaries.filter {
            $0.energyQuality?.hasUnmeasuredSleepEnergy == true
        }.map(\.dayKey)
        var changed = false
        for dayKey in unmeasuredDays.union(previouslyFlagged) {
            let didChange = updateEnergyQuality(for: dayKey) {
                $0.hasUnmeasuredSleepEnergy = unmeasuredDays.contains(dayKey)
            }
            changed = didChange || changed
        }
        return changed
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
    /// Long-term retention by default: preserve today, thin older days to one point per minute.
    /// An explicit day limit is still available for bounded previews and compatibility tests.
    ///
    /// - 往日按 epoch 桶（`floor(timestamp / olderResolution)`）分组、**每桶保留最后一条**：
    ///   单次遍历即可完成，输出保持升序、条数只减不增；用 epoch 桶而非日历分钟可避免
    ///   DST 与分钟对齐问题。
    /// - 「每桶留最后一条」天然保留了跨午夜的那条边界样本，因此今天的能量插值边界不变。
    /// - 降采样只影响展示密度；已落盘的日聚合能量在 5 秒精度下算好，不会因此改变
    ///   （`load()` 的 `allowedDayKeys` 只含今天，不会用降采样后的样本重算旧日期）。
    static func retainedSamples(
        _ samples: [HistorySample],
        now: Date = Date(),
        retentionDays: Int? = nil,
        olderResolution: TimeInterval = 60,
        calendar: Calendar = .current
    ) -> [HistorySample] {
        let todayStart = calendar.startOfDay(for: now)
        let cutoffStart = retentionDays.flatMap {
            calendar.date(byAdding: .day, value: -(max($0, 1) - 1), to: todayStart)
        } ?? Date.distantPast
        guard olderResolution > 0 else {
            return samples.filter { $0.timestamp >= cutoffStart }
        }

        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var kept: [HistorySample] = []
        kept.reserveCapacity(sorted.count)
        var lastBucket: Double?

        for sample in sorted {
            if sample.timestamp >= todayStart {
                kept.append(sample)
                continue
            }
            guard sample.timestamp >= cutoffStart else { continue }

            let bucket = (sample.timestamp.timeIntervalSinceReferenceDate / olderResolution)
                .rounded(.down)
            if bucket == lastBucket {
                // 同一桶内后来者替换前一条 → 每桶保留最后一条。
                kept[kept.count - 1] = sample
            } else {
                kept.append(sample)
                lastBucket = bucket
            }
        }
        return kept
    }

    /// 有样本的本地日期（升序，各为当天 00:00），供放大窗口按天切换。
    static func availableDays(
        from samples: [HistorySample],
        calendar: Calendar = .current
    ) -> [Date] {
        var days: Set<Date> = []
        days.reserveCapacity(8)
        for sample in samples {
            days.insert(calendar.startOfDay(for: sample.timestamp))
        }
        return days.sorted()
    }

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
}
