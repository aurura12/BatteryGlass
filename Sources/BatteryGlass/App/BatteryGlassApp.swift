import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻应用：不占用 Dock。
        NSApp.setActivationPolicy(.accessory)

        // 启动时隐藏主窗口：仅保留菜单栏图标与桌面小组件（设置里可关闭此行为）。
        guard !AppSettings.shouldShowMainWindowAtLaunch() else { return }
        DispatchQueue.main.async {
            // 主窗口是普通 NSWindow；菜单栏弹窗是 NSPanel，不应被关闭。
            NSApp.windows
                .filter { !($0 is NSPanel) && $0.canBecomeMain }
                .forEach { $0.close() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // 用户点击 Dock 图标时，若主窗口已关闭则重新打开。
            NotificationCenter.default.post(name: .requestDashboardWindow, object: nil)
        }
        return true
    }
}

@main
struct BatteryGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let settings: AppSettings
    private let monitor: BatteryMonitor
    private let history: BatteryHistoryStore
    private let desktopWidget: DesktopWidgetController

    init() {
        let settings = AppSettings()
        // 用系统实际登录项状态同步设置，保证设置页开关与系统状态一致；
        // 未从 .app 包运行时无法查询，保留存储值。
        if let enabled = LoginItemService.systemLaunchAtLoginEnabled() {
            settings.launchAtLoginEnabled = enabled
        }
        let monitor = BatteryMonitor(settings: settings)
        let history = BatteryHistoryStore(settings: settings)
        let desktopWidget = DesktopWidgetController(monitor: monitor, settings: settings)
        self.settings = settings
        self.monitor = monitor
        self.history = history
        self.desktopWidget = desktopWidget
    }

    var body: some Scene {
        WindowGroup("BatteryGlass", id: "dashboard") {
            DashboardView()
                .environment(monitor)
                .environment(history)
                .environment(settings)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 400, height: 700)
        .windowResizability(.contentSize)

        MenuBarExtra {
            DashboardView()
                .environment(monitor)
                .environment(history)
                .environment(settings)
        } label: {
            MenuBarLabel()
                .environment(monitor)
                .environment(settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(history)
                .environment(settings)
        }
    }
}
