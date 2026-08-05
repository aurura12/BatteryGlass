import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(BatteryHistoryStore.self) private var history
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.spacingM) {
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
