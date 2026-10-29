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
    /// 窗口是否真的在屏幕上（可见且未最小化）。关闭或最小化后视图停止重新加载曲线数据。
    var isVisible = false

    /// 选中日被清除后，让窗口标题、实际加载日期和导航器回退到同一天。
    @discardableResult
    func reconcileSelectedDay(days: [Date], now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let resolved = HistoryDaySelection(days: days, selected: selectedDay, now: now, calendar: calendar).selected
        guard resolved != selectedDay else { return false }
        selectedDay = resolved
        return true
    }
}

/// 放大窗口内的曲线视图。
///
/// 样本通过 `BatteryHistoryStore.samplesAsync(forDay:)` 在持久化队列上读取，`body`
/// 不再同步查 SQLite；只有窗口可见时才按采样节拍重新加载，关闭或最小化后完全停止。
struct ChartDetailView: View {
    @Environment(BatteryHistoryStore.self) private var history
    @Environment(AppSettings.self) private var settings
    let model: ChartDetailModel
    /// 选择变化回调，供窗口同步标题。
    let onSelectionChange: (ExpandedChart, Date) -> Void

    @State private var chartCache = PowerChartDataCache()
    @State private var levelChartCache = BatteryLevelChartDataCache()
    /// 可选日期与当前日期样本，由 `reload()` 异步填充。
    @State private var availableDays: [Date] = []
    @State private var samples: [HistorySample] = []
    /// `samples` 当前对应的日期；换日时先清空，避免用旧一天的曲线配新一天的时间轴。
    @State private var loadedDay: Date?

    /// 重新加载的条件：日期、可见性、热层样本与归档索引。
    /// 不可见时刻意不读取热层计数，避免后台采样持续触发视图重算。
    private struct ReloadKey: Equatable {
        var day: Date
        var isVisible: Bool
        var liveCount: Int
        var liveLastID: UUID?
        /// 诊断回填只改读数、不改数量与 id，缺少版本号时窗口会一直显示回填前的曲线。
        var samplesVersion: Int
        var archivedDayCount: Int
    }

    private var reloadKey: ReloadKey {
        let visible = model.isVisible
        return ReloadKey(
            day: model.selectedDay,
            isVisible: visible,
            liveCount: visible ? history.samples.count : 0,
            liveLastID: visible ? history.samples.last?.id : nil,
            samplesVersion: visible ? history.samplesVersion : 0,
            archivedDayCount: visible ? history.archivedDays.count : 0
        )
    }

    /// 可选日期与前后一天导航。
    private var daySelection: HistoryDaySelection {
        HistoryDaySelection(days: availableDays, selected: model.selectedDay)
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

                HistoryDayNavigator(selection: days) { day in
                    model.selectedDay = day
                    onSelectionChange(model.kind, day)
                }

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
        .task(id: reloadKey) { await reload() }
        // 窗口的 NSHostingView 只创建一次，主题色必须在视图内跟随设置，不能在建窗时快照。
        .environment(\.themeAccent, settings.themeAccent.color)
    }

    /// 记录不可用时，空图要说明原因而不是提示「应用运行后每 5 秒记录一次」。
    private var emptyCurveMessage: String? {
        HistoryRecordingNotice.resolve(
            recordingEnabled: settings.recordHistory,
            persistenceIssue: history.persistenceIssue
        )?.emptyCurveMessage
    }

    /// 异步加载当前日期的样本。窗口不可见时直接返回，关闭状态下不产生任何查询。
    private func reload() async {
        guard model.isVisible else { return }
        availableDays = history.availableDays()
        if model.reconcileSelectedDay(days: availableDays) {
            onSelectionChange(model.kind, model.selectedDay)
        }
        let day = model.selectedDay
        if loadedDay != day {
            samples = []
            loadedDay = day
        }
        let loaded = await history.samplesAsync(forDay: day)
        guard !Task.isCancelled, model.selectedDay == day else { return }
        samples = loaded
    }


    @ViewBuilder
    private func chart(kind: ExpandedChart, day: Date, samples: [HistorySample]) -> some View {
        switch kind {
        case .power:
            TodayPowerChart(
                chartData: chartCache.data(
                    for: samples,
                    sleepIntervals: history.sleepIntervals,
                    version: history.samplesVersion
                ),
                sleepIntervals: history.sleepIntervals,
                day: day,
                emptyMessage: emptyCurveMessage ?? "暂无有效功率曲线",
                plotHeight: nil
            )
        case .level:
            TodayBatteryLevelChart(
                chartData: levelChartCache.data(for: samples, version: history.samplesVersion),
                day: day,
                emptyMessage: emptyCurveMessage,
                plotHeight: nil
            )
        }
    }
}
