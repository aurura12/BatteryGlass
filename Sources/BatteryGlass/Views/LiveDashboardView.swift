import SwiftUI

struct LiveDashboardView: View {
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        VStack(spacing: DesignTokens.spacingM) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: DesignTokens.spacingM),
                    GridItem(.flexible(), spacing: DesignTokens.spacingM)
                ],
                spacing: DesignTokens.spacingM
            ) {
                BatteryPercentCard(snapshot: monitor.snapshot)
                PowerKpiCard(snapshot: monitor.snapshot)
                CycleKpiCard(snapshot: monitor.snapshot)
                HealthKpiCard(snapshot: monitor.snapshot)
            }

            if monitor.snapshot.adapterConnected, monitor.snapshot.state != .discharging {
                AdapterSplitCard(snapshot: monitor.snapshot)
            }

            PowerTrendCard(
                samples: monitor.recentPower,
                snapshot: monitor.snapshot
            )

            MetricsGrid(snapshot: monitor.snapshot)
        }
    }
}

// MARK: - 电源分配（充电 / 直供 / 适配器合计）

struct AdapterSplitCard: View {
    let snapshot: BatterySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            Label("电源分配", systemImage: "powerplug")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: DesignTokens.spacingM) {
                splitItem(
                    title: "给电池",
                    icon: "battery.100percent.bolt",
                    value: String(format: "%+.1f W", snapshot.chargingPowerW ?? 0),
                    tint: DesignTokens.statusGreen
                )
                Divider()
                    .frame(height: 26)
                splitItem(
                    title: "系统估算",
                    icon: "laptopcomputer",
                    value: snapshot.directSupplyPowerW.map { String(format: "%.1f W", $0) } ?? "--",
                    tint: DesignTokens.dataBlue
                )
                Divider()
                    .frame(height: 26)
                splitItem(
                    title: "适配器输出",
                    icon: "cable.connector",
                    value: snapshot.adapterOutputPowerW.map { String(format: "%.1f W", $0) } ?? "--",
                    tint: .primary
                )
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
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
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity, alignment: .topLeading)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
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
    }
}

// MARK: - 电量

struct BatteryPercentCard: View {
    let snapshot: BatterySnapshot

    private var accent: Color { BatteryStyling.tint(for: snapshot) }

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
        guard let remaining = snapshot.timeRemaining else { return "——" }
        if snapshot.state == .charging {
            return "充满还需 " + BatteryFormatters.timeRemaining(remaining)
        }
        return "剩余 " + BatteryFormatters.timeRemaining(remaining)
    }
}

// MARK: - 实时功率

struct PowerKpiCard: View {
    let snapshot: BatterySnapshot

    private var isOnAdapter: Bool {
        snapshot.state == .charging || snapshot.state == .pluggedIn
    }

    private var displayPower: Double {
        snapshot.displayPower
    }

    private var accent: Color {
        isOnAdapter ? DesignTokens.dataBlue : BatteryStyling.tint(for: snapshot)
    }

    var body: some View {
        KpiCard(title: "实时功率", icon: directionIcon) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(valueText)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                if snapshot.state != .unknown {
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
        switch snapshot.state {
        case .charging, .pluggedIn: return "cpu"
        case .discharging: return "arrow.up.right"
        default: return "waveform.path.ecg"
        }
    }

    private var directionText: String {
        switch snapshot.state {
        case .charging, .pluggedIn: return "适配器供电 · 系统功率"
        case .discharging: return "电池供电 · 能量流出电池"
        default: return "暂无数据"
        }
    }

    private var valueText: String {
        // 适配器供电时显示无符号系统功率；电池供电时保留正负号（充电+/放电-）。
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

    var body: some View {
        KpiCard(title: "循环次数", icon: "repeat") {
            Text("\(snapshot.cycleCount)")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            SlimBar(
                progress: min(Double(snapshot.cycleCount) / 1000, 1),
                tint: DesignTokens.dataBlue
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

// MARK: - 功率趋势（数值版，与其他 KPI 卡片同模块）

struct PowerTrendCard: View {
    let samples: [PowerSample]
    let snapshot: BatterySnapshot

    private var accent: Color { BatteryStyling.tint(for: snapshot) }

    var body: some View {
        KpiCard(title: "功率趋势", icon: "chart.line.uptrend.xyaxis") {
            HStack(spacing: DesignTokens.spacingM) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(peakText)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                    Text("2 分钟峰值")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(averageText)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("2 分钟平均")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Text(directionCaption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(accent)
        }
    }

    private var windowSamples: [PowerSample] {
        Array(samples.suffix(240))
    }

    private var hasSamples: Bool {
        !windowSamples.isEmpty
    }

    private var peakPower: Double {
        windowSamples.max(by: { abs($0.power) < abs($1.power) })?.power ?? 0
    }

    private var averagePower: Double {
        guard !windowSamples.isEmpty else { return 0 }
        return windowSamples.map(\.power).reduce(0, +) / Double(windowSamples.count)
    }

    /// 采样功率恒为正（消耗功率），无数据时显示 "--" 而非误导性的 "+0.0 W"。
    private var peakText: String {
        guard hasSamples else { return "--" }
        return String(format: "%.1f W", peakPower)
    }

    private var averageText: String {
        guard hasSamples else { return "--" }
        return String(format: "%.1f W", averagePower)
    }

    private var directionCaption: String {
        if !hasSamples { return "暂无有效功率数据" }
        switch snapshot.state {
        case .charging: return "适配器供电 · 系统总功率"
        case .discharging: return "电池供电 · 系统总功率"
        case .pluggedIn: return "适配器供电 · 系统总功率"
        case .unknown: return "暂无有效功率数据"
        }
    }
}
