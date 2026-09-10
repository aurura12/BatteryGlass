import AppKit
import SwiftUI

/// 单实例保护：history.json 与 power-diagnostics.jsonl 均假定进程独占写入。
///
/// 必须在 `BatteryGlassApp.init` 构造核心对象**之前**执行：那些对象会启动 2Hz 定时器
/// 并触发首次写盘，若等到 `applicationDidFinishLaunching` 才接管旧实例，新旧进程会
/// 短暂并发写同一持久化文件。
///
/// 提取为独立工具，便于在 App 启动最早时机调用，并让失败分支不依赖 `NSApp`
/// （此时 AppKit 可能尚未就绪）——调用方用 `exit` 交出控制权。
enum AppInstanceGuard {
    /// 终止同 bundle 的其他运行实例。直接运行二进制（lldb/调试）时没有 bundle，
    /// 用固定标识匹配正式应用。
    /// - Returns: `false` 表示无法接管，调用方应退出让既有实例继续运行。
    static func enforceSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.batteryglass.app"
        let myPID = ProcessInfo.processInfo.processIdentifier

        // 依次终止所有既有实例；每个实例等待其走完 willTerminate（flush 落盘），
        // 避免交接期间两进程同时写同一文件。任一实例无法终止时，把工作交给它并返回 false。
        while let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != myPID && !$0.isTerminated }) {
            guard existing.terminate() else {
                existing.activate()
                return false
            }
            let deadline = Date(timeIntervalSinceNow: 3)
            while !existing.isTerminated && Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            guard existing.isTerminated else {
                existing.activate()
                return false
            }
        }
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏常驻应用：不占用 Dock。（单实例接管已在 App.init 之前完成）
        NSApp.setActivationPolicy(.accessory)
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
        // 必须最先接管实例：下方的 BatteryMonitor / BatteryHistoryStore 会立即启动
        // 定时器并写盘，晚于此检查会与新实例并发写同一持久化文件。
        guard AppInstanceGuard.enforceSingleInstance() else {
            exit(0)
        }

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
