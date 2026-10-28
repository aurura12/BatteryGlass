import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(BatteryHistoryStore.self) private var history
    @Environment(ChartWindowController.self) private var chartWindow
    /// 面板是否在屏幕上。关闭后不再读取 `BatteryHistoryStore`：否则每 5 秒一条新样本
    /// 都会让离屏的整页（含两张图和逐样本 mark）重算一遍。
    var isVisible: Bool = true

    @State private var energyRange: EnergyHistoryRange = .fourteen
    @State private var todayCache = TodaySamplesCache()
    @State private var chartCache = PowerChartDataCache()
    @State private var levelChartCache = BatteryLevelChartDataCache()

    /// 用户选中的日期（当天 00:00）。`followsToday` 为 true 时忽略它、始终跟随日历上的今天，
    /// 这样跨午夜会自动切到新的一天，而不是停在旧日期。
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var followsToday = true
    /// 往日曲线在后台从归档读取（`body` 里同步查 SQLite 会卡住面板）。
    @State private var archivedSamples: [HistorySample] = []
    @State private var loadedArchiveDay: Date?

    /// 隐藏时展示的最后一份数据：避免关闭动画期间闪成空态，也保证重新打开时立刻有内容。
    @State private var frozenSamples: [HistorySample] = []
    @State private var frozenSleepIntervals: [SleepInterval] = []
    @State private var frozenSummaries: [DailySummary] = []
    @State private var frozenDays: [Date] = []

    private var activeDay: Date {
        followsToday ? Calendar.current.startOfDay(for: Date()) : selectedDay
    }

    private var days: [Date] {
        isVisible ? history.availableDays() : frozenDays
    }

    private var daySelection: HistoryDaySelection {
        HistoryDaySelection(days: days, selected: activeDay)
    }

    private var renderedSamples: [HistorySample] {
        // 往日曲线来自归档（静态），隐藏时也无需冻结。
        if !followsToday { return archivedSamples }
        return isVisible
            ? todayCache.samples(from: history.samples, day: activeDay)
            : frozenSamples
    }

    private var sleepIntervals: [SleepInterval] {
        isVisible ? history.sleepIntervals : frozenSleepIntervals
    }

    private var summaries: [DailySummary] {
        isVisible ? energyRange.summaries(from: history) : frozenSummaries
    }

    private var chartData: PowerChartData {
        chartCache.data(for: renderedSamples, sleepIntervals: sleepIntervals)
    }

    private var levelChartData: BatteryLevelChartData {
        levelChartCache.data(for: renderedSamples)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.spacingM) {
                DailyEnergyComparisonChart(
                    summaries: summaries,
                    range: $energyRange
                )

                HStack(spacing: DesignTokens.spacingS) {
                    Text("功率 / 电量曲线")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    HistoryDayNavigator(
                        selection: daySelection,
                        labelFont: .system(size: 11, weight: .medium)
                    ) { day in
                        selectedDay = day
                        followsToday = Calendar.current.isDate(day, inSameDayAs: Date())
                    }
                }
                .padding(.horizontal, DesignTokens.spacingXS)

                TodayPowerChart(
                    chartData: chartData,
                    sleepIntervals: sleepIntervals,
                    day: activeDay,
                    onExpand: { chartWindow.show(.power) }
                )
                // 换日重建视图，重置缩放与悬停。
                .id(activeDay)

                TodayBatteryLevelChart(
                    chartData: levelChartData,
                    day: activeDay,
                    onExpand: { chartWindow.show(.level) }
                )
            }
            .padding(.bottom, DesignTokens.spacingXS)
        }
        .scrollIndicators(.hidden)
        .task(id: cacheKey) {
            guard isVisible else { return }
            if followsToday {
                frozenSamples = todayCache.samples(from: history.samples, day: activeDay)
            }
            frozenSleepIntervals = history.sleepIntervals
            frozenSummaries = energyRange.summaries(from: history)
            frozenDays = history.availableDays()
        }
        .task(id: reloadKey) {
            await reloadArchivedDayIfNeeded()
        }
    }

    /// 往日曲线异步加载：切换日期时先清空，避免旧一天的曲线配新一天的时间轴。
    private func reloadArchivedDayIfNeeded() async {
        guard isVisible, !followsToday else { return }
        let day = activeDay
        if loadedArchiveDay != day {
            archivedSamples = []
        }
        let loaded = await history.samplesAsync(forDay: day)
        guard !Task.isCancelled, activeDay == day, !followsToday else { return }
        archivedSamples = loaded
        loadedArchiveDay = day
    }

    /// 可见性、统计范围或归档日期变化时刷新冻结数据；隐藏时保持不变。
    private struct CacheKey: Equatable {
        var isVisible: Bool
        var range: EnergyHistoryRange
        var archivedDayCount: Int
    }

    private var cacheKey: CacheKey {
        CacheKey(
            isVisible: isVisible,
            range: energyRange,
            archivedDayCount: isVisible ? history.archivedDays.count : 0
        )
    }

    /// 只有查看往日时才需要重新读取归档；今天走 `history.samples` 的实时观察。
    private struct ReloadKey: Equatable {
        var day: Date
        var isVisible: Bool
        var followsToday: Bool
        var archivedDayCount: Int
    }

    private var reloadKey: ReloadKey {
        ReloadKey(
            day: activeDay,
            isVisible: isVisible,
            followsToday: followsToday,
            archivedDayCount: isVisible ? history.archivedDays.count : 0
        )
    }
}
