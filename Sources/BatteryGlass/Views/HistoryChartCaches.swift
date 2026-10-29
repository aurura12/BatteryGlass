import Foundation

/// 指定日期的样本记忆化：仅在样本数量、最后一条 id、内容版本或日期变化时重新过滤。
/// 诊断回填只替换读数、不改数量与 id，因此必须靠 `version` 判断失效。
final class TodaySamplesCache {
    private var cached: [HistorySample] = []
    private var lastCount = -1
    private var lastID: UUID?
    private var lastVersion = -1
    private var dayKey = ""

    func samples(from all: [HistorySample], day: Date, version: Int) -> [HistorySample] {
        let key = BatteryFormatters.dayKey(for: day)
        if lastCount == all.count, lastID == all.last?.id, lastVersion == version, dayKey == key {
            return cached
        }
        cached = HistoryRetention.samples(forDay: day, from: all)
        lastCount = all.count
        lastID = all.last?.id
        lastVersion = version
        dayKey = key
        return cached
    }
}

/// 功率曲线数据记忆化：仅在样本集合变化时重建（绘图最多 800 点）。
final class PowerChartDataCache {
    private var cached: PowerChartData?
    private var lastCount = -1
    private var lastID: UUID?
    private var lastVersion = -1

    func data(
        for samples: [HistorySample],
        sleepIntervals: [SleepInterval],
        version: Int
    ) -> PowerChartData {
        if let cached,
           lastCount == samples.count,
           lastID == samples.last?.id,
           lastVersion == version,
           cachedSleepIntervals == sleepIntervals {
            return cached
        }
        let data = PowerChartData(
            samples: samples,
            sleepIntervals: sleepIntervals,
            maximumDisplayedSamples: HistoryChartRendering.maximumDisplayedSamples,
            sourceVersion: version
        )
        cached = data
        lastCount = samples.count
        lastID = samples.last?.id
        lastVersion = version
        cachedSleepIntervals = sleepIntervals
        return data
    }

    private var cachedSleepIntervals: [SleepInterval] = []
}

/// 电量曲线数据记忆化：仅在样本集合变化时重建（绘图最多 800 点）。
final class BatteryLevelChartDataCache {
    private var cached: BatteryLevelChartData?
    private var lastCount = -1
    private var lastID: UUID?
    private var lastVersion = -1

    func data(for samples: [HistorySample], version: Int) -> BatteryLevelChartData {
        if let cached,
           lastCount == samples.count,
           lastID == samples.last?.id,
           lastVersion == version {
            return cached
        }
        let data = BatteryLevelChartData(
            samples: samples,
            maximumDisplayedSamples: HistoryChartRendering.maximumDisplayedSamples,
            sourceVersion: version
        )
        cached = data
        lastCount = samples.count
        lastID = samples.last?.id
        lastVersion = version
        return data
    }
}

/// 功率图可见段的记忆化：睡眠过滤、断点切分与降采样只在窗口或数据变化时重做。
/// 悬停只在吸附样本变化时注入高亮点，不再每移动一像素就重跑整段计算。
final class PowerChartSegmentCache {
    private struct Key: Equatable {
        var isZoomed: Bool
        var domainLower: Date
        var domainUpper: Date
        var sampleCount: Int
        var lastSampleID: UUID?
        var sourceVersion: Int
        var segmentCount: Int
        var sleepIntervals: [SleepInterval]
    }

    private var key: Key?
    private var visible: [[HistorySample]] = []
    private var rendered: [[HistorySample]] = []

    func segments(
        chartData: PowerChartData,
        sleepIntervals: [SleepInterval],
        isZoomed: Bool,
        dateDomain: ClosedRange<Date>
    ) -> (visible: [[HistorySample]], rendered: [[HistorySample]]) {
        let newKey = Key(
            isZoomed: isZoomed,
            domainLower: dateDomain.lowerBound,
            domainUpper: dateDomain.upperBound,
            sampleCount: chartData.plotSamples.count,
            lastSampleID: chartData.plotSamples.last?.id,
            sourceVersion: chartData.sourceVersion,
            segmentCount: chartData.fullSegments.count,
            sleepIntervals: sleepIntervals
        )
        if newKey == key { return (visible, rendered) }

        let visibleSegments = chartData.fullSegments.flatMap { segment in
            let visibleSamples = PowerChartWindow.samples(in: dateDomain, from: segment)
            let filtered = PowerChartSegmentation.excludingSleepIntervals(
                visibleSamples,
                sleepIntervals: sleepIntervals
            )
            return PowerChartSegmentation.splitByGaps(filtered, breakingAt: sleepIntervals)
        }
        // 概览态按可见窗口抽样；放大态保留完整段。
        let downsampled = isZoomed
            ? visibleSegments
            : HistoryChartRendering.downsampleSegmentsPreservingExtrema(
                visibleSegments,
                limit: HistoryChartRendering.maximumDisplayedSamples,
                value: { $0.consumptionPowerW }
            )
        key = newKey
        visible = visibleSegments
        rendered = downsampled
        return (visibleSegments, downsampled)
    }
}

/// 电量图分段、填充序列、缺口连线与 Y 域的联合记忆化。
/// 这四项都随窗口与样本集合变化，悬停移动时不必重算。
final class BatteryLevelSegmentCache {
    struct Result {
        var segments: [[HistorySample]]
        var fillSamples: [HistorySample]
        var bridges: [HistoryChartRendering.GapBridge]
        var yDomain: ClosedRange<Double>
    }

    private struct Key: Equatable {
        var isZoomed: Bool
        var domainLower: Date
        var domainUpper: Date
        var sampleCount: Int
        var lastSampleID: UUID?
        var sourceVersion: Int
    }

    private var key: Key?
    private var result = Result(segments: [], fillSamples: [], bridges: [], yDomain: 0...100)

    func data(
        chartData: BatteryLevelChartData,
        window: ChartZoomWindow,
        domain: ClosedRange<Date>
    ) -> Result {
        let newKey = Key(
            isZoomed: window.isZoomed,
            domainLower: domain.lowerBound,
            domainUpper: domain.upperBound,
            sampleCount: chartData.samples.count,
            lastSampleID: chartData.samples.last?.id,
            sourceVersion: chartData.sourceVersion
        )
        if newKey == key { return result }

        let segments: [[HistorySample]]
        let yDomain: ClosedRange<Double>
        if window.isZoomed {
            let visible = ChartViewport.visibleSamples(chartData.samples, in: domain)
            segments = HistoryChartRendering.downsampleSegmentsPreservingExtrema(
                PowerChartSegmentation.splitByGaps(visible),
                limit: HistoryChartRendering.maximumDisplayedSamples,
                value: { $0.percent }
            )
            yDomain = BatteryLevelAxis.yDomain(for: visible.map(\.percent))
        } else {
            segments = chartData.displayedSegments
            yDomain = chartData.percentDomain
        }

        let built = Result(
            segments: segments,
            fillSamples: segments.flatMap { $0 },
            bridges: HistoryChartRendering.gapBridges(segments),
            yDomain: yDomain
        )
        key = newKey
        result = built
        return built
    }
}

/// 日/周/月聚合记忆化：仅在汇总集合或分组方式变化时重算（内部需建字典并排序）。
final class DailyAggregateCache {
    private var cached: [EnergyAggregate] = []
    private var lastSummaries: [DailySummary] = []
    private var lastGrouping: EnergyGrouping?

    func aggregates(summaries: [DailySummary], grouping: EnergyGrouping) -> [EnergyAggregate] {
        if grouping == lastGrouping, summaries == lastSummaries {
            return cached
        }
        cached = EnergyAggregator.aggregate(summaries: summaries, grouping: grouping)
        lastSummaries = summaries
        lastGrouping = grouping
        return cached
    }
}
