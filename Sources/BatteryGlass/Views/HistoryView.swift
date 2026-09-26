import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(BatteryHistoryStore.self) private var history
    @Environment(BatteryMonitor.self) private var monitor
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

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.spacingM) {
                DailyEnergyComparisonChart(
                    summaries: energyRange.summaries(from: history),
                    range: $energyRange
                )

                TodayPowerChart(
                    chartData: chartData,
                    sleepIntervals: history.sleepIntervals
                )
                // 跨天后以新的一天重建视图，重置时间滑块位置，
                // 避免 @State scrollPosition 停留在昨天的滚动位置导致曲线窗口错乱。
                .id(BatteryFormatters.dayKey(for: Date()))

                TodayBatteryLevelChart(
                    chartData: levelChartData
                )

                HealthTrendChart(summaries: history.allSummaries())

                HistoryMetricCard(
                    title: "循环次数",
                    icon: "repeat",
                    value: "\(cycleCount)",
                    caption: "次 · 设计寿命 1000 次",
                    tint: DesignTokens.dataBlue
                )
            }
            .padding(.bottom, DesignTokens.spacingXS)
        }
        .scrollIndicators(.hidden)
    }

    private var cycleCount: Int {
        history.samples.last?.cycleCount ?? monitor.snapshot.cycleCount
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

    private var energySummaries: [DailySummary] {
        summaries.filter { $0.energyKWh != nil }
    }

    private var aggregates: [EnergyAggregate] {
        EnergyAggregator.aggregate(summaries: energySummaries, grouping: grouping)
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
                ChartEmptyPlaceholder("暂无完整每日耗电量数据")
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
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let energy = value.as(Double.self) {
                                Text(String(format: "%.1f", energy))
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
                // 只渲染最近 30 天，避免长期使用后「全部」范围渲染数千行。
                ForEach(summaries.suffix(30).reversed()) { summary in
                    HStack {
                        Text(summary.dayKey)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(summary.energyKWh.map(BatteryFormatters.energyKWh) ?? "--")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DesignTokens.dataBlue)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.top, DesignTokens.spacingXS)
    }
}

struct TodayPowerChart: View {
    let chartData: PowerChartData
    let sleepIntervals: [SleepInterval]
    /// 曲线坐标（秒，已跳过断点）下的可滚动范围；数据不足一屏时为 nil。
    let scrollRange: ClosedRange<Double>?
    @State private var scrollPosition: Double
    @State private var hoveredSample: HistorySample?
    @State private var hoverLocation: CGPoint?
    /// 悬停位置与吸附样本超过该间隔视为"无数据"（待机缺口内不显示 tooltip）。
    private let hoverMaximumGap: TimeInterval = 180

    private var energySamples: [HistorySample] { chartData.plotSamples }

    init(chartData: PowerChartData, sleepIntervals: [SleepInterval]) {
        self.chartData = chartData
        self.sleepIntervals = sleepIntervals
        let range = PowerChartWindow.scrollBounds(
            timeline: chartData.timeline,
            samples: chartData.plotSamples
        )
        self.scrollRange = range
        self._scrollPosition = State(
            initialValue: range?.upperBound
                ?? chartData.timeline.position(for: chartData.plotSamples.last?.timestamp ?? Date())
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("今日功率曲线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if scrollRange != nil {
                    Text("横向滚动查看")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if chartData.plotSegments.isEmpty {
                ChartEmptyPlaceholder("暂无有效功率曲线")
                    .frame(height: 120)
            } else {
                VStack(spacing: 4) {
                    Chart {
                        ForEach(Array(displaySegments.enumerated()), id: \.offset) { _, segment in
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
                        AxisMarks(values: axisMarks.map(\.position)) { value in
                            if let position = value.as(Double.self),
                               let mark = axisMarks.min(by: {
                                   abs($0.position - position) < abs($1.position - position)
                               }) {
                                AxisGridLine().foregroundStyle(.clear)
                                AxisTick()
                                AxisValueLabel {
                                    if let date = mark.date {
                                        Text(date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)))
                                    } else {
                                        Text("//")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                    }
                                }
                            }
                        }
                    }
                    .chartXScale(domain: visibleChartDomain)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            ZStack(alignment: .topTrailing) {
                                Rectangle()
                                    .fill(.clear)
                                    .onContinuousHover { phase in
                                        updateHover(phase, proxy: proxy, geometry: geometry)
                                    }

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
                    .frame(height: 138)
                    .accessibilityLabel("今日功率曲线")
                    .accessibilityValue(powerAccessibilitySummary)

                    if let scrollRange {
                        Slider(
                            value: $scrollPosition,
                            in: scrollRange
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
        .onChange(of: scrollRange?.upperBound) { previousEnd, newEnd in
            guard let previousEnd, let newEnd, previousEnd != newEnd,
                  PowerChartWindow.shouldFollowLatest(
                      currentPosition: scrollPosition,
                      previousEnd: previousEnd
                  ) else {
                return
            }
            scrollPosition = newEnd
        }
    }

    /// 曲线坐标下的可见窗口：宽度固定（默认 2 小时），随滚动位置平移，
    /// 因此拖动时间滑块时横向比例不变（不会出现拉伸/回缩）。
    private var visibleChartDomain: ClosedRange<Double> {
        let start = scrollRangeStart
        guard let scrollRange else {
            let end = chartData.plotSamples.isEmpty ? start + 1 : chartEnd
            return start...max(start + 1, end)
        }
        let lower = min(max(scrollPosition, scrollRange.lowerBound), scrollRange.upperBound)
        return PowerChartWindow.visibleChartDomain(startingAt: lower, end: chartEnd)
    }

    /// 曲线坐标下今日首条有效样本的位置。
    private var scrollRangeStart: Double {
        chartData.plotSamples.first.map { chartData.timeline.position(for: $0.timestamp) }
            ?? chartData.timeline.position(for: Date())
    }

    /// 曲线坐标下今日最后一条有效样本的位置。
    private var chartEnd: Double {
        chartData.plotSamples.last.map { chartData.timeline.position(for: $0.timestamp) }
            ?? chartData.timeline.position(for: Date())
    }

    /// 可见窗口对应的真实时间范围，用于筛选要绘制的样本。
    private var visibleDateDomain: ClosedRange<Date> {
        let domain = visibleChartDomain
        let lower = chartData.timeline.date(for: domain.lowerBound)
        return lower...max(lower, chartData.timeline.date(for: domain.upperBound))
    }

    private var axisMarks: [PowerChartAxisMark] {
        let domain = visibleDateDomain
        var marks: [PowerChartAxisMark] = []
        let calendar = Calendar.current
        var date = calendar.dateInterval(of: .hour, for: domain.lowerBound)?.start

        while let tick = date, tick <= domain.upperBound {
            if tick >= domain.lowerBound, !chartData.timeline.isInsideBreak(tick) {
                marks.append(
                    PowerChartAxisMark(
                        position: chartData.timeline.position(for: tick),
                        date: tick
                    )
                )
            }
            date = calendar.date(byAdding: .hour, value: 1, to: tick)
        }

        let visibleBreaks = chartData.timeline.breaks.filter {
            $0.duration > 5
                && $0.end > domain.lowerBound
                && $0.start < domain.upperBound
        }
        let markerStride = max(1, Int(ceil(Double(visibleBreaks.count) / 8)))
        for (index, interval) in visibleBreaks.enumerated() where index.isMultiple(of: markerStride) {
            // 断点不占宽度，标记直接画在跳变点上；断点起点在窗口左侧时钳到可见域左边缘。
            let position = min(
                max(chartData.timeline.position(for: interval.start), visibleChartDomain.lowerBound),
                visibleChartDomain.upperBound
            )
            marks.append(PowerChartAxisMark(position: position, date: nil))
        }

        return marks.sorted { $0.position < $1.position }
    }

    /// 只画正功率样本；无读数点、长缺口和系统睡眠都会切成独立曲线段。
    private var displaySegments: [[HistorySample]] {
        chartData.plotSegments.flatMap { segment in
            let visible = PowerChartWindow.samples(in: visibleDateDomain, from: segment)
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

    private func updateHover(
        _ phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        switch phase {
        case .ended:
            hoveredSample = nil
            hoverLocation = nil
        case .active(let location):
            guard let plotFrame = proxy.plotFrame else {
                hoveredSample = nil
                hoverLocation = nil
                return
            }

            let frame = geometry[plotFrame]
            guard frame.contains(location) else {
                hoveredSample = nil
                hoverLocation = nil
                return
            }

            let xPosition = location.x - frame.minX
            guard let coordinate: Double = proxy.value(atX: xPosition) else {
                hoveredSample = nil
                hoverLocation = nil
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

/// 今日电量曲线：整日一屏展示，不做横向滚动，支持悬停查看时间与电量。
struct TodayBatteryLevelChart: View {
    let chartData: BatteryLevelChartData
    @State private var hoveredSample: HistorySample?
    @State private var hoverLocation: CGPoint?
    /// 悬停位置与吸附样本超过该间隔视为"无数据"（待机缺口内不显示 tooltip）。
    private let hoverMaximumGap: TimeInterval = 180

    private var samples: [HistorySample] { chartData.samples }

    /// 以最后一条样本时间结尾（数据驱动），避免 2Hz 重渲染下按 `Date()` 每 0.5s 重新缩放抖动。
    private var xDomain: ClosedRange<Date> {
        BatteryLevelAxis.xDomain(now: samples.last?.timestamp ?? Date())
    }

    /// 缺口处断开连线；待机期间不记录样本，故无需再按待机区间过滤。
    private var displaySegments: [[HistorySample]] {
        PowerChartSegmentation.splitByGaps(chartData.displayedSamples)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日电量曲线")
                .font(.caption)
                .foregroundStyle(.secondary)

            if samples.isEmpty {
                ChartEmptyPlaceholder("暂无今日数据，应用运行后每 5 秒记录一次")
                    .frame(height: 120)
            } else {
                Chart {
                    ForEach(Array(displaySegments.enumerated()), id: \.offset) { _, segment in
                        ForEach(segment) { sample in
                            AreaMark(
                                x: .value("时间", sample.timestamp),
                                yStart: .value("电量下界", chartData.percentDomain.lowerBound),
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
                .chartXScale(domain: xDomain)
                .chartYScale(domain: chartData.percentDomain)
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
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick()
                        AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)))
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topTrailing) {
                            Rectangle()
                                .fill(.clear)
                                .onContinuousHover { phase in
                                    updateHover(phase, proxy: proxy, geometry: geometry)
                                }

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
                .frame(height: 138)
                .clipped()
                .accessibilityLabel("今日电量曲线")
                .accessibilityValue(levelAccessibilitySummary)
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
    }

    /// VoiceOver 概要：最新一条电量样本。
    private var levelAccessibilitySummary: String {
        guard let latest = samples.last else { return "暂无数据" }
        return "最新电量 \(BatteryFormatters.percent(latest.percent))"
    }

    private func updateHover(
        _ phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        switch phase {
        case .ended:
            hoveredSample = nil
            hoverLocation = nil
        case .active(let location):
            guard let plotFrame = proxy.plotFrame else {
                hoveredSample = nil
                hoverLocation = nil
                return
            }

            let frame = geometry[plotFrame]
            guard frame.contains(location) else {
                hoveredSample = nil
                hoverLocation = nil
                return
            }

            let xPosition = location.x - frame.minX
            guard let timestamp: Date = proxy.value(atX: xPosition) else {
                hoveredSample = nil
                hoverLocation = nil
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

/// 电池健康度历史趋势：取自每日汇总的最小健康度，展示长期损耗曲线（近 90 天）。
struct HealthTrendChart: View {
    let summaries: [DailySummary]
    @State private var hoveredSummary: DailySummary?
    @State private var hoverLocation: CGPoint?

    private var healthEntries: [DailySummary] {
        summaries
            .filter { $0.minHealthPercent != nil }
            .suffix(90)
    }

    private var latestHealth: Double? {
        healthEntries.last?.minHealthPercent
    }

    private var yDomain: ClosedRange<Double> {
        let healthValues = healthEntries.compactMap(\.minHealthPercent)
        // 上限随数据动态扩展：健康度可能超过 100%（新电池满充容量高于设计容量），
        // 固定 100% 会把数据点裁剪到绘图区外。
        let maximum = max(100, healthValues.max() ?? 100)
        let minimum = min(max((healthValues.min() ?? 100) - 5, 0), maximum - 1)
        return minimum...maximum
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            Text("电池健康趋势")
                .font(.caption)
                .foregroundStyle(.secondary)

            if healthEntries.isEmpty {
                ChartEmptyPlaceholder("暂无健康度数据，运行一段时间后自动生成")
                    .frame(height: 116)
            } else {
                Chart(healthEntries) { summary in
                    LineMark(
                        x: .value("日期", summary.date),
                        y: .value("健康度", summary.minHealthPercent ?? 0)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(BatteryStyling.healthTint(for: latestHealth))

                    if let hoveredSummary {
                        RuleMark(x: .value("悬停日期", hoveredSummary.date))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(.secondary.opacity(0.7))
                        PointMark(
                            x: .value("日期", hoveredSummary.date),
                            y: .value("健康度", hoveredSummary.minHealthPercent ?? 0)
                        )
                        .foregroundStyle(BatteryStyling.healthTint(for: hoveredSummary.minHealthPercent))
                        .symbolSize(36)
                    }
                }
                .chartYScale(domain: yDomain)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let health = value.as(Double.self) {
                                Text("\(Int(health.rounded()))%")
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits))
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.clear)
                                .onContinuousHover { phase in
                                    updateHover(phase, proxy: proxy, geometry: geometry)
                                }

                            if let hoveredSummary, let hoverLocation {
                                healthTooltip(for: hoveredSummary)
                                    .position(
                                        x: min(max(hoverLocation.x, 60), geometry.size.width - 60),
                                        y: min(max(hoverLocation.y - 26, 18), geometry.size.height - 18)
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(height: 116)
                .accessibilityLabel("电池健康趋势")
                .accessibilityValue(healthAccessibilitySummary)
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
    }

    /// VoiceOver 概要：最新健康度。
    private var healthAccessibilitySummary: String {
        guard let latestHealth else { return "暂无数据" }
        return String(format: "最新健康度 %.0f%%", latestHealth)
    }

    private func updateHover(
        _ phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        switch phase {
        case .ended:
            hoveredSummary = nil
            hoverLocation = nil
        case .active(let location):
            guard let plotFrame = proxy.plotFrame else {
                hoveredSummary = nil
                hoverLocation = nil
                return
            }
            let frame = geometry[plotFrame]
            guard frame.contains(location) else {
                hoveredSummary = nil
                hoverLocation = nil
                return
            }
            let xPosition = location.x - frame.minX
            guard let date: Date = proxy.value(atX: xPosition) else {
                hoveredSummary = nil
                hoverLocation = nil
                return
            }
            hoverLocation = location
            hoveredSummary = PowerChartInteraction.nearestDailySummary(to: date, from: healthEntries)
        }
    }

    private func healthTooltip(for summary: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.dayKey)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(summary.minHealthPercent.map { String(format: "%.0f%%", $0) } ?? "--")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(BatteryStyling.healthTint(for: summary.minHealthPercent))
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

    static func nearestDailySummary(
        to date: Date,
        from summaries: [DailySummary]
    ) -> DailySummary? {
        summaries.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    static func totalDailyEnergy(from summaries: [DailySummary]) -> Double? {
        let values = summaries.compactMap(\.energyKWh)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
}

struct HistoryMetricCard: View {
    let title: String
    let icon: String
    let value: String
    let caption: String
    let tint: Color

    var body: some View {
        KpiCard(title: title, icon: icon, verticalPadding: DesignTokens.spacingM) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
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
