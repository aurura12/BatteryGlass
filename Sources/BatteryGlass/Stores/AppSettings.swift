import Foundation
import Observation

/// 菜单栏图标旁显示的内容。
enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case none
    case percent
    case timeRemaining

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "不显示"
        case .percent: return "百分比"
        case .timeRemaining: return "剩余时间"
        }
    }
}

/// 桌面小组件尺寸样式。
enum DesktopWidgetStyle: String, CaseIterable, Identifiable {
    case compact
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "紧凑"
        case .large: return "大尺寸"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    var lowBatteryNotificationsEnabled: Bool {
        didSet { defaults.set(lowBatteryNotificationsEnabled, forKey: Self.notificationsEnabledKey) }
    }

    var lowBatteryThreshold: Double {
        didSet { defaults.set(lowBatteryThreshold, forKey: Self.thresholdKey) }
    }

    var animationIntensity: Double {
        didSet { defaults.set(animationIntensity, forKey: Self.intensityKey) }
    }

    var animationSpeed: Double {
        didSet { defaults.set(animationSpeed, forKey: Self.speedKey) }
    }

    var recordHistory: Bool {
        didSet { defaults.set(recordHistory, forKey: Self.recordHistoryKey) }
    }

    var powerDiagnosticsLoggingEnabled: Bool {
        didSet { defaults.set(powerDiagnosticsLoggingEnabled, forKey: Self.powerDiagnosticsLoggingKey) }
    }

    var desktopWidgetEnabled: Bool {
        didSet { defaults.set(desktopWidgetEnabled, forKey: Self.desktopWidgetKey) }
    }

    var launchAtLoginEnabled: Bool {
        didSet { defaults.set(launchAtLoginEnabled, forKey: Self.launchAtLoginKey) }
    }

    var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { defaults.set(menuBarDisplayMode.rawValue, forKey: Self.menuBarDisplayModeKey) }
    }

    var showMainWindowAtLaunch: Bool {
        didSet { defaults.set(showMainWindowAtLaunch, forKey: Self.showMainWindowAtLaunchKey) }
    }

    var adapterChangeNotificationsEnabled: Bool {
        didSet { defaults.set(adapterChangeNotificationsEnabled, forKey: Self.adapterChangeNotificationsKey) }
    }

    var desktopWidgetStyle: DesktopWidgetStyle {
        didSet { defaults.set(desktopWidgetStyle.rawValue, forKey: Self.desktopWidgetStyleKey) }
    }

    var desktopWidgetFrameString: String {
        didSet { defaults.set(desktopWidgetFrameString, forKey: Self.desktopWidgetFrameKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lowBatteryNotificationsEnabled = defaults.bool(forKey: Self.notificationsEnabledKey)

        if defaults.object(forKey: Self.thresholdKey) != nil {
            // 钳制到设置滑块的合法范围（10–50），避免存储值越界导致低电量误判。
            lowBatteryThreshold = min(max(defaults.double(forKey: Self.thresholdKey), 10), 50)
        } else {
            lowBatteryThreshold = 20
        }
        animationIntensity = defaults.object(forKey: Self.intensityKey) as? Double ?? 0.75
        animationSpeed = defaults.object(forKey: Self.speedKey) as? Double ?? 1.0
        recordHistory = defaults.object(forKey: Self.recordHistoryKey) as? Bool ?? true
        powerDiagnosticsLoggingEnabled = defaults.object(forKey: Self.powerDiagnosticsLoggingKey) as? Bool ?? false
        desktopWidgetEnabled = defaults.object(forKey: Self.desktopWidgetKey) as? Bool ?? true
        desktopWidgetFrameString = defaults.string(forKey: Self.desktopWidgetFrameKey) ?? ""
        launchAtLoginEnabled = defaults.object(forKey: Self.launchAtLoginKey) as? Bool ?? false
        menuBarDisplayMode = MenuBarDisplayMode(rawValue: defaults.string(forKey: Self.menuBarDisplayModeKey) ?? "") ?? .none
        showMainWindowAtLaunch = defaults.object(forKey: Self.showMainWindowAtLaunchKey) as? Bool ?? true
        adapterChangeNotificationsEnabled = defaults.object(forKey: Self.adapterChangeNotificationsKey) as? Bool ?? false
        desktopWidgetStyle = DesktopWidgetStyle(rawValue: defaults.string(forKey: Self.desktopWidgetStyleKey) ?? "") ?? .compact
    }

    /// 供 AppDelegate 在启动流程中直接读取（不依赖注入实例）。
    static func shouldShowMainWindowAtLaunch(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showMainWindowAtLaunchKey) as? Bool ?? true
    }

    private static let notificationsEnabledKey = "notificationsEnabled"
    private static let thresholdKey = "lowBatteryThreshold"
    private static let intensityKey = "animationIntensity"
    private static let speedKey = "animationSpeed"
    private static let recordHistoryKey = "recordHistory"
    private static let powerDiagnosticsLoggingKey = "powerDiagnosticsLoggingEnabled"
    private static let desktopWidgetKey = "desktopWidgetEnabled"
    private static let desktopWidgetFrameKey = "desktopWidgetFrameString"
    private static let launchAtLoginKey = "launchAtLoginEnabled"
    private static let menuBarDisplayModeKey = "menuBarDisplayMode"
    private static let showMainWindowAtLaunchKey = "showMainWindowAtLaunch"
    private static let adapterChangeNotificationsKey = "adapterChangeNotificationsEnabled"
    private static let desktopWidgetStyleKey = "desktopWidgetStyle"
}
