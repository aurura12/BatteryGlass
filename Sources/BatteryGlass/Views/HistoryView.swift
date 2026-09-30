import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(BatteryHistoryStore.self) private var history
    @Environment(ChartWindowController.self) private var chartWindow
    @State private var energyRange: EnergyHistoryRange = .fourteen
    // 面板以 2Hz 重渲染；用记忆化避免每次重算今日样本与曲线数据。
    @State private var todayCache = TodaySamplesCache()
    @State private var chartCache = PowerChartDataCache()
    @State private var levelChartCache = BatteryLevelChartDataCache()

    private var todaySamples: [HistorySample] {
        todayCache.samples(from: history.samples)
    }

    private var chartData: PowerChartData {
        chartCache.data(for: todaySamples, sleepIntervals: history.sleepIntervals)
    }

    private var levelChartData: BatteryLevelChartData {
        levelChartCache.data(for: todaySamples)
    }

    /// 跨天标识：变化时重置各图的缩放窗口。
    private var dayKey: String { BatteryFormatters.dayKey(for: Date()) }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.spacingM) {
                DailyEnergyComparisonChart(
                    summaries: energyRange.summaries(from: history),
                    range: $energyRange
                )

                TodayPowerChart(
                    chartData: chartData,
                    sleepIntervals: history.sleepIntervals,
                    dayKey: dayKey,
                    onExpand: { chartWindow.show(.power) }
                )
                // 跨天后以新的一天重建视图，重置时间滑块位置，
                // 避免 @State 停留在昨天的滚动位置导致曲线窗口错乱。
                .id(dayKey)

                TodayBatteryLevelChart(
                    chartData: levelChartData,
                    dayKey: dayKey,
                    onExpand: { chartWindow.show(.level) }
                )

                TodayMetricChart(
                    samples: todaySamples,
                    dayKey: dayKey,
                    onExpand: { metric in chartWindow.show(ExpandedChart(metric: metric)) }
                )
            }
            .padding(.bottom, DesignTokens.spacingXS)
        }
        .scrollIndicators(.hidden)
    }
}

/// 今日样本记忆化：仅在样本数量、最后一条 id 或日期变化时重新过滤。
final class TodaySamplesCache {
    private var cached: [HistorySample] = []
    private var lastCount = -1
    private var lastID: UUID?
    private var dayKey = ""

    func samples(from all: [HistorySample], now: Date = Date()) -> [HistorySample] {
        let key = BatteryFormatters.dayKey(for: now)
        if lastCount == all.count, lastID == all.last?.id, dayKey == key {
            return cached
        }
        cached = HistoryRetention.samples(forDay: now, from: all)
        lastCount = all.count
        lastID = all.last?.id
        dayKey = key
        return cached
    }
}

/// 功率曲线数据记忆化：仅在样本集合变化时重建（抽样到 800 点是 O(n) 开销）。
final class PowerChartDataCache {
    private var cached: PowerChartData?
    private var lastCount = -1
    private var lastID: UUID?

    func data(for samples: [HistorySample], sleepIntervals: [SleepInterval]) -> PowerChartData {
        if let cached,
           lastCount == samples.count,
           lastID == samples.last?.id,
           cachedSleepIntervals == sleepIntervals {
            return cached
        }
        let data = PowerChartData(
            samples: samples,
            sleepIntervals: sleepIntervals,
            maximumDisplayedSamples: 800
        )
        cached = data
        lastCount = samples.count
        lastID = samples.last?.id
        cachedSleepIntervals = sleepIntervals
        return data
    }

    private var cachedSleepIntervals: [SleepInterval] = []
}

/// 电量曲线数据记忆化：仅在样本集合变化时重建（抽样到 800 点是 O(n) 开销）。
final class BatteryLevelChartDataCache {
    private var cached: BatteryLevelChartData?
    private var lastCount = -1
    private var lastID: UUID?

    func data(for samples: [HistorySample]) -> BatteryLevelChartData {
        if let cached, lastCount == samples.count, lastID == samples.last?.id {
            return cached
        }
        let data = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 800)
        cached = data
        lastCount = samples.count
        lastID = samples.last?.id
        return data
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

enum EnergyHistoryRange: Int, CaseIterable, Identifiable {
    case seven = 7
    case fourteen = 14
    case thirty = 30
    case ninety = 90
    case all = 0

    var id: Int { rawValue }

    var title: String {
        rawValue == 0 ? "全部" : "近\(rawValue)天"
    }

    @MainActor
    func summaries(from history: BatteryHistoryStore) -> [DailySummary] {
        rawValue == 0 ? history.allSummaries() : history.summaries(lastDays: rawValue)
    }
}

enum DailyEnergyMetricOrder {
    static let today = "今日"
    static let average = "日均"
    static let total = "总计"
    static let titles = [today, average, total]
}

struct DailyDetailsDisclosureState {
    private(set) var isExpanded = false

    mutating func toggle() {
        isExpanded.toggle()
    }
}

struct DailyEnergyComparisonChart: View {
    let summaries: [DailySummary]
    @Binding var range: EnergyHistoryRange
    @State private var grouping: EnergyGrouping = .day
    @State private var hoveredAggregate: EnergyAggregate?
    @State private var dailyDetailsState = DailyDetailsDisclosureState()
    @State private var aggregateCache = DailyAggregateCache()

    private var energySummaries: [DailySummary] {
        summaries.filter { $0.energyKWh != nil }
    }

    private var aggregates: [EnergyAggregate] {
        aggregateCache.aggregates(summaries: energySummaries, grouping: grouping)
    }

    /// 柱图从 0 起算：Y 域取 0…峰值×1.1（至少 0.1 kWh），刻度走整齐步长 + 自适应小数位
    /// （固定 %.1f 会让 0.0x kWh 量级的刻度全塌成 "0.0"）。
    private var energyAxis: AxisTickScale {
        let peak = aggregates.map(\.energyKWh).max() ?? 0
        return MetricValueAxis.ticks(in: 0...max(peak * 1.1, 0.1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack {
                Text("\(grouping.chartTitle)（\(range.title)）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("分组", selection: $grouping) {
                    ForEach(EnergyGrouping.allCases) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.mini)
                .fixedSize()
            }

            Picker("统计范围", selection: $range) {
                ForEach(EnergyHistoryRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)

            if aggregates.isEmpty {
                ChartEmptyPlaceholder("暂无可用每日耗电量数据")
                    .frame(height: 138)
            } else {
                Chart(aggregates) { aggregate in
                    BarMark(
                        x: .value("日期", aggregate.periodStart),
                        y: .value("耗电量", aggregate.energyKWh)
                    )
                    .foregroundStyle(DesignTokens.dataBlue.gradient)
                    .cornerRadius(4)
                }
                .chartYScale(domain: energyAxis.domain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: energyAxis.values) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let raw = value.as(Double.self) {
                                Text(energyAxis.label(for: raw))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: xAxisLabelDates) { value in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick()
                        AxisValueLabel(centered: false, anchor: .top) {
                            if let date = value.as(Date.self) {
                                Text(xAxisLabel(for: date))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
                .chartXScale(domain: chartXDomain)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.clear)
                                .onContinuousHover { phase in
                                    updateHover(phase, proxy: proxy, geometry: geometry)
                                }

                            if let hoveredAggregate,
                               let anchor = tooltipAnchor(
                                   for: hoveredAggregate,
                                   proxy: proxy,
                                   geometry: geometry
                               ) {
                                hoverTooltip(for: hoveredAggregate)
                                    .alignmentGuide(.leading) { dimensions in
                                        dimensions.width / 2 - anchor.x
                                    }
                                    .alignmentGuide(.top) { dimensions in
                                        dimensions.height + 8 - anchor.y
                                    }
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(height: 138)
                .accessibilityLabel("每日耗电量图表")
                .accessibilityValue(energyAccessibilitySummary)

                comparisonMetrics
            }

            if !summaries.isEmpty {
                dailyDetails
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
    }

    /// VoiceOver 概要：周期数与总耗电量。
    private var energyAccessibilitySummary: String {
        guard !aggregates.isEmpty else { return "暂无数据" }
        let total = aggregates.map(\.energyKWh).reduce(0, +)
        return "共 \(aggregates.count) 个周期，总计 \(BatteryFormatters.energyKWh(total))"
    }

    private func updateHover(
        _ phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        switch phase {
        case .ended:
            hoveredAggregate = nil
        case .active(let location):
            guard let plotFrame = proxy.plotFrame else {
                hoveredAggregate = nil
                return
            }

            let frame = geometry[plotFrame]
            guard frame.contains(location) else {
                hoveredAggregate = nil
                return
            }

            let xPosition = location.x - frame.minX
            guard let date: Date = proxy.value(atX: xPosition) else {
                hoveredAggregate = nil
                return
            }

            hoveredAggregate = EnergyAggregator.nearestAggregate(to: date, from: aggregates)
        }
    }

    private func tooltipAnchor(
        for aggregate: EnergyAggregate,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> CGPoint? {
        guard let plotFrame = proxy.plotFrame,
              let xPosition = proxy.position(forX: aggregate.periodStart),
              let yPosition = proxy.position(forY: aggregate.energyKWh) else {
            return nil
        }

        return PowerChartInteraction.dailyTooltipAnchor(
            plotFrame: geometry[plotFrame],
            xPosition: xPosition,
            yPosition: yPosition
        )
    }

    private func hoverTooltip(for aggregate: EnergyAggregate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(aggregate.title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(BatteryFormatters.energyKWh(aggregate.energyKWh))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.dataBlue)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private func xAxisLabel(for date: Date) -> String {
        switch grouping {
        case .day:
            return BatteryFormatters.xAxisDayLabel(date)
        case .week:
            return BatteryFormatters.xAxisDayLabel(date)
        case .month:
            return BatteryFormatters.xAxisMonthLabel(date)
        }
    }

    private var chartXDomain: ClosedRange<Date> {
        guard let first = aggregates.first?.periodStart,
              let last = aggregates.last?.periodStart else {
            let fallback = Date()
            return fallback...fallback.addingTimeInterval(1)
        }

        let calendar = Calendar.current
        let previous = calendar.date(byAdding: grouping.xStride, value: -1, to: first) ?? first
        let next = calendar.date(byAdding: grouping.xStride, value: 1, to: last) ?? last
        let lower = Date(timeIntervalSinceReferenceDate:
            (previous.timeIntervalSinceReferenceDate + first.timeIntervalSinceReferenceDate) / 2
        )
        let upper = Date(timeIntervalSinceReferenceDate:
            (last.timeIntervalSinceReferenceDate + next.timeIntervalSinceReferenceDate) / 2
        )
        return lower...upper
    }

    private var xAxisLabelDates: [Date] {
        let dates = aggregates.map(\.periodStart)
        let maximumLabelCount = 5
        guard dates.count > maximumLabelCount else { return dates }

        let lastIndex = dates.count - 1
        return (0..<maximumLabelCount).map { position in
            let progress = Double(position) / Double(maximumLabelCount - 1)
            return dates[Int((progress * Double(lastIndex)).rounded())]
        }
    }

    private var comparisonMetrics: some View {
        HStack(spacing: DesignTokens.spacingM) {
            if grouping == .day {
                energyMetric(title: DailyEnergyMetricOrder.today, value: todayEnergy)
                Divider()
                    .frame(height: 24)
            }
            energyMetric(title: grouping == .day ? DailyEnergyMetricOrder.average : "周期均", value: averageEnergy)
            Divider()
                .frame(height: 24)
            energyMetric(title: DailyEnergyMetricOrder.total, value: totalEnergy)
        }
        .padding(.top, DesignTokens.spacingXS)
    }

    private func energyMetric(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value.map(BatteryFormatters.energyKWh) ?? "--")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.dataBlue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var todayEnergy: Double? {
        guard grouping == .day else { return nil }
        return aggregates.first { Calendar.current.isDateInToday($0.periodStart) }?.energyKWh
    }

    private var totalEnergy: Double? {
        guard !aggregates.isEmpty else { return nil }
        return aggregates.map(\.energyKWh).reduce(0, +)
    }

    private var averageEnergy: Double? {
        guard !aggregates.isEmpty else { return nil }
        return aggregates.map(\.energyKWh).reduce(0, +) / Double(aggregates.count)
    }

    private var dailyDetails: some View {
        VStack(spacing: DesignTokens.spacingXS) {
            Divider()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    dailyDetailsState.toggle()
                }
            } label: {
                HStack {
                    Text("每日明细")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: dailyDetailsState.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("每日明细")
            .accessibilityValue(dailyDetailsState.isExpanded ? "已展开" : "已收起")

            if dailyDetailsState.isExpanded {
                // 最多渲染最近 30 行以避免长期使用后「全部」范围渲染数千行；
                // 所选范围内不足 30 天时全部显示，超出部分在下方用一行轻量文案提示。
                ForEach(summaries.suffix(30).reversed()) { summary in
                    HStack {
                        Text(summary.dayKey)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let reason = energyQualityWarning(for: summary) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .help(reason)
                                .accessibilityLabel(Text(reason))
                        }
                        Spacer()
                        Text(summary.energyKWh.map(BatteryFormatters.energyKWh) ?? "--")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DesignTokens.dataBlue)
                    }
                    .padding(.vertical, 2)
                }
                if summaries.count > 30 {
                    Text("另有 \(summaries.count - 30) 天未显示")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.top, DesignTokens.spacingXS)
    }

    /// 生成日能耗质量角标的原因文案；`energyQuality` 缺失或全部标记为 false 时返回 nil。
    /// 多条原因按标记顺序以「；」拼接。
    private func energyQualityWarning(for summary: DailySummary) -> String? {
        guard let quality = summary.energyQuality else { return nil }
        var reasons: [String] = []
        if quality.hasSamplingGaps {
            reasons.append("当天存在超过 60 秒的采样断点，耗电量可能偏低")
        }
        if quality.hasEstimatedSleepEnergy {
            reasons.append("睡眠段为估算值（无可用计数器或未校准）")
        }
        if quality.hasUncalibratedCounterEnergy {
            reasons.append("睡眠段使用未校准的遥测计数器，数值可能有系统性偏差")
        }
        if quality.hasLowerBoundSleepEnergy {
            reasons.append("睡眠边界供电状态变化，仅统计到可观测来源，实际值不低于此")
        }
        if quality.hasUnknownHistoricalCoverage {
            reasons.append("旧版本记录，统计口径未知")
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "；")
    }
}

struct TodayPowerChart: View {
    let chartData: PowerChartData
    let sleepIntervals: [SleepInterval]
    /// 跨天标识：变化时重置缩放窗口。
    let dayKey: String
    /// 绘图区高度；nil 表示撑满剩余空间（放大浮层内使用）。
    let plotHeight: CGFloat?
    /// 非 nil 时在标题栏提供「放大查看」入口。
    let onExpand: (() -> Void)?

    /// 用户设定的缩放窗口；nil 表示跟随默认（贴最新一屏）。
    @State private var window: ChartZoomWindow?
    @State private var hoveredSample: HistorySample?
    @State private var hoverLocation: CGPoint?
    /// 悬停位置与吸附样本超过该间隔视为"无数据"（待机缺口内不显示 tooltip）。
    private let hoverMaximumGap: TimeInterval = 180
    /// 放大下限：1 分钟（5 秒一条时约 12 个点）。
    private static let minimumVisibleDuration: TimeInterval = 60

    private var energySamples: [HistorySample] { chartData.plotSamples }

    init(
        chartData: PowerChartData,
        sleepIntervals: [SleepInterval],
        dayKey: String = "",
        plotHeight: CGFloat? = 138,
        onExpand: (() -> Void)? = nil
    ) {
        self.chartData = chartData
        self.sleepIntervals = sleepIntervals
        self.dayKey = dayKey
        self.plotHeight = plotHeight
        self.onExpand = onExpand
    }

    var body: some View {
        // 帧内只算一次：这些计算属性含 O(样本数) 的筛选与 O(断点数) 的坐标换算，
        // 若直接写进逐样本的 ForEach，会被放大到 O(n²)（卡顿主因）。
        let activeWindow = effectiveWindow(for: window)
        let chartDomain = activeWindow.domain
        let dateDomain = visibleDateDomain(for: chartDomain)
        let tickUnit = ChartTimeAxis.unit(
            forSpan: dateDomain.upperBound.timeIntervalSince(dateDomain.lowerBound)
        )
        let tickFormat: Date.FormatStyle = tickUnit.includesMinutes
            ? Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)
            : Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted))
        let marks = axisMarks(in: dateDomain, unit: tickUnit, chartDomain: chartDomain)
        let segments = displaySegments(isZoomed: activeWindow.isZoomed, in: dateDomain)
        let sliderRange = panRange(for: activeWindow)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("今日功率曲线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if activeWindow.isZoomed {
                    Text("已放大")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if activeWindow.canPan {
                    Text("横向滚动查看")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                ChartZoomButton(kind: .zoomOut) {
                    $window.zoom(by: 1 / ChartZoomButton.step, effective: activeWindow)
                }
                ChartZoomButton(kind: .zoomIn) {
                    $window.zoom(by: ChartZoomButton.step, effective: activeWindow)
                }
                if window != nil {
                    ChartZoomResetButton { window = nil }
                }
                if let onExpand {
                    ChartExpandButton(action: onExpand)
                }
            }

            if chartData.plotSegments.isEmpty {
                ChartEmptyPlaceholder("暂无有效功率曲线")
                    .frame(height: 120)
            } else {
                VStack(spacing: 4) {
                    Chart {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            ForEach(segment) { sample in
                                AreaMark(
                                    x: .value("时间", chartData.timeline.position(for: sample.timestamp)),
                                    y: .value("功率", sample.consumptionPowerW ?? 0)
                                )
                                .interpolationMethod(.linear)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [DesignTokens.dataBlue.opacity(0.22), DesignTokens.dataBlue.opacity(0.02)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("时间", chartData.timeline.position(for: sample.timestamp)),
                                    y: .value("功率", sample.consumptionPowerW ?? 0)
                                )
                                .interpolationMethod(.linear)
                                .foregroundStyle(DesignTokens.dataBlue)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            }
                        }

                        if let hoveredSample,
                           let power = hoveredSample.consumptionPowerW {
                            RuleMark(
                                x: .value(
                                    "悬停时间",
                                    chartData.timeline.position(for: hoveredSample.timestamp)
                                )
                            )
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundStyle(DesignTokens.dataBlue.opacity(0.7))

                            PointMark(
                                x: .value(
                                    "时间",
                                    chartData.timeline.position(for: hoveredSample.timestamp)
                                ),
                                y: .value("功率", power)
                            )
                            .foregroundStyle(DesignTokens.dataBlue)
                            .symbolSize(36)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .chartXAxis {
                        AxisMarks(values: marks.map(\.position)) { value in
                            if let position = value.as(Double.self),
                               let mark = marks.min(by: {
                                   abs($0.position - position) < abs($1.position - position)
                               }) {
                                AxisGridLine().foregroundStyle(.clear)
                                AxisTick()
                                AxisValueLabel {
                                    if let date = mark.date {
                                        Text(date, format: tickFormat)
                                    } else {
                                        Text("//")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                    }
                                }
                            }
                        }
                    }
                    .chartXScale(domain: chartDomain)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            let plot = proxy.overlayPlotRect(in: geometry)
                            ZStack(alignment: .topTrailing) {
                                ChartPlotEventCatcher(
                                    onZoom: { factor, location in
                                        window = activeWindow.zoomed(
                                            by: Double(factor),
                                            anchorFraction: ChartZoomGestureMath.anchorFraction(
                                                for: location,
                                                in: plot
                                            )
                                        )
                                        clearHover()
                                    },
                                    onPan: { deltaX, _ in
                                        window = activeWindow.panned(
                                            by: ChartZoomGestureMath.panDelta(
                                                points: deltaX,
                                                plotWidth: plot.width,
                                                span: activeWindow.span
                                            )
                                        )
                                        clearHover()
                                    },
                                    onHover: { location in
                                        updateHover(at: location, proxy: proxy, geometry: geometry)
                                    }
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                                if let hoveredSample, let hoverLocation {
                                    hoverTooltip(for: hoveredSample)
                                        .position(
                                            x: min(max(hoverLocation.x, 60), geometry.size.width - 60),
                                            y: min(max(hoverLocation.y - 26, 18), geometry.size.height - 18)
                                        )
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .chartPlotHeight(plotHeight)
                    .accessibilityLabel("今日功率曲线")
                    .accessibilityValue(powerAccessibilitySummary)

                    if activeWindow.canPan {
                        Slider(
                            value: Binding(
                                get: { activeWindow.start },
                                set: { window = activeWindow.moved(toStart: $0) }
                            ),
                            in: sliderRange
                        )
                        .controlSize(.small)
                        .tint(DesignTokens.dataBlue)
                        .accessibilityLabel("功率曲线时间范围")
                        .accessibilityHint("拖动查看更早或更新的功率数据")
                    }
                }
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
        .onChange(of: dayKey) { _, _ in
            window = nil
        }
        .onChange(of: bounds.upperBound) { _, _ in
            guard let current = window else { return }
            let rebased = current.rebased(to: bounds)
            if rebased != current {
                window = rebased
            }
        }
    }

    /// 曲线坐标下的可缩放总范围（今日全部有效样本）。
    private var bounds: ClosedRange<Double> {
        let first = chartData.plotSamples.first.map { chartData.timeline.position(for: $0.timestamp) }
        let last = chartData.plotSamples.last.map { chartData.timeline.position(for: $0.timestamp) }
        guard let first, let last, last > first else {
            let end = last ?? first ?? 0
            return end...(end + 1)
        }
        return first...last
    }

    /// 当前生效的窗口：未交互时贴最新的默认窗口（宽度 2 小时），交互后为用户的窗口。
    private func effectiveWindow(for stored: ChartZoomWindow?) -> ChartZoomWindow {
        let base = ChartZoomWindow.latest(
            bounds: bounds,
            defaultSpan: PowerChartWindow.defaultVisibleDuration,
            minimumSpan: Self.minimumVisibleDuration
        )
        return (stored ?? base).rebased(to: bounds)
    }

    /// 时间滑块的可用范围（可见窗口起点）。
    private func panRange(for window: ChartZoomWindow) -> ClosedRange<Double> {
        let lower = bounds.lowerBound
        return lower...max(lower, bounds.upperBound - window.span)
    }

    /// 可见窗口对应的真实时间范围，用于筛选要绘制的样本。
    private func visibleDateDomain(for chartDomain: ClosedRange<Double>) -> ClosedRange<Date> {
        let lower = chartData.timeline.date(for: chartDomain.lowerBound)
        return lower...max(lower, chartData.timeline.date(for: chartDomain.upperBound))
    }

    private func axisMarks(
        in dateDomain: ClosedRange<Date>,
        unit: ChartTickUnit,
        chartDomain: ClosedRange<Double>
    ) -> [PowerChartAxisMark] {
        var marks = ChartTimeAxis.marks(in: dateDomain, unit: unit).map { tick in
            PowerChartAxisMark(position: chartData.timeline.position(for: tick), date: tick)
        }
        // 断点内的整点刻度会塌缩到跳变点、与断点标记重叠，直接剔除。
        marks.removeAll { mark in
            guard let date = mark.date else { return false }
            return chartData.timeline.isInsideBreak(date)
        }

        let visibleBreaks = chartData.timeline.breaks.filter {
            $0.duration > 5
                && $0.end > dateDomain.lowerBound
                && $0.start < dateDomain.upperBound
        }
        let markerStride = max(1, Int(ceil(Double(visibleBreaks.count) / 8)))
        for (index, interval) in visibleBreaks.enumerated() where index.isMultiple(of: markerStride) {
            // 断点不占宽度，标记直接画在跳变点上；断点起点在窗口左侧时钳到可见域左边缘。
            let position = min(
                max(chartData.timeline.position(for: interval.start), chartDomain.lowerBound),
                chartDomain.upperBound
            )
            marks.append(PowerChartAxisMark(position: position, date: nil))
        }

        return marks.sorted { $0.position < $1.position }
    }

    /// 只画正功率样本；无读数点、长缺口和系统睡眠都会切成独立曲线段。
    /// 放大后改用未抽样的完整段，避免 800 点抽样在窄窗口内过于稀疏。
    private func displaySegments(
        isZoomed: Bool,
        in dateDomain: ClosedRange<Date>
    ) -> [[HistorySample]] {
        let source = isZoomed ? chartData.fullSegments : chartData.plotSegments
        return source.flatMap { segment in
            let visible = PowerChartWindow.samples(in: dateDomain, from: segment)
            let filtered = PowerChartSegmentation.excludingSleepIntervals(
                visible,
                sleepIntervals: sleepIntervals
            )
            return PowerChartSegmentation.splitByGaps(
                filtered,
                breakingAt: sleepIntervals
            )
        }
    }

    /// VoiceOver 概要：最新一条可见功率样本。
    private var powerAccessibilitySummary: String {
        guard let latest = energySamples.last,
              let power = latest.consumptionPowerW else { return "暂无数据" }
        return String(format: "最新 %.1f 瓦", power)
    }

    /// 手势进行中清掉 tooltip，避免标记跟着手指停留。
    private func clearHover() {
        hoveredSample = nil
        hoverLocation = nil
    }

    private func updateHover(
        at location: CGPoint?,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let location, let plotFrame = proxy.plotFrame else {
            clearHover()
            return
        }

        let frame = geometry[plotFrame]
        guard frame.contains(location) else {
            clearHover()
            return
        }

        let xPosition = location.x - frame.minX
        guard let coordinate: Double = proxy.value(atX: xPosition) else {
            clearHover()
            return
        }
        let timestamp = chartData.timeline.date(for: coordinate)

        hoverLocation = location
        guard let nearest = PowerChartInteraction.nearestSample(
            to: timestamp,
            from: energySamples
        ) else {
            hoveredSample = nil
            return
        }
        // 待机缺口内悬停会吸附到缺口两端样本，与实际位置相差过大时不显示，
        // 避免把待机前的功率误当成待机期间的测量值。
        if abs(nearest.timestamp.timeIntervalSince(timestamp)) > hoverMaximumGap {
            hoveredSample = nil
            return
        }
        hoveredSample = nearest
    }

    private func hoverTooltip(for sample: HistorySample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sample.timestamp, format: .dateTime
                .hour(.defaultDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(String(format: "%.1f W", sample.consumptionPowerW ?? 0))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.dataBlue)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

/// 今日电量曲线：整日一屏展示，支持捏合缩放 / 拖动平移与悬停查看时间与电量。
struct TodayBatteryLevelChart: View {
    let chartData: BatteryLevelChartData
    /// 跨天标识：变化时重置缩放窗口。
    let dayKey: String
    /// 绘图区高度；nil 表示撑满剩余空间（放大浮层内使用）。
    let plotHeight: CGFloat?
    /// 非 nil 时在标题栏提供「放大查看」入口。
    let onExpand: (() -> Void)?

    /// 用户设定的缩放窗口；nil 表示整日。
    @State private var window: ChartZoomWindow?
    @State private var hoveredSample: HistorySample?
    @State private var hoverLocation: CGPoint?
    /// 悬停位置与吸附样本超过该间隔视为"无数据"（待机缺口内不显示 tooltip）。
    private let hoverMaximumGap: TimeInterval = 180
    /// 放大下限：5 分钟。
    private static let minimumVisibleDuration: TimeInterval = 300

    private var samples: [HistorySample] { chartData.samples }

    init(
        chartData: BatteryLevelChartData,
        dayKey: String = "",
        plotHeight: CGFloat? = 138,
        onExpand: (() -> Void)? = nil
    ) {
        self.chartData = chartData
        self.dayKey = dayKey
        self.plotHeight = plotHeight
        self.onExpand = onExpand
    }

    /// 以最后一条样本时间结尾（数据驱动），避免 2Hz 重渲染下按 `Date()` 每 0.5s 重新缩放抖动。
    private var fullDomain: ClosedRange<Date> {
        BatteryLevelAxis.xDomain(now: samples.last?.timestamp ?? Date())
    }

    /// 可缩放总范围，换算成参考纪元秒（与 ChartZoomWindow 的坐标单位一致）。
    private var bounds: ClosedRange<Double> {
        let lower = fullDomain.lowerBound.timeIntervalSinceReferenceDate
        let upper = fullDomain.upperBound.timeIntervalSinceReferenceDate
        return lower...upper
    }

    /// 当前生效窗口：未交互时是整日，交互后为用户的窗口。
    private func effectiveWindow(for stored: ChartZoomWindow?) -> ChartZoomWindow {
        let base = ChartZoomWindow.fullRange(
            bounds: bounds,
            minimumSpan: Self.minimumVisibleDuration
        )
        return (stored ?? base).rebased(to: bounds)
    }

    /// 可见的真实时间域。
    private func visibleDomain(for window: ChartZoomWindow) -> ClosedRange<Date> {
        let lower = Date(timeIntervalSinceReferenceDate: window.start)
        let upper = Date(timeIntervalSinceReferenceDate: max(window.start + 1, window.upper))
        return lower...max(lower, upper)
    }

    /// Y 轴域：缩放后按可见样本重算；未缩放时沿用整日预计算域（两者输入集一致）。
    private func yDomain(
        for window: ChartZoomWindow,
        in domain: ClosedRange<Date>
    ) -> ClosedRange<Double> {
        guard window.isZoomed else { return chartData.percentDomain }
        let visible = ChartViewport.visibleSamples(samples, in: domain)
        return BatteryLevelAxis.yDomain(for: visible.map(\.percent))
    }

    /// 缺口处断开连线；待机期间不记录样本，故无需再按待机区间过滤。
    private func displaySegments(
        for window: ChartZoomWindow,
        in domain: ClosedRange<Date>
    ) -> [[HistorySample]] {
        let source = window.isZoomed
            ? ChartViewport.visibleSamples(samples, in: domain, maximum: 800)
            : chartData.displayedSamples
        return PowerChartSegmentation.splitByGaps(source)
    }

    var body: some View {
        // 帧内只算一次：若把 `yDomain` 这类计算属性直接写进逐样本的 ForEach，
        // 每个样本都会重跑一遍 O(样本数) 的筛选，整体退化成 O(n²)（卡顿主因）。
        let activeWindow = effectiveWindow(for: window)
        let plotDomain = visibleDomain(for: activeWindow)
        let plotYDomain = yDomain(for: activeWindow, in: plotDomain)
        let segments = displaySegments(for: activeWindow, in: plotDomain)
        let tickUnit = ChartTimeAxis.unit(
            forSpan: plotDomain.upperBound.timeIntervalSince(plotDomain.lowerBound)
        )
        let tickFormat: Date.FormatStyle = tickUnit.includesMinutes
            ? Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)
            : Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted))

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("今日电量曲线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if activeWindow.isZoomed {
                    Text("已放大")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                ChartZoomButton(kind: .zoomOut) {
                    $window.zoom(by: 1 / ChartZoomButton.step, effective: activeWindow)
                }
                ChartZoomButton(kind: .zoomIn) {
                    $window.zoom(by: ChartZoomButton.step, effective: activeWindow)
                }
                if window != nil {
                    ChartZoomResetButton { window = nil }
                }
                if let onExpand {
                    ChartExpandButton(action: onExpand)
                }
            }

            if samples.isEmpty {
                ChartEmptyPlaceholder("暂无今日数据，应用运行后每 5 秒记录一次")
                    .frame(height: 120)
            } else {
                Chart {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        ForEach(segment) { sample in
                            AreaMark(
                                x: .value("时间", sample.timestamp),
                                yStart: .value("电量下界", plotYDomain.lowerBound),
                                yEnd: .value("电量", sample.percent)
                            )
                            .interpolationMethod(.linear)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [DesignTokens.dataBlue.opacity(0.22), DesignTokens.dataBlue.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                            LineMark(
                                x: .value("时间", sample.timestamp),
                                y: .value("电量", sample.percent)
                            )
                            .interpolationMethod(.linear)
                            .foregroundStyle(DesignTokens.dataBlue)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        }
                    }

                    if let hoveredSample {
                        RuleMark(x: .value("悬停时间", hoveredSample.timestamp))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(DesignTokens.dataBlue.opacity(0.7))

                        PointMark(
                            x: .value("时间", hoveredSample.timestamp),
                            y: .value("电量", hoveredSample.percent)
                        )
                        .foregroundStyle(DesignTokens.dataBlue)
                        .symbolSize(36)
                    }
                }
                .chartXScale(domain: plotDomain)
                .chartYScale(domain: plotYDomain)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let percent = value.as(Double.self) {
                                Text("\(Int(percent.rounded()))%")
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: ChartTimeAxis.marks(in: plotDomain, unit: tickUnit)) { _ in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick()
                        AxisValueLabel(format: tickFormat)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        let plot = proxy.overlayPlotRect(in: geometry)
                        ZStack(alignment: .topTrailing) {
                            ChartPlotEventCatcher(
                                onZoom: { factor, location in
                                    window = activeWindow.zoomed(
                                        by: Double(factor),
                                        anchorFraction: ChartZoomGestureMath.anchorFraction(
                                            for: location,
                                            in: plot
                                        )
                                    )
                                    clearHover()
                                },
                                onPan: { deltaX, _ in
                                    window = activeWindow.panned(
                                        by: ChartZoomGestureMath.panDelta(
                                            points: deltaX,
                                            plotWidth: plot.width,
                                            span: activeWindow.span
                                        )
                                    )
                                    clearHover()
                                },
                                onHover: { location in
                                    updateHover(at: location, proxy: proxy, geometry: geometry)
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if let hoveredSample, let hoverLocation {
                                hoverTooltip(for: hoveredSample)
                                    .position(
                                        x: min(max(hoverLocation.x, 60), geometry.size.width - 60),
                                        y: min(max(hoverLocation.y - 26, 18), geometry.size.height - 18)
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .chartPlotHeight(plotHeight)
                // Y 轴顶端刻度（如 100%）以刻度线为中心绘制，贴着绘图区上沿会被 .clipped()
                // 裁掉上半个字并压到标题上；在图表外包一层顶部内边距给标签留出空间。
                .padding(.top, 14)
                .clipped()
                .accessibilityLabel("今日电量曲线")
                .accessibilityValue(levelAccessibilitySummary)
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
        .onChange(of: dayKey) { _, _ in
            window = nil
        }
    }

    /// VoiceOver 概要：最新一条电量样本。
    private var levelAccessibilitySummary: String {
        guard let latest = samples.last else { return "暂无数据" }
        return "最新电量 \(BatteryFormatters.percent(latest.percent))"
    }

    /// 手势进行中清掉 tooltip，避免标记跟着手指停留。
    private func clearHover() {
        hoveredSample = nil
        hoverLocation = nil
    }

    private func updateHover(
        at location: CGPoint?,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let location, let plotFrame = proxy.plotFrame else {
            clearHover()
            return
        }

        let frame = geometry[plotFrame]
        guard frame.contains(location) else {
            clearHover()
            return
        }

        let xPosition = location.x - frame.minX
        guard let timestamp: Date = proxy.value(atX: xPosition) else {
            clearHover()
            return
        }

        hoverLocation = location
        guard let nearest = PowerChartInteraction.nearestSample(
            to: timestamp,
            from: samples
        ) else {
            hoveredSample = nil
            return
        }
        // 缺口内悬停会吸附到缺口两端样本，与实际位置相差过大时不显示，
        // 避免把待机前的电量误当成待机期间的读数。
        if abs(nearest.timestamp.timeIntervalSince(timestamp)) > hoverMaximumGap {
            hoveredSample = nil
            return
        }
        hoveredSample = nearest
    }

    private func hoverTooltip(for sample: HistorySample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sample.timestamp, format: .dateTime
                .hour(.defaultDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(BatteryFormatters.percent(sample.percent))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.dataBlue)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

/// 今日温压分时曲线的可选指标。
enum TodayMetric: String, CaseIterable, Identifiable {
    case temperature
    case voltage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: "温度"
        case .voltage: "电压"
        }
    }

    func value(from sample: HistorySample) -> Double? {
        switch self {
        case .temperature: sample.temperatureCelsius
        case .voltage: sample.voltage
        }
    }

    func valueLabel(for value: Double) -> String {
        switch self {
        case .temperature: String(format: "%.1f °C", value)
        case .voltage: String(format: "%.2f V", value)
        }
    }
}

/// 某指标的今日分时绘图数据：过滤空值、抽样到上限、预算 Y 域与轴刻度。
struct TodayMetricChartData {
    let metric: TodayMetric
    /// 今日有该指标值的全量样本，供悬停吸附使用。
    let samples: [HistorySample]
    /// 抽样后的渲染样本，最多 `maximumDisplayedSamples` 条。
    let displayedSamples: [HistorySample]
    /// 由全量样本预计算的 Y 轴域（抽样可能丢极值，故不能用抽样集计算）。
    let valueDomain: ClosedRange<Double>
    /// Y 轴域内的整齐刻度与标签小数位。
    let axisTicks: AxisTickScale

    init(samples: [HistorySample], metric: TodayMetric, maximumDisplayedSamples: Int = 800) {
        self.metric = metric
        let valid = samples.filter { sample in
            guard let value = metric.value(from: sample) else { return false }
            return value.isFinite
        }
        self.samples = valid
        let domain = MetricValueAxis.yDomain(for: valid.compactMap { metric.value(from: $0) })
        self.valueDomain = domain
        self.axisTicks = MetricValueAxis.ticks(in: domain)

        guard maximumDisplayedSamples > 1, valid.count > maximumDisplayedSamples else {
            self.displayedSamples = valid
            return
        }
        let step = Double(valid.count - 1) / Double(maximumDisplayedSamples - 1)
        self.displayedSamples = (0..<maximumDisplayedSamples).map { index in
            valid[Int((Double(index) * step).rounded())]
        }
    }
}

/// 今日温压曲线数据记忆化：仅在样本集合或所选指标变化时重建（抽样到 800 点是 O(n) 开销）。
final class TodayMetricChartDataCache {
    private var cached: TodayMetricChartData?
    private var lastMetric: TodayMetric?
    private var lastCount = -1
    private var lastID: UUID?

    func data(for samples: [HistorySample], metric: TodayMetric) -> TodayMetricChartData {
        if let cached, lastMetric == metric, lastCount == samples.count, lastID == samples.last?.id {
            return cached
        }
        let data = TodayMetricChartData(samples: samples, metric: metric)
        cached = data
        lastMetric = metric
        lastCount = samples.count
        lastID = samples.last?.id
        return data
    }
}

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

/// 通用趋势 Y 轴域：空数据回退 0...1；平线时上下各留 max(|值|×5%, 1)；否则在跨度上留 10% 余量。
enum MetricValueAxis {
    /// 整齐步长候选（升序）。刻意不含 0.25 / 2.5：它们无法用对应位数的小数精确表达。
    private static let stepCandidates: [Double] = [
        0.001, 0.002, 0.005, 0.01, 0.02, 0.05,
        0.1, 0.2, 0.5, 1, 2, 5,
        10, 20, 50, 100, 200, 500, 1000
    ]
    /// 刻度数量区间：太少失去参考价值，太多在 138pt 高的图里会挤在一起。
    private static let tickCountRange = 3...5

    static func yDomain(for values: [Double]) -> ClosedRange<Double> {
        let finite = values.filter { $0.isFinite }
        guard let minimum = finite.min(), let maximum = finite.max() else { return 0...1 }
        let span = maximum - minimum
        guard span >= 0.0001 else {
            let padding = max(abs(minimum) * 0.05, 1)
            return (minimum - padding)...(maximum + padding)
        }
        let padding = span * 0.1
        return (minimum - padding)...(maximum + padding)
    }

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
            // 浮点噪声可能让两个刻度格式化后相同（曾是「31 / 31 / 31」的直接原因），加位兜底。
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

/// 今日温度统计：最高温与高于阈值的累计时长。
enum TodayTemperatureStats {
    static func maximum(in samples: [HistorySample]) -> Double? {
        samples.compactMap(\.temperatureCelsius).filter { $0.isFinite }.max()
    }

    /// 高于阈值的累计时长：把相邻样本的间隔归给起始样本，跳过超过 `maximumGap` 的断点
    /// （待机等无采样区间不应算作高温时长）。样本需按时间升序。
    static func durationAbove(
        _ threshold: Double,
        in samples: [HistorySample],
        maximumGap: TimeInterval = 60
    ) -> TimeInterval {
        var total: TimeInterval = 0
        for (previous, next) in zip(samples, samples.dropFirst()) {
            guard let value = previous.temperatureCelsius,
                  value.isFinite,
                  value >= threshold else {
                continue
            }
            let gap = next.timestamp.timeIntervalSince(previous.timestamp)
            guard gap > 0, gap <= maximumGap else { continue }
            total += gap
        }
        return total
    }
}

/// 今日温度 / 电压分时曲线：整日一屏、分段切换，含最高温与高温累计时长等概览。
struct TodayMetricChart: View {
    let samples: [HistorySample]
    /// 跨天标识：变化时重置缩放窗口。
    let dayKey: String
    /// 绘图区高度；nil 表示撑满剩余空间（放大窗口内使用）。
    let plotHeight: CGFloat?
    /// 由外部固定指标并隐藏内置切换器（放大窗口按标签页驱动）；nil 时用内置状态。
    let fixedMetric: TodayMetric?
    /// 非 nil 时在标题栏提供「放大查看」入口，并回传当前指标。
    let onExpand: ((TodayMetric) -> Void)?

    @State private var metric: TodayMetric = .temperature
    @State private var cache = TodayMetricChartDataCache()
    /// 用户设定的缩放窗口；nil 表示整日。
    @State private var window: ChartZoomWindow?
    @State private var hoveredSample: HistorySample?
    @State private var hoverLocation: CGPoint?

    /// 悬停位置与吸附样本超过该间隔视为「无数据」（待机缺口内不显示 tooltip）。
    private let hoverMaximumGap: TimeInterval = 180
    /// 高温提示阈值（℃）。
    private static let highTemperatureThreshold: Double = 35
    /// 放大下限：5 分钟。
    private static let minimumVisibleDuration: TimeInterval = 300

    init(
        samples: [HistorySample],
        dayKey: String = "",
        plotHeight: CGFloat? = 138,
        fixedMetric: TodayMetric? = nil,
        onExpand: ((TodayMetric) -> Void)? = nil
    ) {
        self.samples = samples
        self.dayKey = dayKey
        self.plotHeight = plotHeight
        self.fixedMetric = fixedMetric
        self.onExpand = onExpand
    }

    /// 当前实际展示的指标：外部指定优先，否则用内置切换器的状态。
    private var activeMetric: TodayMetric {
        fixedMetric ?? metric
    }

    private var chartData: TodayMetricChartData {
        cache.data(for: samples, metric: activeMetric)
    }

    /// 以最后一条样本时间结尾（数据驱动），避免 2Hz 重渲染下按 `Date()` 每 0.5s 重新缩放抖动。
    private var fullDomain: ClosedRange<Date> {
        BatteryLevelAxis.xDomain(now: samples.last?.timestamp ?? Date())
    }

    /// 可缩放总范围，换算成参考纪元秒（与 ChartZoomWindow 的坐标单位一致）。
    private var bounds: ClosedRange<Double> {
        let lower = fullDomain.lowerBound.timeIntervalSinceReferenceDate
        let upper = fullDomain.upperBound.timeIntervalSinceReferenceDate
        return lower...upper
    }

    /// 当前生效窗口：未交互时是整日，交互后为用户的窗口。
    private func effectiveWindow(for stored: ChartZoomWindow?) -> ChartZoomWindow {
        let base = ChartZoomWindow.fullRange(
            bounds: bounds,
            minimumSpan: Self.minimumVisibleDuration
        )
        return (stored ?? base).rebased(to: bounds)
    }

    /// 可见的真实时间域。
    private func visibleDomain(for window: ChartZoomWindow) -> ClosedRange<Date> {
        let lower = Date(timeIntervalSinceReferenceDate: window.start)
        let upper = Date(timeIntervalSinceReferenceDate: max(window.start + 1, window.upper))
        return lower...max(lower, upper)
    }

    /// Y 轴域与刻度：缩放后按可见样本重算；未缩放时沿用整日预计算值。
    private func yAxis(
        for window: ChartZoomWindow,
        in domain: ClosedRange<Date>
    ) -> AxisTickScale {
        guard window.isZoomed else { return chartData.axisTicks }
        let visible = ChartViewport.visibleSamples(chartData.samples, in: domain)
        let valueDomain = MetricValueAxis.yDomain(
            for: visible.compactMap { activeMetric.value(from: $0) }
        )
        return MetricValueAxis.ticks(in: valueDomain)
    }

    /// 缺口处断开连线；待机期间不记录样本，故无需再按待机区间过滤。
    private func displaySegments(
        for window: ChartZoomWindow,
        in domain: ClosedRange<Date>
    ) -> [[HistorySample]] {
        let source = window.isZoomed
            ? ChartViewport.visibleSamples(chartData.samples, in: domain, maximum: 800)
            : chartData.displayedSamples
        return PowerChartSegmentation.splitByGaps(source)
    }

    var body: some View {
        // 帧内只算一次：若把 `yAxis` 直接写进逐样本的 ForEach，每个样本都会重跑
        // 一遍 O(样本数) 的筛选 + 刻度字符串格式化（卡顿主因）。
        let activeWindow = effectiveWindow(for: window)
        let plotDomain = visibleDomain(for: activeWindow)
        let plotYAxis = yAxis(for: activeWindow, in: plotDomain)
        let segments = displaySegments(for: activeWindow, in: plotDomain)
        let tickUnit = ChartTimeAxis.unit(
            forSpan: plotDomain.upperBound.timeIntervalSince(plotDomain.lowerBound)
        )
        let tickFormat: Date.FormatStyle = tickUnit.includesMinutes
            ? Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)
            : Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted))
        let metricKind = activeMetric
        let metricTitle = metricKind.title

        return VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            // 放大窗口按标签页指定指标时隐藏内置切换器，避免两层重复控件。
            if fixedMetric == nil {
                Picker("指标", selection: $metric) {
                    ForEach(TodayMetric.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 6) {
                if let statsText {
                    Text(statsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if activeWindow.isZoomed {
                    Text("已放大")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                ChartZoomButton(kind: .zoomOut) {
                    $window.zoom(by: 1 / ChartZoomButton.step, effective: activeWindow)
                }
                ChartZoomButton(kind: .zoomIn) {
                    $window.zoom(by: ChartZoomButton.step, effective: activeWindow)
                }
                if window != nil {
                    ChartZoomResetButton { window = nil }
                }
                if let onExpand {
                    ChartExpandButton { onExpand(metricKind) }
                }
            }
            .frame(minHeight: 14)

            if chartData.samples.isEmpty {
                ChartEmptyPlaceholder("暂无今日\(metricTitle)数据，应用运行后每 5 秒记录一次")
                    .frame(height: 120)
            } else {
                Chart {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        ForEach(segment) { sample in
                            if let value = metricKind.value(from: sample) {
                                AreaMark(
                                    x: .value("时间", sample.timestamp),
                                    yStart: .value("下界", plotYAxis.domain.lowerBound),
                                    yEnd: .value(metricTitle, value)
                                )
                                .interpolationMethod(.linear)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [DesignTokens.dataBlue.opacity(0.22), DesignTokens.dataBlue.opacity(0.02)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("时间", sample.timestamp),
                                    y: .value(metricTitle, value)
                                )
                                .interpolationMethod(.linear)
                                .foregroundStyle(DesignTokens.dataBlue)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            }
                        }
                    }

                    if let hoveredSample, let value = metricKind.value(from: hoveredSample) {
                        RuleMark(x: .value("悬停时间", hoveredSample.timestamp))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(DesignTokens.dataBlue.opacity(0.7))

                        PointMark(
                            x: .value("时间", hoveredSample.timestamp),
                            y: .value(metricTitle, value)
                        )
                        .foregroundStyle(DesignTokens.dataBlue)
                        .symbolSize(36)
                    }
                }
                .chartXScale(domain: plotDomain)
                .chartYScale(domain: plotYAxis.domain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: plotYAxis.values) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let raw = value.as(Double.self) {
                                Text(plotYAxis.label(for: raw))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: ChartTimeAxis.marks(in: plotDomain, unit: tickUnit)) { _ in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick()
                        AxisValueLabel(format: tickFormat)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        let plot = proxy.overlayPlotRect(in: geometry)
                        ZStack(alignment: .topTrailing) {
                            ChartPlotEventCatcher(
                                onZoom: { factor, location in
                                    window = activeWindow.zoomed(
                                        by: Double(factor),
                                        anchorFraction: ChartZoomGestureMath.anchorFraction(
                                            for: location,
                                            in: plot
                                        )
                                    )
                                    clearHover()
                                },
                                onPan: { deltaX, _ in
                                    window = activeWindow.panned(
                                        by: ChartZoomGestureMath.panDelta(
                                            points: deltaX,
                                            plotWidth: plot.width,
                                            span: activeWindow.span
                                        )
                                    )
                                    clearHover()
                                },
                                onHover: { location in
                                    updateHover(at: location, proxy: proxy, geometry: geometry)
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if let hoveredSample,
                               let hoverLocation,
                               let value = metricKind.value(from: hoveredSample) {
                                hoverTooltip(for: hoveredSample, value: value)
                                    .position(
                                        x: min(max(hoverLocation.x, 60), geometry.size.width - 60),
                                        y: min(max(hoverLocation.y - 26, 18), geometry.size.height - 18)
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .chartPlotHeight(plotHeight)
                // Y 轴顶端刻度以刻度线为中心绘制，贴着绘图区上沿会被 .clipped() 裁掉半行字。
                .padding(.top, 14)
                .clipped()
                .accessibilityLabel("今日\(metricTitle)曲线")
                .accessibilityValue(accessibilitySummary)
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
        .onChange(of: dayKey) { _, _ in
            window = nil
        }
    }

    /// 概览：温度显示今日最高与高温累计时长，电压显示今日范围。
    private var statsText: String? {
        switch activeMetric {
        case .temperature:
            guard let maximum = TodayTemperatureStats.maximum(in: chartData.samples) else { return nil }
            let duration = TodayTemperatureStats.durationAbove(
                Self.highTemperatureThreshold,
                in: chartData.samples
            )
            return "今日最高 \(String(format: "%.1f", maximum)) °C · "
                + "≥\(Int(Self.highTemperatureThreshold))°C 累计 \(Self.durationText(duration))"
        case .voltage:
            let values = chartData.samples.compactMap(\.voltage)
            guard let minimum = values.min(), let maximum = values.max() else { return nil }
            return String(format: "今日 %.2f – %.2f V", minimum, maximum)
        }
    }

    private var accessibilitySummary: String {
        guard let latest = chartData.samples.last,
              let value = activeMetric.value(from: latest) else {
            return "暂无数据"
        }
        return "最新 \(activeMetric.valueLabel(for: value))"
    }

    /// 手势进行中清掉 tooltip，避免标记跟着手指停留。
    private func clearHover() {
        hoveredSample = nil
        hoverLocation = nil
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) 分" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private func updateHover(at location: CGPoint?, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let location, let plotFrame = proxy.plotFrame else {
            clearHover()
            return
        }
        let frame = geometry[plotFrame]
        guard frame.contains(location) else {
            clearHover()
            return
        }
        let xPosition = location.x - frame.minX
        guard let timestamp: Date = proxy.value(atX: xPosition) else {
            clearHover()
            return
        }
        hoverLocation = location
        guard let nearest = PowerChartInteraction.nearestSample(to: timestamp, from: chartData.samples) else {
            hoveredSample = nil
            return
        }
        if abs(nearest.timestamp.timeIntervalSince(timestamp)) > hoverMaximumGap {
            hoveredSample = nil
            return
        }
        hoveredSample = nearest
    }

    private func hoverTooltip(for sample: HistorySample, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sample.timestamp, format: .dateTime
                .hour(.defaultDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(activeMetric.valueLabel(for: value))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.dataBlue)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

struct PowerChartData {
    let timeline: PowerChartTimeline
    /// Positive, finite readings used for chart bounds and hover snapping.
    let plotSamples: [HistorySample]
    /// Renderable runs split at no-power samples before downsampling.
    let plotSegments: [[HistorySample]]
    /// 未抽样的完整连续段：放大到窄窗口时用它渲染，避免 800 点抽样在细节区间过稀。
    let fullSegments: [[HistorySample]]

    let energySamples: [HistorySample]
    let chartSamples: [HistorySample]

    init(samples: [HistorySample], maximumDisplayedSamples: Int) {
        self.init(
            samples: samples,
            sleepIntervals: [],
            maximumDisplayedSamples: maximumDisplayedSamples
        )
    }

    init(
        samples: [HistorySample],
        sleepIntervals: [SleepInterval],
        maximumDisplayedSamples: Int
    ) {
        let energySamples = samples.filter { $0.consumptionPowerW != nil }
        self.energySamples = energySamples

        let validSegments = PowerChartSegmentation.splitForPowerTimeline(
            samples,
            sleepIntervals: sleepIntervals
        )
        self.timeline = PowerChartTimeline(segments: validSegments)
        self.fullSegments = validSegments
        let plotSegments = Self.downsampleSegments(
            validSegments,
            maximumDisplayedSamples: maximumDisplayedSamples
        )
        let plotSamples = validSegments.flatMap { $0 }
        self.plotSegments = plotSegments
        self.plotSamples = plotSamples

        guard maximumDisplayedSamples > 1,
              energySamples.count > maximumDisplayedSamples else {
            self.chartSamples = energySamples
            return
        }

        let step = Double(energySamples.count - 1) / Double(maximumDisplayedSamples - 1)
        self.chartSamples = (0..<maximumDisplayedSamples).map { index in
            energySamples[Int((Double(index) * step).rounded())]
        }
    }

    private static func downsampleSegments(
        _ segments: [[HistorySample]],
        maximumDisplayedSamples: Int
    ) -> [[HistorySample]] {
        let drawable = segments.filter { $0.count > 1 }
        guard maximumDisplayedSamples > 1, !drawable.isEmpty else { return [] }

        let totalCount = drawable.reduce(0) { $0 + $1.count }
        guard totalCount > maximumDisplayedSamples else { return drawable }

        // Keep both endpoints of each run so downsampling never joins across a no-power gap.
        if drawable.count * 2 >= maximumDisplayedSamples {
            let runBudget = maximumDisplayedSamples / 2
            guard runBudget > 0 else { return [] }
            return (0..<runBudget).map { index in
                let sourceIndex = runBudget == 1
                    ? 0
                    : Int((Double(index) * Double(drawable.count - 1) / Double(runBudget - 1)).rounded())
                let segment = drawable[sourceIndex]
                return [segment[0], segment[segment.count - 1]]
            }
        }

        let extraBudget = maximumDisplayedSamples - drawable.count * 2
        let totalExtraCapacity = drawable.reduce(0) { $0 + $1.count - 2 }
        guard extraBudget > 0, totalExtraCapacity > 0 else {
            return drawable.map { [$0[0], $0[$0.count - 1]] }
        }

        var targets = Array(repeating: 2, count: drawable.count)
        var remainders: [(index: Int, value: Double)] = []
        for (index, segment) in drawable.enumerated() {
            let capacity = segment.count - 2
            let share = Double(extraBudget) * Double(capacity) / Double(totalExtraCapacity)
            let whole = min(capacity, Int(share.rounded(.down)))
            targets[index] += whole
            remainders.append((index, share - Double(whole)))
        }

        var unallocated = maximumDisplayedSamples - targets.reduce(0, +)
        for remainder in remainders.sorted(by: { $0.value > $1.value }) where unallocated > 0 {
            guard targets[remainder.index] < drawable[remainder.index].count else { continue }
            targets[remainder.index] += 1
            unallocated -= 1
        }

        return drawable.enumerated().map { index, segment in
            Self.evenlySampled(segment, count: targets[index])
        }
    }

    private static func evenlySampled(_ samples: [HistorySample], count: Int) -> [HistorySample] {
        guard count > 1, samples.count > count else { return samples }
        return (0..<count).map { index in
            let sourceIndex = Int(
                (Double(index) * Double(samples.count - 1) / Double(count - 1)).rounded()
            )
            return samples[sourceIndex]
        }
    }
}

struct PowerChartBreak: Equatable {
    var start: Date
    var end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct PowerChartAxisMark: Identifiable {
    var position: Double
    var date: Date?

    var id: Double { position }
}

struct PowerChartTimeline {
    let breaks: [PowerChartBreak]

    init(segments: [[HistorySample]]) {
        self.breaks = zip(segments, segments.dropFirst()).compactMap { previous, next in
            guard let last = previous.last,
                  let first = next.first,
                  first.timestamp > last.timestamp else {
                return nil
            }
            return PowerChartBreak(start: last.timestamp, end: first.timestamp)
        }
    }

    /// Maps wall-clock time onto a chart axis where no-power intervals take no width.
    /// 断点（待机 / 无读数缺口）不占横向空间：落在断点内的时刻全部映射到断点起点，
    /// 曲线在断点处直接跳到下一段，断点位置由轴上的 `//` 标记提示。
    func position(for date: Date) -> Double {
        var removedDuration: TimeInterval = 0
        for interval in breaks {
            if date < interval.start { break }
            if date <= interval.end {
                return interval.start.timeIntervalSinceReferenceDate - removedDuration
            }
            removedDuration += interval.duration
        }
        return date.timeIntervalSinceReferenceDate - removedDuration
    }

    /// Converts a chart coordinate back to its corresponding wall-clock time.
    /// 落在被跳过的断点上时返回断点结束时刻（曲线在该处恢复）。
    func date(for position: Double) -> Date {
        var removedDuration: TimeInterval = 0
        for interval in breaks {
            let startPosition = interval.start.timeIntervalSinceReferenceDate - removedDuration
            if position < startPosition { break }
            removedDuration += interval.duration
        }
        return Date(timeIntervalSinceReferenceDate: position + removedDuration)
    }

    /// 真实时间是否落在断点内部（用于跳过断点里的整点刻度）。
    func isInsideBreak(_ date: Date) -> Bool {
        breaks.contains { $0.start < date && date < $0.end }
    }
}

/// 今日电量曲线数据：不做 `consumptionPowerW` 过滤（那会丢掉合法电量点），
/// 只按 `percent` 有效性做防御过滤，并预计算 Y 轴域供 2Hz 渲染直接取用。
struct BatteryLevelChartData {
    /// 今日全量样本，供悬停吸附使用。
    let samples: [HistorySample]
    /// 抽样后的渲染样本，最多 `maximumDisplayedSamples` 条。
    let displayedSamples: [HistorySample]
    /// 由全量样本预计算的 Y 轴域（抽样可能丢极值，故不能用抽样集计算）。
    let percentDomain: ClosedRange<Double>

    init(samples: [HistorySample], maximumDisplayedSamples: Int) {
        let valid = samples.filter { $0.percent.isFinite }
        self.samples = valid
        self.percentDomain = BatteryLevelAxis.yDomain(for: valid.map(\.percent))

        guard maximumDisplayedSamples > 1,
              valid.count > maximumDisplayedSamples else {
            self.displayedSamples = valid
            return
        }

        let step = Double(valid.count - 1) / Double(maximumDisplayedSamples - 1)
        self.displayedSamples = (0..<maximumDisplayedSamples).map { index in
            valid[Int((Double(index) * step).rounded())]
        }
    }
}

/// 电量曲线坐标轴：纯函数，便于单元测试。
enum BatteryLevelAxis {
    /// X 轴域：当天 00:00 → now，至少 60s 宽，避免刚过午夜时域退化。
    static func xDomain(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let start = calendar.startOfDay(for: now)
        return start...max(now, start.addingTimeInterval(60))
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

/// 把样本按时间缺口切分为连续段，供功率曲线缺口处断开渲染。
enum PowerChartSegmentation {
    /// Split the source timeline at missing/zero readings, sleeps, and long observation gaps.
    static func splitForPowerTimeline(
        _ samples: [HistorySample],
        sleepIntervals: [SleepInterval],
        maximumGap: TimeInterval = 300
    ) -> [[HistorySample]] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var segments: [[HistorySample]] = []
        var current: [HistorySample] = []

        for sample in sorted {
            let isSleeping = sleepIntervals.contains { interval in
                interval.end > interval.start
                    && interval.start <= sample.timestamp
                    && sample.timestamp < interval.end
            }
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
                let crossesSleep = sleepIntervals.contains {
                    $0.overlaps(previous.timestamp, sample.timestamp)
                }
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

        var segments: [[HistorySample]] = [[first]]
        for sample in sorted.dropFirst() {
            guard let last = segments[segments.count - 1].last else { continue }
            let crossesSleepInterval = sleepIntervals.contains {
                $0.overlaps(last.timestamp, sample.timestamp)
            }
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
        return samples.filter { sample in
            !sleepIntervals.contains { interval in
                interval.end > interval.start
                    && interval.start <= sample.timestamp
                    && sample.timestamp < interval.end
            }
        }
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

struct ChartEmptyPlaceholder: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
