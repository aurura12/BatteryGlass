import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护：history.json 与 power-diagnostics.jsonl 均假定进程独占写入。
        // 若已有同 bundle 实例在运行（如 build_and_run.sh 每次 open -n、重复启动等），
        // 终止旧实例并等其 flush 落盘后由本实例接管，让“重新构建后启动”能切到最新代码；
        // 无法终止时则激活对方并退出自己，避免两个进程并发写同一持久化文件。
        guard enforceSingleInstance() else { return }

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

    /// 终止同 bundle 的其他运行实例，确保本进程成为唯一实例。
    /// 直接运行二进制（lldb/调试）时没有 bundle，用固定标识匹配正式应用。
    /// - Returns: `false` 表示本进程应退出，控制权已交给既有实例。
    private func enforceSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.batteryglass.app"
        let myPID = ProcessInfo.processInfo.processIdentifier

        // 依次终止所有既有实例；每个实例等待其走完 willTerminate（flush 落盘），
        // 避免交接期间两进程同时写同一文件。任一实例无法终止时，把工作交给它并退出自己。
        while let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != myPID && !$0.isTerminated }) {
            guard existing.terminate() else {
                existing.activate()
                NSApp.terminate(nil)
                return false
            }
            let deadline = Date(timeIntervalSinceNow: 3)
            while !existing.isTerminated && Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            guard existing.isTerminated else {
                existing.activate()
                NSApp.terminate(nil)
                return false
            }
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
