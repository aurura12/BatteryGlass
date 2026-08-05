import SwiftUI

struct MenuBarLabel: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        StatusBarIconView(snapshot: monitor.snapshot)
        .help("BatteryGlass · \(monitor.snapshot.percentText)")
        .accessibilityLabel("BatteryGlass，电池电量 \(monitor.snapshot.percentText)")
        .onReceive(NotificationCenter.default.publisher(for: .requestDashboardWindow)) { _ in
            openWindow(id: "dashboard")
        }
        .onAppear {
            NotificationCenter.default.post(
                name: .desktopWidgetVisibilityChanged,
                object: nil,
                userInfo: ["enabled": settings.desktopWidgetEnabled]
            )
        }
        .onChange(of: settings.desktopWidgetEnabled) { _, enabled in
            NotificationCenter.default.post(
                name: .desktopWidgetVisibilityChanged,
                object: nil,
                userInfo: ["enabled": enabled]
            )
        }
    }
}

/// 自定义状态栏图标：渐变圆角徽章 + 闪电，与系统电池图标明显区分。
struct StatusBarIconView: View {
    let snapshot: BatterySnapshot

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: BatteryStyling.gradient(for: snapshot),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .strokeBorder(.white.opacity(0.4), lineWidth: 0.5)
                )
                .shadow(color: BatteryStyling.tint(for: snapshot).opacity(0.5), radius: 2, y: 1)

            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 15, height: 15)
    }
}
