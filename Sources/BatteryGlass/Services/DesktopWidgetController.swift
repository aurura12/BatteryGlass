import AppKit
import CoreGraphics
import SwiftUI

/// 桌面小组件窗口：borderless、透明、非激活，位于桌面图标层级之上、普通窗口之下。
@MainActor
final class DesktopWidgetController: NSObject, NSWindowDelegate {
    private let monitor: BatteryMonitor
    private let settings: AppSettings
    private var window: NSWindow?
    /// 只在主线程增删；`deinit` 是 nonisolated，用 `nonisolated(unsafe)` 允许销毁时移除。
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    /// 拖动期间的窗口位置合并写盘，避免每个拖动事件都同步写一次 UserDefaults。
    private nonisolated(unsafe) var frameSaveTimer: Timer?
    private var pendingFrame: NSRect?

    init(monitor: BatteryMonitor, settings: AppSettings) {
        self.monitor = monitor
        self.settings = settings
        super.init()

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .desktopWidgetVisibilityChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let enabled = notification.userInfo?["enabled"] as? Bool ?? false
                // 观察者注册在 .main 队列，回调本就在主线程；用 assumeIsolated 同步执行，
                // 避免 Task 跳转让 setVisible 与同一轮里的其他调用失去顺序保证。
                MainActor.assumeIsolated {
                    self?.setVisible(enabled)
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .resetDesktopWidgetPosition,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resetPosition()
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .desktopWidgetStyleChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyStyle()
                }
            }
        )
        // 分辨率/显示器配置变化后，窗口可能落在屏幕外，需要拉回可见区。
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleScreenParametersChange()
                }
            }
        )
    }

    deinit {
        frameSaveTimer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setVisible(_ visible: Bool) {
        guard visible else {
            window?.orderOut(nil)
            monitor.setDesktopWidgetVisible(false)
            return
        }
        if window == nil {
            createWindow()
        }
        window?.orderFrontRegardless()
        // 先按可见上报，等窗口服务器给出真实的遮挡状态再修正（见 windowDidChangeOcclusionState）。
        // 被普通窗口完全盖住时不必每秒重绘毛玻璃卡片。
        monitor.setDesktopWidgetVisible(true)
    }

    func resetPosition() {
        settings.desktopWidgetFrameString = ""
        guard let window else { return }
        window.setFrame(defaultFrame(), display: true)
    }

    private func createWindow() {
        let view = DesktopWidgetView { [weak self] in
            guard let self else { return }
            self.settings.desktopWidgetEnabled = false
            self.setVisible(false)
        }
        .environment(monitor)
        .environment(settings)

        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        // 关闭窗口级矩形阴影，改用 SwiftUI 视图的圆角阴影，避免出现矩形边框。
        window.hasShadow = false
        // 桌面图标层级 = desktopWindow + 20，小组件再高 1 层，位于图标之上、普通窗口之下。
        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 21
        )
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hostingView
        window.setContentSize(DesktopWidgetView.preferredSize(for: settings.desktopWidgetStyle))
        window.setFrame(restoredFrame() ?? defaultFrame(), display: true)
        self.window = window
    }

    /// 跟随设置中的尺寸样式调整窗口大小（保持右上角锚点不变）。
    private func applyStyle() {
        guard let window else { return }
        let size = DesktopWidgetView.preferredSize(for: settings.desktopWidgetStyle)
        var frame = window.frame
        let topRight = CGPoint(x: frame.maxX, y: frame.maxY)
        frame.size = size
        frame.origin = CGPoint(x: topRight.x - size.width, y: topRight.y - size.height)
        window.setFrame(frame, display: true)
    }

    /// 小组件被其他窗口完全遮挡（或在别的 Space）时，`BatteryMonitor` 无需按秒发布：
    /// 窗口重新露出来时会再次收到该通知，随即恢复刷新。
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window,
              (notification.object as? NSWindow) === window else { return }
        monitor.setDesktopWidgetVisible(window.occlusionState.contains(.visible))
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        pendingFrame = window.frame
        frameSaveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameSaveTimer = timer
    }

    /// 把拖动过程中最后一次位置写入设置；拖动期间每个事件都写会是高频同步 IO。
    private func flushPendingFrame() {
        frameSaveTimer?.invalidate()
        frameSaveTimer = nil
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        settings.desktopWidgetFrameString = NSStringFromRect(frame)
    }

    /// 屏幕参数变化后，若窗口不再与任何屏幕的可见区相交，则移回默认位置。
    private func handleScreenParametersChange() {
        guard let window else { return }
        let frame = window.frame
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else {
            return
        }
        window.setFrame(defaultFrame(), display: true)
    }

    private func restoredFrame() -> NSRect? {
        DesktopWidgetFramePolicy.restoredFrame(
            saved: settings.desktopWidgetFrameString,
            screenFrames: NSScreen.screens.map(\.visibleFrame)
        )
    }

    private func defaultFrame() -> NSRect {
        let size = DesktopWidgetView.preferredSize(for: settings.desktopWidgetStyle)
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100, width: 236, height: 132)
        }
        return DesktopWidgetFramePolicy.defaultFrame(size: size, visibleFrame: screen.visibleFrame)
    }
}

/// 小组件窗口位置的纯决策，便于脱离 `NSScreen` 做单元测试。
enum DesktopWidgetFramePolicy {
    /// 已保存的位置只有在与任一屏幕可见区相交时才恢复；否则由调用方回退到默认位置。
    static func restoredFrame(saved: String, screenFrames: [NSRect]) -> NSRect? {
        guard !saved.isEmpty else { return nil }
        let rect = NSRectFromString(saved)
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard screenFrames.contains(where: { $0.intersects(rect) }) else { return nil }
        return rect
    }

    /// 主屏右上角默认位置：距右边 24pt、距顶 72pt。
    static func defaultFrame(size: CGSize, visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.maxX - size.width - 24,
            y: visibleFrame.maxY - size.height - 72,
            width: size.width,
            height: size.height
        )
    }
}
