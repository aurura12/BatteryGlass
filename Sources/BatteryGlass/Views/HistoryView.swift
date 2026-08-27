import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(BatteryHistoryStore.self) private var history
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.spacingM) {
                DailyEnergyComparisonChart(
                    summaries: history.summaries(lastDays: 14)
                )

                TodayPowerChart(samples: history.samplesForDay(Date()))

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

struct DailyEnergyComparisonChart: View {
    let summaries: [DailySummary]

    private var energySummaries: [DailySummary] {
        summaries.filter { $0.energyKWh != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            Text("每日耗电量（近 14 天）")
                .font(.caption)
                .foregroundStyle(.secondary)

            if energySummaries.isEmpty {
                ChartEmptyPlaceholder("升级后开始累计每日耗电量")
                    .frame(height: 138)
            } else {
                Chart(energySummaries) { summary in
                    BarMark(
                        x: .value("日期", summary.date, unit: .day),
                        y: .value("耗电量", summary.energyKWh ?? 0)
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
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day(.defaultDigits))
                    }
                }
                .frame(height: 138)

                comparisonMetrics
                dailyDetails
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
    }

    private var comparisonMetrics: some View {
        HStack(spacing: DesignTokens.spacingM) {
            energyMetric(title: "今日", value: todayEnergy)
            Divider()
                .frame(height: 24)
            energyMetric(title: "最高", value: maximumEnergy)
            Divider()
                .frame(height: 24)
            energyMetric(title: "日均", value: averageEnergy)
        }
        .padding(.top, DesignTokens.spacingXS)
    }

    private func energyMetric(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value.map { String(format: "%.2f kWh", $0) } ?? "--")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.dataBlue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var todayKey: String {
        BatteryFormatters.dayKey(for: Date())
    }

    private var todayEnergy: Double? {
        energySummaries.first { $0.dayKey == todayKey }?.energyKWh
    }

    private var maximumEnergy: Double? {
        energySummaries.compactMap(\.energyKWh).max()
    }

    private var averageEnergy: Double? {
        let values = energySummaries.compactMap(\.energyKWh)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var dailyDetails: some View {
        VStack(spacing: DesignTokens.spacingXS) {
            Divider()

            ForEach(energySummaries.reversed()) { summary in
                HStack {
                    Text(summary.dayKey)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f kWh", summary.energyKWh ?? 0))
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
                        ForEach(chartSamples) { sample in
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
                    .chartScrollableAxes(.horizontal)
                    .scrollIndicators(.hidden, axes: .horizontal)
                    .chartXVisibleDomain(length: PowerChartWindow.defaultVisibleDuration)
                    .chartScrollPosition(x: $scrollPosition)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            ZStack(alignment: .topTrailing) {
                                Rectangle()
                                    .fill(.clear)
                                    .onContinuousHover { phase in
                                        updateHover(phase, proxy: proxy, geometry: geometry)
                                    }

                                if let hoveredSample {
                                    hoverTooltip(for: hoveredSample)
                                        .padding(8)
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
        case .active(let location):
            guard let plotFrame = proxy.plotFrame else {
                hoveredSample = nil
                return
            }

            let frame = geometry[plotFrame]
            guard frame.contains(location) else {
                hoveredSample = nil
                return
            }

            let xPosition = location.x - frame.minX
            guard let timestamp: Date = proxy.value(atX: xPosition) else {
                hoveredSample = nil
                return
            }

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
