import SwiftUI

struct MenuBarLabel: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 3) {
            StatusBarIconView(snapshot: monitor.snapshot)
            if monitor.snapshot.state == .charging {
                // 只有 battery.100percent.bolt 带闪电变体，其余电量档没有；
                // 因此电量图标按真实电量显示，充电状态另用一个小闪电标识，
                // 避免"充电中恒显满电"且不违反"状态不只靠颜色传达"。
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(BatteryStyling.tint(for: monitor.snapshot))
            }
            if settings.menuBarDisplayMode != .none {
                Text(labelText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(BatteryStyling.tint(for: monitor.snapshot))
                    .fixedSize()
            }
        }
        .help("BatteryGlass · \(monitor.snapshot.percentText)")
        .accessibilityLabel("BatteryGlass，电池电量 \(monitor.snapshot.percentText)")
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

    /// 菜单栏图标旁的文字：百分比或剩余时间；未检测到电池时显示 "--"。
    private var labelText: String {
        switch settings.menuBarDisplayMode {
        case .none:
            return ""
        case .percent:
            return monitor.snapshot.state == .unknown ? "--" : monitor.snapshot.percentText
        case .timeRemaining:
            return BatteryFormatters.menuBarTimeRemaining(monitor.snapshot.timeRemaining)
        }
    }
}

/// 菜单栏使用系统电池符号，避免 MenuBarExtra 对自绘 Shape 的渲染差异。
enum MenuBarBatterySymbol {
    static func name(for snapshot: BatterySnapshot) -> String {
        if snapshot.state == .unknown {
            return "battery.0percent"
        }

        switch snapshot.percent {
        case 87.5...:
            return "battery.100percent"
        case 62.5..<87.5:
            return "battery.75percent"
        case 37.5..<62.5:
            return "battery.50percent"
        case 12.5..<37.5:
            return "battery.25percent"
        default:
            return "battery.0percent"
        }
    }
}

struct StatusBarIconView: View {
    let snapshot: BatterySnapshot

    var body: some View {
        Image(systemName: MenuBarBatterySymbol.name(for: snapshot))
            .font(.system(size: 15, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(BatteryStyling.tint(for: snapshot))
        .frame(width: 17, height: 15)
    }
}
