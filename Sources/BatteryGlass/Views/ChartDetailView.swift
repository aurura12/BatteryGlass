import SwiftUI

/// 可在独立窗口放大查看的曲线。
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

/// 放大窗口的共享状态：切换曲线只改这里的值，不重建窗口，位置与大小得以保留。
@MainActor
@Observable
final class ChartDetailModel {
    var kind: ExpandedChart = .power
}

/// 放大窗口内的曲线视图。
///
/// 自行从 `BatteryHistoryStore` 取当天样本并记忆化曲线数据（与面板内各自一份），
/// 因此窗口开着时会随新样本实时刷新。
struct ChartDetailView: View {
    @Environment(BatteryHistoryStore.self) private var history
    let model: ChartDetailModel

    @State private var todayCache = TodaySamplesCache()
    @State private var chartCache = PowerChartDataCache()
    @State private var levelChartCache = BatteryLevelChartDataCache()

    var body: some View {
        let samples = todayCache.samples(from: history.samples)
        let dayKey = BatteryFormatters.dayKey(for: Date())

        return VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            chart(kind: model.kind, samples: samples, dayKey: dayKey)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Text("⌘+滚轮缩放时间轴 · 双指横扫或按住拖动平移 · 🔍⟲ 重置")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func chart(kind: ExpandedChart, samples: [HistorySample], dayKey: String) -> some View {
        switch kind {
        case .power:
            TodayPowerChart(
                chartData: chartCache.data(for: samples, sleepIntervals: history.sleepIntervals),
                sleepIntervals: history.sleepIntervals,
                dayKey: dayKey,
                plotHeight: nil
            )
        case .level:
            TodayBatteryLevelChart(
                chartData: levelChartCache.data(for: samples),
                dayKey: dayKey,
                plotHeight: nil
            )
        case .metric:
            TodayMetricChart(
                samples: samples,
                dayKey: dayKey,
                plotHeight: nil
            )
        }
    }
}
