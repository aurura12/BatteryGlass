import Combine
import SwiftUI

final class HoverModel: ObservableObject {
    @Published var hovering = false
}

/// 桌面小组件：紧凑或大尺寸的电池状态卡片，始终悬浮在桌面层级。
struct DesktopWidgetView: View {
    static func preferredSize(for style: DesktopWidgetStyle) -> CGSize {
        switch style {
        case .compact: return CGSize(width: 236, height: 132)
        case .large: return CGSize(width: 264, height: 208)
        }
    }

    @Environment(BatteryMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    var onClose: (() -> Void)? = nil
    @StateObject private var hover = HoverModel()

    private var snapshot: BatterySnapshot { monitor.snapshot }
    private var tint: Color { BatteryStyling.tint(for: snapshot) }
    private var style: DesktopWidgetStyle { settings.desktopWidgetStyle }
    private var preferredSize: CGSize { Self.preferredSize(for: style) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
                HStack(spacing: DesignTokens.spacingS) {
                    badge
                    VStack(alignment: .leading, spacing: 1) {
                        Text("BatteryGlass")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                        Text(statusText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(percentText)
                        .font(.system(size: style == .large ? 40 : 34, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    if snapshot.state != .unknown {
                        Text("%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(snapshot.displayPowerText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }

                SlimBar(progress: snapshot.percent / 100, tint: tint)

                if style == .large {
                    largeMetrics
                }

                Text(detailText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(14)

            if hover.hovering {
                Button {
                    onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("关闭小组件")
                .transition(.opacity)
            }
        }
        .frame(width: preferredSize.width, height: preferredSize.height)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.14), tint.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
        .onHover { hover.hovering = $0 }
    }

    /// 大尺寸小组件额外展示的指标网格。
    private var largeMetrics: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: DesignTokens.spacingM),
                GridItem(.flexible(), spacing: DesignTokens.spacingM)
            ],
            spacing: 8
        ) {
            metric(icon: "thermometer", title: "温度", value: BatteryFormatters.temperature(snapshot.temperatureCelsius))
            metric(icon: "bolt", title: "电压", value: BatteryFormatters.voltage(snapshot.voltage))
            metric(icon: "heart.text.square", title: "健康度", value: snapshot.healthText)
            metric(icon: "repeat", title: "循环", value: "\(snapshot.cycleCount)")
        }
    }

    private func metric(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: BatteryStyling.gradient(for: snapshot),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
    }

    /// 未检测到电池时显示 "--"，避免出现误导性的 "0%"。
    private var percentText: String {
        snapshot.state == .unknown ? "--" : "\(Int(snapshot.percent.rounded()))"
    }

    private var statusText: String {
        switch snapshot.state {
        case .charging: return "充电中"
        case .discharging: return "电池供电"
        case .pluggedIn: return "已接通电源"
        case .unknown: return "未知状态"
        }
    }

    private var detailText: String {
        if let remaining = snapshot.timeRemaining {
            return "剩余 " + BatteryFormatters.timeRemaining(remaining)
        }
        if snapshot.adapterConnected, let watts = snapshot.adapterWatts {
            return String(format: "适配器 %.0f W", watts)
        }
        return "BatteryGlass 实时监测中"
    }
}
