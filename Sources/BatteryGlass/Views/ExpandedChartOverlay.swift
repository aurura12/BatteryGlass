import SwiftUI

/// 历史页可放大查看的曲线。
enum ExpandedChart: String, Identifiable {
    case power
    case level
    case metric

    var id: String { rawValue }

    var title: String {
        switch self {
        case .power: "今日功率曲线"
        case .level: "今日电量曲线"
        case .metric: "今日温度 / 电压曲线"
        }
    }
}

/// 面板内放大浮层：在历史内容区覆盖一张更大的曲线图，复用同一批曲线视图。
///
/// 面板窗口固定 392×672，故不新建窗口；浮层高度撑满历史内容区，绘图区因此
/// 从 ~138pt 提升到 ~400pt。浮层内的曲线是独立实例，拥有各自的缩放窗口。
struct ExpandedChartOverlay: View {
    let kind: ExpandedChart
    let chartData: PowerChartData
    let levelData: BatteryLevelChartData
    let metricSamples: [HistorySample]
    let sleepIntervals: [SleepInterval]
    let dayKey: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(spacing: DesignTokens.spacingS) {
                Text(kind.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭放大视图")
                .accessibilityLabel("关闭放大视图")
            }

            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelGlassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
        .onExitCommand(perform: onClose)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var chart: some View {
        switch kind {
        case .power:
            TodayPowerChart(
                chartData: chartData,
                sleepIntervals: sleepIntervals,
                dayKey: dayKey,
                plotHeight: nil
            )
        case .level:
            TodayBatteryLevelChart(
                chartData: levelData,
                dayKey: dayKey,
                plotHeight: nil
            )
        case .metric:
            TodayMetricChart(
                samples: metricSamples,
                dayKey: dayKey,
                plotHeight: nil
            )
        }
    }
}
