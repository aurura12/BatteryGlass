import Foundation

/// Y 轴刻度：整齐步长刻度值 + 标签小数位，保证窄值域下相邻标签不会塌成同一个数字。
struct AxisTickScale: Equatable {
    /// 原样回传的值域，供 `.chartYScale(domain:)` 使用。
    let domain: ClosedRange<Double>
    /// 升序刻度值，均落在 `domain` 内（域非法时为空）。
    let values: [Double]
    /// 标签小数位。
    let fractionDigits: Int

    var labels: [String] { values.map(label(for:)) }

    func label(for value: Double) -> String {
        String(format: "%.\(fractionDigits)f", value)
    }
}

/// 用于耗电量柱图的整齐刻度值和自适应小数位。
enum EnergyAxisScale {
    /// 整齐步长候选（升序）。刻意不含 0.25 / 2.5：它们无法用对应位数的小数精确表达。
    private static let stepCandidates: [Double] = [
        0.001, 0.002, 0.005, 0.01, 0.02, 0.05,
        0.1, 0.2, 0.5, 1, 2, 5,
        10, 20, 50, 100, 200, 500, 1000
    ]
    /// 刻度数量区间：太少失去参考价值，太多在 138pt 高的图里会挤在一起。
    private static let tickCountRange = 3...5

    /// 在值域内挑「整齐」步长生成刻度，并按步长决定标签小数位。
    /// 刻度值经 `Double(index) * step` 生成（不做累加，避免浮点漂移），标签兜底去重。
    static func ticks(in domain: ClosedRange<Double>) -> AxisTickScale {
        let lower = domain.lowerBound
        let upper = domain.upperBound
        guard lower.isFinite, upper.isFinite, upper > lower else {
            return AxisTickScale(domain: domain, values: [], fractionDigits: 2)
        }

        let width = upper - lower
        for step in stepCandidates {
            let lowerRatio = lower / step
            let upperRatio = upper / step
            // 比值超出 Int 安全范围说明步长相对量级过小，转 Int 会溢出。
            guard lowerRatio.isFinite, upperRatio.isFinite,
                  abs(lowerRatio) < 1e15, abs(upperRatio) < 1e15 else { continue }
            let firstIndex = Int(ceil(lowerRatio - 1e-9))
            let lastIndex = Int(floor(upperRatio + 1e-9))
            let count = lastIndex - firstIndex + 1
            guard tickCountRange.contains(count) else { continue }

            let values = (firstIndex...lastIndex).map { Double($0) * step }
            var digits = fractionDigits(forStep: step)
            // 浮点噪声可能让两个刻度格式化后相同，加位兜底。
            while digits < 6, Set(values.map { String(format: "%.\(digits)f", $0) }).count != values.count {
                digits += 1
            }
            return AxisTickScale(domain: domain, values: values, fractionDigits: digits)
        }

        // 极端跨度：退化为下界 / 中点 / 上界三点。
        var digits = fractionDigits(forStep: max(width / 2, 0.001))
        while digits < 6, Set([lower, (lower + upper) / 2, upper]
            .map { String(format: "%.\(digits)f", $0) }).count != 3 {
            digits += 1
        }
        return AxisTickScale(domain: domain, values: [lower, (lower + upper) / 2, upper], fractionDigits: digits)
    }

    /// 步长对应的小数位：0.2 → 1、0.01 → 2、5 → 0。减去 1e-9 抵消 log10 的浮点噪声。
    static func fractionDigits(forStep step: Double) -> Int {
        guard step.isFinite, step > 0 else { return 0 }
        let exponent = -log10(step)
        guard exponent > 0 else { return 0 }
        return min(max(Int(ceil(exponent - 1e-9)), 0), 6)
    }
}

struct PowerChartData {
    let timeline: PowerChartTimeline
    /// Positive, finite readings used for chart bounds and hover snapping.
    let plotSamples: [HistorySample]
    /// Renderable runs split at no-power samples before downsampling.
    let plotSegments: [[HistorySample]]
    /// 未抽样的完整连续段：放大到窄窗口时用它渲染，避免整日降采样影响局部细节。
    let fullSegments: [[HistorySample]]

    let energySamples: [HistorySample]
    let chartSamples: [HistorySample]
    /// 源样本的内容版本：数量与末条 id 不变、只有读数被替换时（诊断回填）
    /// 让分段缓存失效，否则曲线会一直停在回填前的数据。
    let sourceVersion: Int

    init(samples: [HistorySample], maximumDisplayedSamples: Int, sourceVersion: Int = 0) {
        self.init(
            samples: samples,
            sleepIntervals: [],
            maximumDisplayedSamples: maximumDisplayedSamples,
            sourceVersion: sourceVersion
        )
    }

    init(
        samples: [HistorySample],
        sleepIntervals: [SleepInterval],
        maximumDisplayedSamples: Int,
        sourceVersion: Int = 0
    ) {
        self.sourceVersion = sourceVersion
        let energySamples = samples.filter { $0.consumptionPowerW != nil }
        self.energySamples = energySamples

        let validSegments = PowerChartSegmentation.splitForPowerTimeline(
            samples,
            sleepIntervals: sleepIntervals
        )
        self.timeline = PowerChartTimeline(segments: validSegments)
        self.fullSegments = validSegments
        let plotSegments = HistoryChartRendering.downsampleSegmentsPreservingExtrema(
            validSegments.filter { $0.count > 1 },
            limit: maximumDisplayedSamples,
            value: { $0.consumptionPowerW }
        )
        let plotSamples = validSegments.flatMap { $0 }
        self.plotSegments = plotSegments
        self.plotSamples = plotSamples

        guard maximumDisplayedSamples > 1,
              energySamples.count > maximumDisplayedSamples else {
            self.chartSamples = energySamples
            return
        }

        self.chartSamples = HistoryChartRendering.downsamplePreservingExtrema(
            energySamples,
            limit: maximumDisplayedSamples,
            value: { $0.consumptionPowerW }
        )
    }

}

struct PowerChartBreak: Equatable {
    var start: Date
    var end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// 仅用于绘图：在压缩后的缺口位置竖直连接两端实测功率，不补造历史样本。
struct PowerChartConnection: Identifiable {
    var id: UUID
    var position: Double
    var startPowerW: Double
    var endPowerW: Double
}

struct PowerChartAxisMark: Identifiable {
    var position: Double
    var date: Date?

    var id: Double { position }
}

struct PowerChartTimeline {
    let breaks: [PowerChartBreak]
    let connections: [PowerChartConnection]
    /// 每个断点之前的累计压缩时长（`removalPrefix[i]` = breaks[0..<i] 的时长之和）。
    private let removalPrefix: [TimeInterval]
    /// 断点在压缩坐标下的起点，随 `removalPrefix` 单调不减，供二分查找。
    private let breakStartPositions: [Double]

    init(segments: [[HistorySample]]) {
        var breaks: [PowerChartBreak] = []
        var connections: [PowerChartConnection] = []
        var removedDuration: TimeInterval = 0
        for (previous, next) in zip(segments, segments.dropFirst()) {
            guard let last = previous.last,
                  let first = next.first,
                  first.timestamp > last.timestamp else {
                continue
            }
            let interval = PowerChartBreak(start: last.timestamp, end: first.timestamp)
            breaks.append(interval)
            if let startPower = last.consumptionPowerW,
               let endPower = first.consumptionPowerW,
               startPower.isFinite, startPower > 0,
               endPower.isFinite, endPower > 0 {
                connections.append(PowerChartConnection(
                    id: last.id,
                    position: last.timestamp.timeIntervalSinceReferenceDate - removedDuration,
                    startPowerW: startPower,
                    endPowerW: endPower
                ))
            }
            removedDuration += interval.duration
        }
        self.breaks = breaks
        self.connections = connections

        var prefix: [TimeInterval] = []
        prefix.reserveCapacity(breaks.count + 1)
        var startPositions: [Double] = []
        startPositions.reserveCapacity(breaks.count)
        var removed: TimeInterval = 0
        for interval in breaks {
            prefix.append(removed)
            startPositions.append(interval.start.timeIntervalSinceReferenceDate - removed)
            removed += interval.duration
        }
        prefix.append(removed)
        self.removalPrefix = prefix
        self.breakStartPositions = startPositions
    }

    /// Maps wall-clock time onto a chart axis where no-power intervals take no width.
    /// 断点（待机 / 无读数缺口）不占横向空间：落在断点内的时刻全部映射到断点起点，
    /// 曲线在断点处直接跳到下一段，断点位置由轴上的 `//` 标记提示。
    func position(for date: Date) -> Double {
        // 断点按起点升序：二分找到最后一个 start <= date 的断点，再判断是否落在断点内。
        guard let index = lastBreakIndex(startingAtOrBefore: date) else {
            return date.timeIntervalSinceReferenceDate
        }
        let interval = breaks[index]
        if date <= interval.end {
            return breakStartPositions[index]
        }
        return date.timeIntervalSinceReferenceDate - removalPrefix[index + 1]
    }

    /// Converts a chart coordinate back to its corresponding wall-clock time.
    /// 落在被跳过的断点上时返回断点结束时刻（曲线在该处恢复）。
    func date(for position: Double) -> Date {
        guard let index = lastBreakIndex(atChartPosition: position) else {
            return Date(timeIntervalSinceReferenceDate: position)
        }
        return Date(timeIntervalSinceReferenceDate: position + removalPrefix[index + 1])
    }

    private func lastBreakIndex(startingAtOrBefore date: Date) -> Int? {
        var low = 0
        var high = breaks.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if breaks[mid].start <= date {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    private func lastBreakIndex(atChartPosition position: Double) -> Int? {
        var low = 0
        var high = breakStartPositions.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if breakStartPositions[mid] <= position {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// 真实时间是否落在断点内部（用于跳过断点里的整点刻度）。
    func isInsideBreak(_ date: Date) -> Bool {
        breaks.contains { $0.start < date && date < $0.end }
    }
}

/// 今日电量曲线数据：不做 `consumptionPowerW` 过滤（那会丢掉合法电量点），
/// 只按 `percent` 有效性做防御过滤，并预计算 Y 轴域供曲线渲染直接取用。
struct BatteryLevelChartData {
    /// 今日全量样本，供悬停吸附使用。
    let samples: [HistorySample]
    /// 抽样后的渲染样本，最多 `maximumDisplayedSamples` 条。
    let displayedSamples: [HistorySample]
    /// 按原始采样缺口切开的渲染段，避免降采样间距触发错误断线。
    let displayedSegments: [[HistorySample]]
    /// 由全量样本预计算的 Y 轴域（抽样可能丢极值，故不能用抽样集计算）。
    let percentDomain: ClosedRange<Double>
    /// 源样本的内容版本，供分段缓存判断是否要重建。
    let sourceVersion: Int

    init(samples: [HistorySample], maximumDisplayedSamples: Int, sourceVersion: Int = 0) {
        self.sourceVersion = sourceVersion
        let valid = samples.filter { $0.percent.isFinite }
        self.samples = valid
        self.percentDomain = BatteryLevelAxis.yDomain(for: valid.map(\.percent))

        let sourceSegments = PowerChartSegmentation.splitByGaps(valid)
        guard maximumDisplayedSamples > 1 else {
            self.displayedSegments = sourceSegments
            self.displayedSamples = valid
            return
        }

        let displayedSegments = HistoryChartRendering.downsampleSegmentsPreservingExtrema(
            sourceSegments,
            limit: maximumDisplayedSamples,
            value: { $0.percent }
        )
        self.displayedSegments = displayedSegments
        self.displayedSamples = displayedSegments.flatMap { $0 }
    }
}

/// 电量曲线坐标轴：纯函数，便于单元测试。
enum BatteryLevelAxis {
    /// X 轴域：`day` 当天 00:00 起，至少 60s 宽（避免刚过午夜时域退化）。
    ///
    /// - 今天：到 `now`（调用方传最后一条样本时间，避免父视图重绘造成范围抖动）。
    /// - 往日：到当天最后一刻；有样本时收在当天最后一条样本处，不留大片空白。
    static func xDomain(
        day: Date,
        now: Date = Date(),
        lastSample: Date? = nil,
        calendar: Calendar = .current
    ) -> ClosedRange<Date> {
        let start = calendar.startOfDay(for: day)
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)

        let end: Date
        if calendar.isDate(day, inSameDayAs: now) {
            end = max(now, start.addingTimeInterval(60))
        } else if let lastSample {
            end = min(nextDayStart, max(lastSample, start.addingTimeInterval(60)))
        } else {
            end = nextDayStart
        }
        return start...max(start.addingTimeInterval(60), end)
    }

    /// 便捷重载：取 `now` 所在的那一天（`now` 同时作为当天的结束时刻）。
    static func xDomain(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        xDomain(day: now, now: now, lastSample: nil, calendar: calendar)
    }

    /// Y 轴域：在 0…100 内加边距并保证最小跨度，避免近似平线被纵向放大成剧烈波动。
    static func yDomain(
        for percents: [Double],
        minimumSpan: Double = 10,
        padding: Double = 6
    ) -> ClosedRange<Double> {
        let values = percents.filter { $0.isFinite }.map { min(max($0, 0), 100) }
        guard let lowest = values.min(), let highest = values.max() else {
            return 0...100
        }

        let desiredSpan = min(max(highest - lowest + padding * 2, minimumSpan), 100)
        let center = (lowest + highest) / 2
        var lower = center - desiredSpan / 2
        var upper = center + desiredSpan / 2

        // 贴边时平移（而非压缩）窗口，保持最小跨度不被破坏。
        if lower < 0 {
            upper = min(100, upper - lower)
            lower = 0
        }
        if upper > 100 {
            lower = max(0, lower - (upper - 100))
            upper = 100
        }
        return lower...upper
    }
}

/// 合并重叠的睡眠区间，使逐样本查询不必扫描全部历史记录。
private struct SleepIntervalIndex {
    private let ranges: [Range<Date>]

    init(_ intervals: [SleepInterval]) {
        let sorted = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [Range<Date>] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.upperBound {
                if interval.end > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<interval.end
                }
            } else {
                merged.append(interval.start..<interval.end)
            }
        }
        ranges = merged
    }

    /// 合并后区间的终点递增；找到第一个结束于给定时刻之后的区间。
    private func firstEnding(after date: Date) -> Int {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].upperBound <= date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    func contains(_ date: Date) -> Bool {
        let index = firstEnding(after: date)
        return index < ranges.count && ranges[index].lowerBound <= date
    }

    func overlaps(_ start: Date, _ end: Date) -> Bool {
        guard end > start else { return false }
        let index = firstEnding(after: start)
        return index < ranges.count && ranges[index].lowerBound < end
    }
}

/// 把样本按时间缺口切分为连续段，供功率曲线缺口处断开渲染。
enum PowerChartSegmentation {
    /// Split the source timeline at missing/zero readings, sleeps, and long observation gaps.
    static func splitForPowerTimeline(
        _ samples: [HistorySample],
        sleepIntervals: [SleepInterval],
        maximumGap: TimeInterval = 300
    ) -> [[HistorySample]] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let sleepIndex = SleepIntervalIndex(sleepIntervals)
        var segments: [[HistorySample]] = []
        var current: [HistorySample] = []

        for sample in sorted {
            let isSleeping = sleepIndex.contains(sample.timestamp)
            guard !isSleeping,
                  let power = sample.consumptionPowerW,
                  power.isFinite,
                  power > 0 else {
                if !current.isEmpty {
                    segments.append(current)
                    current = []
                }
                continue
            }

            if let previous = current.last {
                let gap = sample.timestamp.timeIntervalSince(previous.timestamp)
                let crossesSleep = sleepIndex.overlaps(previous.timestamp, sample.timestamp)
                if gap > maximumGap || crossesSleep {
                    segments.append(current)
                    current = []
                }
            }
            current.append(sample)
        }

        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    /// Split whenever a sample has no usable positive power reading.
    static func splitByUnavailablePower(_ samples: [HistorySample]) -> [[HistorySample]] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var segments: [[HistorySample]] = []
        var current: [HistorySample] = []

        for sample in sorted {
            guard let power = sample.consumptionPowerW, power.isFinite, power > 0 else {
                if !current.isEmpty {
                    segments.append(current)
                    current = []
                }
                continue
            }
            current.append(sample)
        }

        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    /// 相邻样本间隔超过 `maximumGap` 秒处断开，返回连续子段数组。
    static func splitByGaps(
        _ samples: [HistorySample],
        maximumGap: TimeInterval = 300,
        breakingAt sleepIntervals: [SleepInterval] = []
    ) -> [[HistorySample]] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard let first = sorted.first else { return [] }
        let sleepIndex = SleepIntervalIndex(sleepIntervals)

        var segments: [[HistorySample]] = [[first]]
        for sample in sorted.dropFirst() {
            guard let last = segments[segments.count - 1].last else { continue }
            let crossesSleepInterval = sleepIndex.overlaps(last.timestamp, sample.timestamp)
            if sample.timestamp.timeIntervalSince(last.timestamp) > maximumGap || crossesSleepInterval {
                segments.append([sample])
            } else {
                segments[segments.count - 1].append(sample)
            }
        }
        return segments
    }

    /// Remove any readings captured during system sleep before splitting at sleep boundaries.
    static func excludingSleepIntervals(
        _ samples: [HistorySample],
        sleepIntervals: [SleepInterval]
    ) -> [HistorySample] {
        guard !sleepIntervals.isEmpty else { return samples }
        let sleepIndex = SleepIntervalIndex(sleepIntervals)
        return samples.filter { !sleepIndex.contains($0.timestamp) }
    }

    /// 过滤掉落在任一待机区间时间范围内的样本。
    static func excludingSleepSegments(
        _ samples: [HistorySample],
        sleepSegments: [SleepSegment]
    ) -> [HistorySample] {
        guard !sleepSegments.isEmpty else { return samples }
        return samples.filter { sample in
            !sleepSegments.contains { $0.start <= sample.timestamp && sample.timestamp <= $0.end }
        }
    }
}

enum PowerChartWindow {
    static let defaultVisibleDuration: TimeInterval = 7_200

    static func samples(
        in domain: ClosedRange<Date>,
        from samples: [HistorySample]
    ) -> [HistorySample] {
        samples.filter { domain.contains($0.timestamp) }
    }

    /// 曲线坐标（秒，已跳过断点）下的可滚动范围：数据不足一屏时返回 nil（不显示滑块）。
    /// 滑块以曲线坐标为单位，拖动时可见窗口等宽平移，横向比例保持不变。
    static func scrollBounds(
        timeline: PowerChartTimeline,
        samples: [HistorySample],
        visibleDuration: TimeInterval = defaultVisibleDuration
    ) -> ClosedRange<Double>? {
        guard let first = samples.first?.timestamp,
              let latest = samples.last?.timestamp else {
            return nil
        }

        let start = timeline.position(for: first)
        let end = timeline.position(for: latest)
        guard end - start > visibleDuration else { return nil }
        return start...(end - visibleDuration)
    }

    /// 曲线坐标下的可见窗口：以 `position` 为起点、固定 `visibleDuration` 宽（末端不超过 `end`）。
    /// 宽度与窗口内容无关，因此滑动时横向比例恒定。
    static func visibleChartDomain(
        startingAt position: Double,
        end: Double,
        visibleDuration: TimeInterval = defaultVisibleDuration
    ) -> ClosedRange<Double> {
        let upper = min(end, position + visibleDuration)
        return position...max(position + 1, upper)
    }

    static func shouldFollowLatest(
        currentPosition: Double,
        previousEnd: Double,
        tolerance: TimeInterval = 10
    ) -> Bool {
        currentPosition >= previousEnd - tolerance
    }
}

enum PowerChartInteraction {
    /// 计算每日耗电量柱状图 tooltip 的锚点，并将 x 钳制在绘图区内，
    /// 避免悬停最早/最晚的柱子时 tooltip 溢出卡片边界。
    static func dailyTooltipAnchor(
        plotFrame: CGRect,
        xPosition: CGFloat,
        yPosition: CGFloat
    ) -> CGPoint {
        let rawX = plotFrame.minX + xPosition
        let rawY = plotFrame.minY + yPosition
        guard plotFrame.width > 140 else {
            return CGPoint(x: rawX, y: rawY)
        }
        return CGPoint(
            x: min(max(rawX, plotFrame.minX + 70), plotFrame.maxX - 70),
            y: rawY
        )
    }

    static func nearestSample(
        to timestamp: Date,
        from samples: [HistorySample]
    ) -> HistorySample? {
        guard !samples.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = samples.count - 1
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if samples[middle].timestamp < timestamp {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        let upper = samples[lowerBound]
        guard lowerBound > 0 else { return upper }

        let lower = samples[lowerBound - 1]
        let lowerDistance = abs(lower.timestamp.timeIntervalSince(timestamp))
        let upperDistance = abs(upper.timestamp.timeIntervalSince(timestamp))
        return lowerDistance <= upperDistance ? lower : upper
    }

    static func totalDailyEnergy(from summaries: [DailySummary]) -> Double? {
        let values = summaries.compactMap(\.energyKWh)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
}
