import Combine
import SwiftUI

final class HoverModel: ObservableObject {
    @Published var hovering = false
}

/// 桌面小组件：紧凑的电池状态卡片，始终悬浮在桌面层级。
struct DesktopWidgetView: View {
    static let preferredSize = CGSize(width: 236, height: 132)

    @Environment(BatteryMonitor.self) private var monitor
    var onClose: (() -> Void)? = nil
    @StateObject private var hover = HoverModel()

    private var snapshot: BatterySnapshot { monitor.snapshot }
    private var tint: Color { BatteryStyling.tint(for: snapshot) }

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
                    Text("\(Int(snapshot.percent.rounded()))")
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Text("%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(snapshot.displayPowerText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }

                SlimBar(progress: snapshot.percent / 100, tint: tint)

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
        .frame(width: 236, height: 132)
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
