import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(BatteryHistoryStore.self) private var history
    @Environment(BatteryMonitor.self) private var monitor
    @State private var energyRange: EnergyHistoryRange = .fourteen

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.spacingM) {
                DailyEnergyComparisonChart(
                    summaries: energyRange.summaries(from: history),
                    range: $energyRange
                )

                TodayPowerChart(samples: history.samplesForDay(Date()))

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

struct DailyEnergyComparisonChart: View {
    let summaries: [DailySummary]
    @Binding var range: EnergyHistoryRange
    @State private var grouping: EnergyGrouping = .day
    @State private var hoveredAggregate: EnergyAggregate?

    private var energySummaries: [DailySummary] {
        summaries.filter { $0.energyKWh != nil }
    }

    private var aggregates: [EnergyAggregate] {
        EnergyAggregator.aggregate(summaries: energySummaries, grouping: grouping)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack {
                Text("每日耗电量（\(range.title)）")
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
                    AxisMarks(values: .stride(by: grouping.xStride)) { value in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(xAxisLabel(for: date))
                            }
                        }
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

                comparisonMetrics
            }

            if !summaries.isEmpty {
                dailyDetails
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
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
        .padding(.top, DesignTokens.spacingXS)
    }
}

struct TodayPowerChart: View {
    let energySamples: [HistorySample]
    let chartSamples: [HistorySample]
    let scrollStartDate: Date
    let scrollEndDate: Date
    @State private var scrollPosition: Date
    @State private var hoveredSample: HistorySample?
    @State private var hoverLocation: CGPoint?

    init(samples: [HistorySample]) {
        let chartData = PowerChartData(samples: samples, maximumDisplayedSamples: 800)
        self.energySamples = chartData.energySamples
        self.chartSamples = chartData.chartSamples
        let bounds = PowerChartWindow.scrollBounds(for: chartData.energySamples)
        let start = bounds?.start ?? Date()
        let end = bounds?.end ?? start
        self.scrollStartDate = start
        self.scrollEndDate = end
        self._scrollPosition = State(initialValue: end)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("今日功率曲线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if chartSamples.count > 1 {
                    Text("横向滚动查看")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if energySamples.isEmpty {
                ChartEmptyPlaceholder("暂无今日数据，应用运行后每 5 秒记录一次")
                    .frame(height: 120)
            } else {
                VStack(spacing: 4) {
                    Chart {
                        ForEach(visibleChartSamples) { sample in
                            AreaMark(
                                x: .value("时间", sample.timestamp),
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
                                x: .value("时间", sample.timestamp),
                                y: .value("功率", sample.consumptionPowerW ?? 0)
                            )
                            .interpolationMethod(.linear)
                            .foregroundStyle(DesignTokens.dataBlue)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        }

                        RuleMark(y: .value("零线", 0))
                            .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3]))
                            .foregroundStyle(.secondary.opacity(0.5))

                        if let hoveredSample,
                           let power = hoveredSample.consumptionPowerW {
                            RuleMark(x: .value("悬停时间", hoveredSample.timestamp))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundStyle(DesignTokens.dataBlue.opacity(0.7))

                            PointMark(
                                x: .value("时间", hoveredSample.timestamp),
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
                        AxisMarks(values: .stride(by: .hour)) { _ in
                            AxisGridLine().foregroundStyle(.clear)
                            AxisTick()
                            AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)))
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

                    if scrollEndDate > scrollStartDate {
                        Slider(
                            value: scrollPositionBinding,
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
        .onChange(of: scrollEndDate) { previousEnd, newEnd in
            guard previousEnd != newEnd,
                  PowerChartWindow.shouldFollowLatest(
                      currentPosition: scrollPosition,
                      previousEnd: previousEnd
                  ) else {
                return
            }
            scrollPosition = newEnd
        }
    }

    private var scrollRange: ClosedRange<Double> {
        scrollStartDate.timeIntervalSinceReferenceDate...scrollEndDate.timeIntervalSinceReferenceDate
    }

    private var visibleChartDomain: ClosedRange<Date> {
        guard let latest = energySamples.last?.timestamp else {
            let fallback = Date()
            return fallback...fallback.addingTimeInterval(1)
        }

        return PowerChartWindow.visibleDomain(
            startingAt: scrollPosition,
            latest: latest
        )
    }

    private var visibleChartSamples: [HistorySample] {
        PowerChartWindow.samples(in: visibleChartDomain, from: chartSamples)
    }

    private var scrollPositionBinding: Binding<Double> {
        Binding(
            get: { scrollPosition.timeIntervalSinceReferenceDate },
            set: { scrollPosition = Date(timeIntervalSinceReferenceDate: $0) }
        )
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
            hoveredSample = PowerChartInteraction.nearestSample(
                to: timestamp,
                from: energySamples
            )
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
        let minimum = (healthValues.min() ?? 100) - 5
        return min(max(minimum, 0), 99)...100
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
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
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
    let energySamples: [HistorySample]
    let chartSamples: [HistorySample]

    init(samples: [HistorySample], maximumDisplayedSamples: Int) {
        let energySamples = samples.filter { $0.consumptionPowerW != nil }
        self.energySamples = energySamples

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
}

enum PowerChartWindow {
    static let defaultVisibleDuration: TimeInterval = 7_200

    static func samples(
        in domain: ClosedRange<Date>,
        from samples: [HistorySample]
    ) -> [HistorySample] {
        samples.filter { domain.contains($0.timestamp) }
    }

    static func visibleDomain(
        startingAt start: Date,
        latest: Date,
        visibleDuration: TimeInterval = defaultVisibleDuration
    ) -> ClosedRange<Date> {
        let upper = min(latest, start.addingTimeInterval(visibleDuration))
        return start...max(start.addingTimeInterval(1), upper)
    }

    static func scrollBounds(
        for samples: [HistorySample],
        visibleDuration: TimeInterval = defaultVisibleDuration
    ) -> (start: Date, end: Date)? {
        guard let first = samples.first?.timestamp,
              let latest = samples.last?.timestamp else {
            return nil
        }

        return (
            start: first,
            end: max(first, latest.addingTimeInterval(-visibleDuration))
        )
    }

    static func initialScrollDate(
        for samples: [HistorySample],
        visibleDuration: TimeInterval = defaultVisibleDuration
    ) -> Date? {
        scrollBounds(for: samples, visibleDuration: visibleDuration)?.end
    }

    static func shouldFollowLatest(
        currentPosition: Date,
        previousEnd: Date,
        tolerance: TimeInterval = 10
    ) -> Bool {
        currentPosition >= previousEnd.addingTimeInterval(-tolerance)
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
        KpiCard(title: title, icon: icon) {
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
