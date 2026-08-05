import AppKit
import CoreGraphics
import SwiftUI

/// 桌面小组件窗口：borderless、透明、非激活，位于桌面图标层级之上、普通窗口之下。
@MainActor
final class DesktopWidgetController: NSObject, NSWindowDelegate {
    private let monitor: BatteryMonitor
    private let settings: AppSettings
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

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
                Task { @MainActor in
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
                Task { @MainActor in
                    self?.resetPosition()
                }
            }
        )
    }

    func setVisible(_ visible: Bool) {
        guard visible else {
            window?.orderOut(nil)
            return
        }
        if window == nil {
            createWindow()
        }
        window?.orderFrontRegardless()
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
        window.setContentSize(DesktopWidgetView.preferredSize)
        window.setFrame(restoredFrame() ?? defaultFrame(), display: true)
        self.window = window
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        settings.desktopWidgetFrameString = NSStringFromRect(window.frame)
    }

    private func restoredFrame() -> NSRect? {
        let saved = settings.desktopWidgetFrameString
        guard !saved.isEmpty else { return nil }
        let rect = NSRectFromString(saved)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) else {
            return nil
        }
        return rect
    }

    private func defaultFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100, width: 236, height: 132)
        }
        let visible = screen.visibleFrame
        let size = DesktopWidgetView.preferredSize
        return NSRect(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 72,
            width: size.width,
            height: size.height
        )
    }
}
