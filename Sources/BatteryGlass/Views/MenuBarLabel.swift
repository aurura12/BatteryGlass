import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 3) {
            StatusBarIconView(snapshot: monitor.snapshot)
            if settings.menuBarDisplayMode != .none {
                Text(labelText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(BatteryStyling.tint(for: monitor.snapshot))
                    .fixedSize()
            }
        }
        .help("BatteryGlass · \(monitor.snapshot.percentText)")
        // 合并为单一无障碍元素：显式播报状态（含"正在充电"），
        // 不让新增的闪电图标对 VoiceOver 不可见。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MenuBarAccessibility.label(for: monitor.snapshot))
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

/// 菜单栏 VoiceOver 文案（纯函数，便于单元测试）。
///
/// 显式包含供电状态，避免"充电中"只靠颜色/图标传达。
enum MenuBarAccessibility {
    static func label(for snapshot: BatterySnapshot) -> String {
        let percent = snapshot.percentText
        switch snapshot.state {
        case .charging:
            return "BatteryGlass，电池电量 \(percent)，正在充电"
        case .discharging:
            return "BatteryGlass，电池电量 \(percent)，电池供电"
        case .pluggedIn:
            return "BatteryGlass，电池电量 \(percent)，已接通电源"
        case .unknown:
            return "BatteryGlass，未检测到电池"
        }
    }
}

enum MenuBarPowerIndicator {
    static let batteryIconWidth: CGFloat = 23

    static func shouldShow(for snapshot: BatterySnapshot) -> Bool {
        badgeSymbolName(for: snapshot) != nil
    }

    static func badgeSymbolName(for snapshot: BatterySnapshot) -> String? {
        snapshot.adapterConnected ? "bolt.fill" : nil
    }

    static func iconWidth(for snapshot: BatterySnapshot) -> CGFloat {
        batteryIconWidth
    }
}

/// 菜单栏电池主体的连续填充比例。
enum MenuBarBatteryFill {
    static func fraction(for snapshot: BatterySnapshot) -> CGFloat {
        guard snapshot.state != .unknown, snapshot.percent.isFinite else {
            return 0
        }

        return CGFloat(min(max(snapshot.percent, 0), 100) / 100)
    }
}

/// 把菜单栏图标合成为一张 NSImage，避免 MenuBarExtra 丢弃多层 SwiftUI 子视图。
/// 使用动态系统颜色，让内部闪电与电池填充形成对比，同时适配浅色/深色菜单栏。
enum MenuBarIconRenderer {
    private static let batteryWidth = MenuBarPowerIndicator.batteryIconWidth
    private static let iconHeight: CGFloat = 18

    static func image(for snapshot: BatterySnapshot) -> NSImage {
        let width = MenuBarPowerIndicator.iconWidth(for: snapshot)
        let image = NSImage(size: NSSize(width: width, height: iconHeight))
        image.isTemplate = false
        image.lockFocus()
        defer { image.unlockFocus() }

        let batteryBody = NSRect(x: 1, y: 3, width: 19, height: 12)
        let batteryTerminal = NSRect(x: 20, y: 6.5, width: 2.5, height: 5)
        let batteryInterior = NSRect(
            x: 3,
            y: 4.5,
            width: 15.5,
            height: 9
        )
        let fillFraction = MenuBarBatteryFill.fraction(for: snapshot)
        NSGraphicsContext.current?.saveGraphicsState()
        let interiorPath = NSBezierPath(
            roundedRect: batteryInterior,
            xRadius: 1.5,
            yRadius: 1.5
        )
        interiorPath.addClip()
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        batteryInterior.fill()
        if fillFraction > 0 {
            NSColor.labelColor.setFill()
            NSRect(
                x: batteryInterior.minX,
                y: batteryInterior.minY,
                width: batteryInterior.width * fillFraction,
                height: batteryInterior.height
            ).fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.labelColor.setFill()
        NSBezierPath(
            roundedRect: batteryTerminal,
            xRadius: 1,
            yRadius: 1
        ).fill()
        NSColor.labelColor.setStroke()
        let bodyPath = NSBezierPath(
            roundedRect: batteryBody,
            xRadius: 3,
            yRadius: 3
        )
        bodyPath.lineWidth = 2
        bodyPath.stroke()

        if let indicatorName = MenuBarPowerIndicator.badgeSymbolName(for: snapshot) {
            let indicatorOutlineConfiguration = NSImage.SymbolConfiguration(
                pointSize: 10,
                weight: .bold
            ).applying(
                NSImage.SymbolConfiguration(paletteColors: [.labelColor])
            )
            let indicatorFillConfiguration = NSImage.SymbolConfiguration(
                pointSize: 9,
                weight: .bold
            ).applying(
                NSImage.SymbolConfiguration(paletteColors: [.controlBackgroundColor])
            )
            let indicatorOutline = NSImage(
                systemSymbolName: indicatorName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(indicatorOutlineConfiguration)
            indicatorOutline?.draw(
                // 闪电位于电池主体内部；外轮廓和内芯形成稳定对比，
                // 低电量的空白区域与满电的填充区域都能看见。
                in: NSRect(x: 6, y: 1, width: 9, height: 16),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            let indicatorFill = NSImage(
                systemSymbolName: indicatorName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(indicatorFillConfiguration)
            indicatorFill?.draw(
                in: NSRect(x: 6.5, y: 1.5, width: 8, height: 15),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }

        return image
    }
}

struct StatusBarIconView: View {
    let snapshot: BatterySnapshot

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.image(for: snapshot))
            .renderingMode(.original)
            .frame(width: MenuBarPowerIndicator.iconWidth(for: snapshot), height: 18, alignment: .leading)
    }
}
