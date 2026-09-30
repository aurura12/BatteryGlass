import SwiftUI

/// 可在独立窗口放大查看的曲线（窗口内即为 4 个标签页）。
enum ExpandedChart: String, CaseIterable, Identifiable {
    case power
    case level
    case temperature
    case voltage

    var id: String { rawValue }

    /// 与天数无关的曲线名；窗口标题用 `title(range:)` 组合。
    var baseTitle: String {
        switch self {
        case .power: "功率曲线"
        case .level: "电量曲线"
        case .temperature: "温度曲线"
        case .voltage: "电压曲线"
        }
    }

    /// 窗口标题：范围 + 曲线名。
    func title(range: HistoryRange) -> String {
        "\(range.title) · \(baseTitle)"
    }

    /// 分段切换器用的短标签。
    var shortTitle: String {
        switch self {
        case .power: "功率"
        case .level: "电量"
        case .temperature: "温度"
        case .voltage: "电压"
        }
    }

    /// 该标签对应的温压指标；非温压标签为 nil。
    var metric: TodayMetric? {
        switch self {
        case .power, .level: nil
        case .temperature: .temperature
        case .voltage: .voltage
        }
    }

    /// 温压指标对应的标签。
    init(metric: TodayMetric) {
        self = metric == .temperature ? .temperature : .voltage
    }
}

/// 放大窗口的共享状态：切换曲线/范围只改这里的值，不重建窗口，位置与大小得以保留。
@MainActor
@Observable
final class ChartDetailModel {
    var kind: ExpandedChart = .power
    var range: HistoryRange = .today
}

/// 放大窗口内的曲线视图。
///
/// 自行从 `BatteryHistoryStore` 取样本并记忆化曲线数据（与面板内各自一份），
/// 因此窗口开着时会随新样本实时刷新。窗口内可直接切换曲线与显示范围。
struct ChartDetailView: View {
    @Environment(BatteryHistoryStore.self) private var history
    let model: ChartDetailModel
    /// 选择变化回调，供窗口同步标题。
    let onSelectionChange: (ExpandedChart, HistoryRange) -> Void

    @State private var todayCache = TodaySamplesCache()
    @State private var chartCache = PowerChartDataCache()
    @State private var levelChartCache = BatteryLevelChartDataCache()

    private var kindSelection: Binding<ExpandedChart> {
        Binding(
            get: { model.kind },
            set: { newValue in
                model.kind = newValue
                onSelectionChange(newValue, model.range)
            }
        )
    }

    private var rangeSelection: Binding<HistoryRange> {
        Binding(
            get: { model.range },
            set: { newValue in
                model.range = newValue
                onSelectionChange(model.kind, newValue)
            }
        )
    }

    var body: some View {
        let samples = todayCache.samples(from: history.samples, days: model.range.days)
        let dayKey = BatteryFormatters.dayKey(for: Date())

        return VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(spacing: DesignTokens.spacingM) {
                Picker("曲线", selection: kindSelection) {
                    ForEach(ExpandedChart.allCases) { kind in
                        Text(kind.shortTitle).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Picker("范围", selection: rangeSelection) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: DesignTokens.spacingS)

                Text("⌘+滚轮缩放 · 双指横扫或按住拖动平移 · 🔍⟲ 重置")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            chart(kind: model.kind, range: model.range, samples: samples, dayKey: dayKey)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func chart(
        kind: ExpandedChart,
        range: HistoryRange,
        samples: [HistorySample],
        dayKey: String
    ) -> some View {
        switch kind {
        case .power:
            TodayPowerChart(
                chartData: chartCache.data(for: samples, sleepIntervals: history.sleepIntervals),
                sleepIntervals: history.sleepIntervals,
                dayKey: dayKey,
                range: range,
                plotHeight: nil
            )
        case .level:
            TodayBatteryLevelChart(
                chartData: levelChartCache.data(for: samples),
                dayKey: dayKey,
                range: range,
                plotHeight: nil
            )
        case .temperature, .voltage:
            // 指标由标签页决定，内置切换器在这里隐藏，避免出现两层重复控件。
            TodayMetricChart(
                samples: samples,
                dayKey: dayKey,
                range: range,
                plotHeight: nil,
                fixedMetric: kind.metric
            )
        }
    }
}
