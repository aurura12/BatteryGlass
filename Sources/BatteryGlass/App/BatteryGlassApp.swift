import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻应用：不占用 Dock。
        NSApp.setActivationPolicy(.accessory)
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
