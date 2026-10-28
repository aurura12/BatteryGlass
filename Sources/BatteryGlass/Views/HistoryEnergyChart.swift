import Charts
import SwiftUI

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
    /// 没有可用日汇总时的提示；记录关闭/暂停时由调用方改成对应原因。
    var emptyMessage: String = "暂无可用每日耗电量数据"
    @Environment(\.themeAccent) private var themeAccent
    @State private var grouping: EnergyGrouping = .day
    @State private var hoveredAggregate: EnergyAggregate?
    @State private var dailyDetailsState = DailyDetailsDisclosureState()
    @State private var aggregateCache = DailyAggregateCache()

    private var aggregates: [EnergyAggregate] {
        aggregateCache.aggregates(summaries: summaries, grouping: grouping)
    }

    /// 柱图从 0 起算：Y 域取 0…峰值×1.1（至少 0.1 kWh），刻度走整齐步长 + 自适应小数位
    /// （固定 %.1f 会让 0.0x kWh 量级的刻度全塌成 "0.0"）。
    private var energyAxis: AxisTickScale {
        let peak = aggregates.map(\.energyKWh).max() ?? 0
        return EnergyAxisScale.ticks(in: 0...max(peak * 1.1, 0.1))
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
                ChartEmptyPlaceholder(emptyMessage)
                    .frame(height: 138)
            } else {
                Chart(aggregates) { aggregate in
                    BarMark(
                        x: .value("日期", aggregate.periodStart),
                        y: .value("耗电量", aggregate.energyKWh)
                    )
                    .foregroundStyle(themeAccent.gradient)
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
                .foregroundStyle(themeAccent)
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
                .foregroundStyle(themeAccent)
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
                            .foregroundStyle(themeAccent)
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

    /// 生成日能耗质量角标的原因文案；多条原因按标记顺序以「；」拼接。
    private func energyQualityWarning(for summary: DailySummary) -> String? {
        guard let quality = summary.energyQuality else { return nil }
        var reasons: [String] = []
        if quality.hasSamplingGaps {
            reasons.append("当天存在采样断点或累计功率读数缺失，耗电量可能偏低")
        }
        if quality.hasUnmeasuredSleepEnergy {
            reasons.append("部分睡眠时段缺少能耗记录，耗电量可能偏低")
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
