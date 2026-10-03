import SwiftUI

/// 可在独立窗口放大查看的曲线。
enum ExpandedChart: String, CaseIterable, Identifiable {
    case power
    case level

    var id: String { rawValue }

    /// 与日期无关的曲线名。
    var baseTitle: String {
        switch self {
        case .power: "功率曲线"
        case .level: "电量曲线"
        }
    }

    /// 分段切换器用的短标签。
    var shortTitle: String {
        switch self {
        case .power: "功率"
        case .level: "电量"
        }
    }

    /// 窗口标题：日期 + 曲线名。
    func title(day: Date, now: Date = Date()) -> String {
        "\(BatteryFormatters.historyDayLabel(day, now: now)) · \(baseTitle)"
    }
}

/// 放大窗口的共享状态：切换曲线/日期只改这里的值，不重建窗口，位置与大小得以保留。
@MainActor
@Observable
final class ChartDetailModel {
    var kind: ExpandedChart = .power
    /// 当前查看的日期（当天 00:00）。
    var selectedDay: Date = Calendar.current.startOfDay(for: Date())
}

/// 放大窗口内的曲线视图。
///
/// 自行从 `BatteryHistoryStore` 取样本并记忆化曲线数据（与面板内各自一份），
/// 因此窗口开着时会随新样本实时刷新。窗口内可切换曲线，并用左右箭头逐天回看。
struct ChartDetailView: View {
    @Environment(BatteryHistoryStore.self) private var history
    let model: ChartDetailModel
    /// 选择变化回调，供窗口同步标题。
    let onSelectionChange: (ExpandedChart, Date) -> Void

    @State private var chartCache = PowerChartDataCache()
    @State private var levelChartCache = BatteryLevelChartDataCache()

    /// 可选日期与前后一天导航。
    private var daySelection: HistoryDaySelection {
        HistoryDaySelection(
            days: history.availableDays(),
            selected: model.selectedDay
        )
    }

    private var kindSelection: Binding<ExpandedChart> {
        Binding(
            get: { model.kind },
            set: { newValue in
                model.kind = newValue
                onSelectionChange(newValue, model.selectedDay)
            }
        )
    }

    var body: some View {
        let days = daySelection
        let samples = history.samples(forDay: days.selected)

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

                dayNavigator(days)

                Spacer(minLength: DesignTokens.spacingS)

                Text("⌘+滚轮缩放 · 双指横扫或按住拖动平移 · 🔍⟲ 重置")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            chart(kind: model.kind, day: days.selected, samples: samples)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 日期导航：`◀  8/25  ▶`，点中间日期弹出菜单直接跳到某天。
    @ViewBuilder
    private func dayNavigator(_ days: HistoryDaySelection) -> some View {
        HStack(spacing: 2) {
            dayStepButton(
                systemName: "chevron.left",
                help: "前一天",
                isEnabled: days.canGoOlder
            ) {
                guard let day = days.olderDay else { return }
                model.selectedDay = day
                onSelectionChange(model.kind, day)
            }

            Menu {
                ForEach(days.days.reversed(), id: \.self) { day in
                    Button(days.label(for: day)) {
                        model.selectedDay = day
                        onSelectionChange(model.kind, day)
                    }
                }
            } label: {
                Text(days.label)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 56)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("选择日期")

            dayStepButton(
                systemName: "chevron.right",
                help: "后一天",
                isEnabled: days.canGoNewer
            ) {
                guard let day = days.newerDay else { return }
                model.selectedDay = day
                onSelectionChange(model.kind, day)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall)
                .fill(.quaternary)
        )
    }

    @ViewBuilder
    private func dayStepButton(
        systemName: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .secondary : .tertiary)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func chart(kind: ExpandedChart, day: Date, samples: [HistorySample]) -> some View {
        switch kind {
        case .power:
            TodayPowerChart(
                chartData: chartCache.data(for: samples, sleepIntervals: history.sleepIntervals),
                sleepIntervals: history.sleepIntervals,
                day: day,
                plotHeight: nil
            )
        case .level:
            TodayBatteryLevelChart(
                chartData: levelChartCache.data(for: samples),
                day: day,
                plotHeight: nil
            )
        }
    }
}
