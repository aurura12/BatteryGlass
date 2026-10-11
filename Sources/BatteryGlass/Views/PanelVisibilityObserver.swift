import AppKit
import SwiftUI

/// 上报承载它的 `NSWindow` 是否真正可见。
///
/// `MenuBarExtra(.window)` 的面板关闭时只是把窗口 order out，SwiftUI 的
/// 内容视图仍然存活，其中的持续动画（`TimelineView(.animation)`）会继续让
/// 视图图失效——布局不受窗口可见性门控，于是已离屏的窗口被反复布局，白白
/// 占用 CPU。把根视图挂上这个观察器，即可在面板关闭时暂停这类动画。
struct PanelVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowVisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowVisibilityView)?.onChange = onChange
    }
}

/// 零尺寸、不参与命中测试；仅监听自身窗口的显示状态并在变化时回调。
private final class WindowVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var lastValue: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 选择器式监听会在 dealloc 时自动移除；换窗口时先清掉旧窗口的注册。
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            report(false)
            return
        }
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didExposeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowStateChanged),
                name: name,
                object: window
            )
        }
        evaluate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func windowStateChanged(_ notification: Notification) {
        evaluate()
    }

    private func evaluate() {
        guard let window else {
            report(false)
            return
        }
        report(window.isVisible && window.occlusionState.contains(.visible))
    }

    private func report(_ visible: Bool) {
        guard lastValue != visible else { return }
        lastValue = visible
        onChange?(visible)
    }
}
