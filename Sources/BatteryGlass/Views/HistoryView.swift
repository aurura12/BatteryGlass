import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(BatteryHistoryStore.self) private var history
    @Environment(ChartWindowController.self) private var chartWindow
    /// 面板是否在屏幕上。关闭后不再读取 `BatteryHistoryStore`：否则每 5 秒一条新样本
    /// 都会让离屏的整页（含两张图和逐样本 mark）重算一遍。
    var isVisible: Bool = true
    @State private var energyRange: EnergyHistoryRange = .fourteen
    // 历史页只随历史样本更新；缓存避免每次更新都重复扫描当天数据。
    @State private var todayCache = TodaySamplesCache()
    @State private var chartCache = PowerChartDataCache()
    @State private var levelChartCache = BatteryLevelChartDataCache()
    /// 隐藏时展示的最后一份数据：避免关闭动画期间闪成空态，也保证重新打开时立刻有内容。
    @State private var frozenSamples: [HistorySample] = []
    @State private var frozenSleepIntervals: [SleepInterval] = []
    @State private var frozenSummaries: [DailySummary] = []

    /// 面板历史页固定展示今天；按天切换只在放大窗口里提供。
    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    private var todaySamples: [HistorySample] {
        // 三元表达式只在可见分支读取 `history`，隐藏时不会建立观察依赖。
        isVisible ? todayCache.samples(from: history.samples, day: today) : frozenSamples
    }

    private var sleepIntervals: [SleepInterval] {
        isVisible ? history.sleepIntervals : frozenSleepIntervals
    }

    private var summaries: [DailySummary] {
        isVisible ? energyRange.summaries(from: history) : frozenSummaries
    }

    private var chartData: PowerChartData {
        chartCache.data(for: todaySamples, sleepIntervals: sleepIntervals)
    }

    private var levelChartData: BatteryLevelChartData {
        levelChartCache.data(for: todaySamples)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.spacingM) {
                DailyEnergyComparisonChart(
                    summaries: summaries,
                    range: $energyRange
                )

                TodayPowerChart(
                    chartData: chartData,
                    sleepIntervals: sleepIntervals,
                    day: today,
                    onExpand: { chartWindow.show(.power) }
                )
                // 跨天后以新的一天重建视图，重置缩放窗口。
                .id(today)

                TodayBatteryLevelChart(
                    chartData: levelChartData,
                    day: today,
                    onExpand: { chartWindow.show(.level) }
                )

            }
            .padding(.bottom, DesignTokens.spacingXS)
        }
        .scrollIndicators(.hidden)
        .task(id: cacheKey) {
            guard isVisible else { return }
            frozenSamples = todayCache.samples(from: history.samples, day: today)
            frozenSleepIntervals = history.sleepIntervals
            frozenSummaries = energyRange.summaries(from: history)
        }
    }

    /// 可见性或统计范围变化时刷新冻结数据；隐藏时保持不变。
    private struct CacheKey: Equatable {
        var isVisible: Bool
        var range: EnergyHistoryRange
    }

    private var cacheKey: CacheKey {
        CacheKey(isVisible: isVisible, range: energyRange)
    }
}
