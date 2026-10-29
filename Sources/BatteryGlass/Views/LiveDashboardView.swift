import SwiftUI

/// 实时页「今日耗电」的展示值：数值 + 是否需要告警。
/// 面板离屏时与快照一起冻结，避免离屏内容订阅 `BatteryHistoryStore`。
struct TodayEnergyDisplay: Equatable {
    var energyKWh: Double?
    var needsAttention: Bool
    var warningText: String?
    var qualityLabel: String

    /// 记录关闭后今天的汇总不再增长，卡片上的数值只是关闭那一刻的快照。
    private static let recordingDisabledWarning = "历史记录已关闭，之后的使用未计入今日耗电"

    init(summary: DailySummary?, recordingEnabled: Bool) {
        energyKWh = summary.flatMap { $0.hasValidEnergy ? $0.energyKWh : nil }
        let quality = summary?.energyQuality
        let summaryNeedsAttention = summary?.needsEnergyAttention ?? false
        let summaryWarning = quality?.warningText

        guard recordingEnabled else {
            // 数值停在关闭时刻、之后不再增长，必须让它看起来「不再更新」，
            // 否则用户只看到一串普通数字，以为耗电真的没变。
            needsAttention = energyKWh != nil || summaryNeedsAttention
            warningText = ([Self.recordingDisabledWarning, summaryWarning] as [String?])
                .compactMap { $0 }
                .joined(separator: "；")
            qualityLabel = energyKWh == nil ? "暂无有效数据" : "记录已关闭"
            return
        }

        needsAttention = summaryNeedsAttention
        warningText = summaryWarning
        qualityLabel = Self.qualityLabel(for: quality, hasValue: energyKWh != nil)
    }

    private static func qualityLabel(for quality: DailyEnergyQuality?, hasValue: Bool) -> String {
        guard hasValue else { return "暂无有效数据" }
        if quality?.hasSamplingGaps == true
            || quality?.hasUnmeasuredSleepEnergy == true
            || quality?.hasLowerBoundSleepEnergy == true {
            return "记录不完整"
        }
        if quality?.hasEstimatedSleepEnergy == true {
            return "含估算"
        }
        if quality?.hasUncalibratedCounterEnergy == true {
            return "未校准"
        }
        if quality?.hasUnknownHistoricalCoverage == true {
            return "旧版记录"
        }
        return "查看统计说明"
    }
}

/// 面板离屏时冻结的实时页数据：快照、功率缓冲与今日能耗。
struct LiveDashboardRenderedData {
    var snapshot: BatterySnapshot
    var recentPower: [PowerSample]
    var todayEnergy: TodayEnergyDisplay
}

struct LiveDashboardView: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(BatteryHistoryStore.self) private var history
    @Environment(AppSettings.self) private var settings
    /// 面板离屏时传入最后一份数据；非 nil 时整页不再订阅 `BatteryMonitor` / `BatteryHistoryStore`，
    /// 避免离屏内容随每秒发布与每 5 秒汇总重算 4 张 KPI 卡片、功率趋势、指标网格。
    var rendered: LiveDashboardRenderedData?

    private var snapshot: BatterySnapshot { rendered?.snapshot ?? monitor.snapshot }
    private var powerSamples: [PowerSample] { rendered?.recentPower ?? monitor.recentPower }
    private var todayEnergy: TodayEnergyDisplay {
        rendered?.todayEnergy
            ?? TodayEnergyDisplay(
                summary: history.todaySummary,
                recordingEnabled: settings.recordHistory
            )
    }

    var body: some View {
        VStack(spacing: DashboardLayout.contentSpacing) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: DesignTokens.spacingM),
                    GridItem(.flexible(), spacing: DesignTokens.spacingM)
                ],
                spacing: DashboardLayout.contentSpacing
            ) {
                BatteryPercentCard(snapshot: snapshot)
                PowerKpiCard(snapshot: snapshot)
                CycleKpiCard(snapshot: snapshot)
                HealthKpiCard(snapshot: snapshot)
            }

            if snapshot.adapterConnected, snapshot.displayState != .discharging {
                AdapterSplitCard(snapshot: snapshot)
            }

            PowerTrendCard(
                samples: powerSamples,
                snapshot: snapshot,
                todayEnergy: todayEnergy
            )

            MetricsGrid(snapshot: snapshot)
        }
    }
}

// MARK: - 电源分配（充电 / 直供 / 适配器合计）

struct AdapterSplitCard: View {
    let snapshot: BatterySnapshot
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            Label("电源分配", systemImage: "powerplug")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: DesignTokens.spacingM) {
                splitItem(
                    title: batterySplit.title,
                    icon: batterySplit.icon,
                    value: batterySplit.value,
                    tint: batterySplit.tint
                )
                Divider()
                    .frame(height: 26)
                splitItem(
                    title: "系统直供",
                    icon: "laptopcomputer",
                    value: snapshot.powerDisplayStatus.placeholder
                        ?? snapshot.directSupplyPowerW.map { String(format: "%.1f W", $0) } ?? "--",
                    tint: themeAccent
                )
                Divider()
                    .frame(height: 26)
                splitItem(
                    title: "适配器输出",
                    icon: "cable.connector",
                    value: snapshot.powerDisplayStatus.placeholder
                        ?? snapshot.adapterOutputPowerW.map { String(format: "%.1f W", $0) } ?? "--",
                    tint: .primary
                )
            }
        }
        .padding(.horizontal, DesignTokens.spacingM)
        .padding(.vertical, DashboardLayout.cardVerticalPadding)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
        .accessibilityElement(children: .combine)
    }

    /// 电池侧分配：充电显示充入功率；插电但连续确认电池仍在放电时显示放电功率，
    /// 避免把真实的电池放电误显示成「+0.0 W」。
    private var batterySplit: (title: String, icon: String, value: String, tint: Color) {
        if let placeholder = snapshot.powerDisplayStatus.placeholder {
            return ("给电池", "battery.100percent.bolt", placeholder, .secondary)
        }
        if snapshot.batteryDischargingWhilePlugged, let discharge = snapshot.batteryDischargePowerW {
            return ("电池放电", "battery.25percent", String(format: "-%.1f W", discharge), DesignTokens.statusRed)
        }
        if snapshot.state == .charging, let charging = snapshot.chargingPowerW {
            return ("给电池", "battery.100percent.bolt", String(format: "%+.1f W", charging), DesignTokens.statusGreen)
        }
        return ("给电池", "battery.100percent.bolt", "0.0 W", .secondary)
    }

    private func splitItem(title: String, icon: String, value: String, tint: Color) -> some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - KPI 卡片容器

struct KpiCard<Content: View>: View {
    let title: String
    let icon: String
    let verticalPadding: CGFloat
    let accessibilityChildren: AccessibilityChildBehavior
    let content: Content

    init(
        title: String,
        icon: String,
        verticalPadding: CGFloat = DashboardLayout.cardVerticalPadding,
        accessibilityChildren: AccessibilityChildBehavior = .combine,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.verticalPadding = verticalPadding
        self.accessibilityChildren = accessibilityChildren
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, DesignTokens.spacingM)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
        // 默认整张卡片合并播报；含独立按钮时保留按钮焦点。
        .accessibilityElement(children: accessibilityChildren)
    }
}

struct SlimBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: geometry.size.width * max(0, min(progress, 1)))
            }
        }
        .frame(height: 4)
        // 纯装饰进度条：数值已由卡片文本播报。
        .accessibilityHidden(true)
    }
}

// MARK: - 电量

struct BatteryPercentCard: View {
    let snapshot: BatterySnapshot
    @Environment(\.themeAccent) private var themeAccent

    private var accent: Color { BatteryStyling.tint(for: snapshot, accent: themeAccent) }

    var body: some View {
        KpiCard(title: "电量", icon: "battery.75percent") {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(percentText)
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                if snapshot.state != .unknown {
                    Text("%")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            SlimBar(progress: snapshot.percent / 100, tint: accent)
            Text(remainingText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 未检测到电池时显示 "--"，避免出现误导性的 "0%"。
    private var percentText: String {
        snapshot.state == .unknown ? "--" : "\(Int(snapshot.percent.rounded()))"
    }

    private var remainingText: String {
        guard let remaining = snapshot.displayTimeRemaining else { return "——" }
        if snapshot.displayState == .charging {
            return "充满还需 " + BatteryFormatters.timeRemaining(remaining)
        }
        return "剩余 " + BatteryFormatters.timeRemaining(remaining)
    }
}

// MARK: - 实时功率

struct PowerKpiCard: View {
    let snapshot: BatterySnapshot
    @Environment(\.themeAccent) private var themeAccent

    private var isOnAdapter: Bool {
        snapshot.displayState == .charging || snapshot.displayState == .pluggedIn
    }

    private var displayPower: Double {
        snapshot.displayPower
    }

    private var accent: Color {
        isOnAdapter ? themeAccent : BatteryStyling.tint(for: snapshot, accent: themeAccent)
    }

    var body: some View {
        KpiCard(title: "实时功率", icon: directionIcon) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(valueText)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                if snapshot.displayState != .unknown, snapshot.powerDisplayStatus == .ready {
                    Text("W")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(directionText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(accent)
        }
    }

    private var directionIcon: String {
        switch snapshot.displayState {
        case .charging, .pluggedIn: return "cpu"
        case .discharging: return "arrow.up.right"
        default: return "waveform.path.ecg"
        }
    }

    private var directionText: String {
        if let message = snapshot.powerDisplayStatus.message {
            return "\(snapshot.displayState.rawValue) · \(message)"
        }
        switch snapshot.displayState {
        case .charging, .pluggedIn: return "适配器供电 · 适配器输出功率"
        case .discharging: return "电池供电 · 能量流出电池"
        default: return "暂无数据"
        }
    }

    private var valueText: String {
        if let placeholder = snapshot.powerDisplayStatus.placeholder { return placeholder }
        // 适配器供电时显示无符号适配器输出功率；电池供电时保留正负号（充电+/放电-）。
        // 未检测到电池时无数据，显示 "--"。
        guard snapshot.state != .unknown else { return "--" }
        return isOnAdapter
            ? String(format: "%.1f", displayPower)
            : String(format: "%+.1f", displayPower)
    }
}

// MARK: - 循环次数

struct CycleKpiCard: View {
    let snapshot: BatterySnapshot
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        KpiCard(title: "循环次数", icon: "repeat") {
            Text("\(snapshot.cycleCount)")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            SlimBar(
                progress: min(Double(snapshot.cycleCount) / 1000, 1),
                tint: themeAccent
            )
            Text("设计寿命 1000 次")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 电池健康

struct HealthKpiCard: View {
    let snapshot: BatterySnapshot

    private var healthTint: Color {
        BatteryStyling.healthTint(for: snapshot.healthPercent)
    }

    var body: some View {
        KpiCard(title: "电池健康", icon: "heart.text.square") {
            Text(snapshot.healthText)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(healthTint)
            SlimBar(
                progress: (snapshot.healthPercent ?? 0) / 100,
                tint: healthTint
            )
            Text(capacityText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var capacityText: String {
        guard snapshot.designCapacityMAh > 0 else { return "——" }
        let full = snapshot.maxCapacityMAh > 0 ? Int(snapshot.maxCapacityMAh) : nil
        if let full {
            return "满充 \(full) / 设计 \(Int(snapshot.designCapacityMAh)) mAh"
        }
        return "设计 \(Int(snapshot.designCapacityMAh)) mAh"
    }
}

// MARK: - 近期功率与今日耗电（按时间范围分卡展示）

struct PowerTrendCard: View {
    let samples: [PowerSample]
    let snapshot: BatterySnapshot
    let todayEnergy: TodayEnergyDisplay
    @Environment(\.themeAccent) private var themeAccent
    @State private var showingEnergyDetails = false

    var body: some View {
        // 每帧只算一次，平均值与峰值共用同一个 120 秒窗口。
        let statistics = PowerTrendStatistics(samples: samples, now: snapshot.timestamp)

        HStack(alignment: .top, spacing: DesignTokens.spacingM) {
            recentPowerCard(statistics)
            todayEnergyCard
        }
    }

    private func recentPowerCard(_ statistics: PowerTrendStatistics) -> some View {
        KpiCard(title: "近 2 分钟功率", icon: "chart.line.uptrend.xyaxis") {
            HStack(spacing: DesignTokens.spacingS) {
                statistic(value: statistics.averagePower, caption: "平均", tint: themeAccent)
                statistic(value: statistics.peakPower, caption: "峰值", tint: .primary)
            }
            Text(powerCaption(statistics))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .help("最近 2 分钟已记录的耗电功率，W 表示耗电的快慢。电池供电时统计电池放电，接通电源时统计适配器输入；切换电源时窗口内可能包含两种记录。")
    }

    private func statistic(value: Double?, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if value != nil {
                    Text("W")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var todayEnergyCard: some View {
        KpiCard(title: "今日累计耗电", icon: "bolt.circle", accessibilityChildren: .contain) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(todayEnergy.energyKWh.map { String(format: "%.3f", $0) } ?? "--")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if todayEnergy.energyKWh != nil {
                        Text("kWh")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

                energyInfoButton
            }
            .padding(.top, DesignTokens.spacingS)
        }
    }

    private var energyInfoButton: some View {
        Button {
            showingEnergyDetails.toggle()
        } label: {
            Image(systemName: todayEnergy.needsAttention ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(energyStatusTint)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(todayEnergy.warningText ?? "查看耗电说明")
        .accessibilityLabel("今日耗电：\(todayEnergy.qualityLabel)")
        .accessibilityHint("查看详细说明")
        .popover(isPresented: $showingEnergyDetails, arrowEdge: .bottom) {
            energyDetails
        }
    }

    private var energyStatusTint: Color {
        todayEnergy.needsAttention ? DesignTokens.statusAmber : .secondary
    }

    private var energyDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(todayEnergy.warningText == nil ? "耗电说明" : todayEnergy.qualityLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(energyStatusTint)
            Text(todayEnergy.warningText ?? (todayEnergy.energyKWh == nil
                ? "今日暂无有效耗电记录，可在历史页查看记录状态。"
                : "今天 00:00 起累计的已记录耗电，1 kWh = 1 度电。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(DesignTokens.spacingM)
        .frame(width: 240, alignment: .leading)
    }

    private func powerCaption(_ statistics: PowerTrendStatistics) -> String {
        if let message = snapshot.powerDisplayStatus.message {
            return statistics.averagePower == nil ? message : "\(message) · 近期记录"
        }
        return statistics.averagePower == nil ? "等待有效功率读数" : "数值越高，耗电越快"
    }
}

