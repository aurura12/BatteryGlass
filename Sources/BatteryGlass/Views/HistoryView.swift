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
    let samples: [HistorySample]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日功率曲线")
                .font(.caption)
                .foregroundStyle(.secondary)

            if samples.isEmpty {
                ChartEmptyPlaceholder("暂无今日数据，应用运行后每 5 秒记录一次")
                    .frame(height: 120)
            } else {
                Chart(samples.suffix(720)) { sample in
                    AreaMark(
                        x: .value("时间", sample.timestamp),
                        y: .value("功率", sample.power)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [DesignTokens.dataBlue.opacity(0.22), DesignTokens.dataBlue.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("时间", sample.timestamp),
                        y: .value("功率", sample.power)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(DesignTokens.dataBlue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))

                    RuleMark(y: .value("零线", 0))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 120)
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
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
