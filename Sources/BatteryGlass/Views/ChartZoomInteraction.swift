import AppKit
import Charts
import SwiftUI

extension ChartProxy {
    /// `chartOverlay` 坐标系下的绘图区矩形。
    func overlayPlotRect(in geometry: GeometryProxy) -> CGRect {
        plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: geometry.size)
    }
}

/// 真实 AppKit 事件层，放在 `chartOverlay` 内容之上。
///
/// 为什么不用 SwiftUI 手势：`.chartOverlay` 里挂 `MagnifyGesture` 在 `MenuBarExtra`
/// 的面板窗口（非激活 NSPanel）中收不到捏合事件，而 `NSView.magnify(with:)` 走的是
/// 普通响应链，可靠得多；顺带用 `scrollWheel` 支持 ⌘+滚轮缩放与双指横扫平移。
///
/// 它同时接管悬停：作为真实 `NSView` 它是绘图区的命中目标，会挡住 SwiftUI 侧
/// `.onContinuousHover` 的触发，因此悬停位置也必须由它上报（`onHover`）。
///
/// 所有回调都是**增量**语义（本次事件相对上一次的增量），因此调用方直接在当前窗口
/// 上累加即可，不需要缓存手势起始状态。
struct ChartPlotEventCatcher: NSViewRepresentable {
    /// 缩放：`factor` 为本次事件的放大系数（>1 放大），`location` 为视图内坐标。
    let onZoom: (CGFloat, CGPoint) -> Void
    /// 平移：`deltaX` 为本次事件的水平位移（点，向右为正），`location` 为视图内坐标。
    let onPan: (CGFloat, CGPoint) -> Void
    /// 悬停：`location` 为视图内坐标，鼠标离开绘图区时为 nil。
    let onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: CatcherView) {
        view.onZoom = onZoom
        view.onPan = onPan
        view.onHover = onHover
    }

    final class CatcherView: NSView {
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        var onPan: ((CGFloat, CGPoint) -> Void)?
        var onHover: ((CGPoint?) -> Void)?

        /// 用左上原点，与 SwiftUI 的坐标系一致（否则悬停坐标的 y 会上下翻转）。
        override var isFlipped: Bool { true }

        private var hoverTrackingArea: NSTrackingArea?
        /// 捏合事件的本地监听器（尽力而为，见安装处的说明）。
        private var magnifyMonitor: Any?

        deinit {
            if let magnifyMonitor {
                NSEvent.removeMonitor(magnifyMonitor)
            }
        }

        /// 面板可能未激活，首次点击也要能开始拖动。
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMagnifyMonitor()
            } else {
                installMagnifyMonitor()
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea {
                removeTrackingArea(hoverTrackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        /// 捏合事件的本地监听器（尽力而为）。
        ///
        /// 实测结论：菜单栏面板对 `magnify` 事件的投递**不稳定**——同一个面板、同样的
        /// `active=true` + key window 状态下，有时能收到（此时下面这个监听器生效），
        /// 有时一个都收不到（`NSView.magnify(with:)` 与 `NSEvent` 本地监听器都拿不到）。
        /// 因此这里只作为补充；可靠的触控板/鼠标入口是 `scrollWheel`（⌘+滚轮缩放、
        /// 双指横扫平移）与标题栏按钮。
        private func installMagnifyMonitor() {
            guard magnifyMonitor == nil else { return }
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { [weak self] event in
                guard let self, let ownWindow = self.window else { return event }

                // 不能用 `event.window === self.window` 判断目标：`magnify` 事件的
                // `event.window` 并不指向面板窗口。改用光标的屏幕坐标 + 命中测试判断。
                let windowPoint = ownWindow.convertPoint(fromScreen: NSEvent.mouseLocation)
                let hit = ownWindow.contentView?.hitTest(windowPoint)
                guard hit === self || (hit?.isDescendant(of: self) ?? false) else { return event }

                let point = self.convert(windowPoint, from: nil)
                guard self.bounds.contains(point) else { return event }

                self.onZoom?(1 + event.magnification, point)
                return nil
            }
        }

        private func removeMagnifyMonitor() {
            if let magnifyMonitor {
                NSEvent.removeMonitor(magnifyMonitor)
                self.magnifyMonitor = nil
            }
        }

        override func mouseMoved(with event: NSEvent) {
            onHover?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(nil)
        }

        override func magnify(with event: NSEvent) {
            onZoom?(1 + event.magnification, convert(event.locationInWindow, from: nil))
        }

        override func mouseDragged(with event: NSEvent) {
            onPan?(event.deltaX, convert(event.locationInWindow, from: nil))
        }

        override func scrollWheel(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)

            if event.modifierFlags.contains(.command) {
                onZoom?(1 + event.scrollingDeltaY * 0.01, location)
                return
            }
            // 横向双指滑动视为平移；纵向滚动交回父级 ScrollView，保住整页滚动。
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
                super.scrollWheel(with: event)
                return
            }
            onPan?(event.scrollingDeltaX, location)
        }
    }
}

/// 图表标题栏的「重置缩放」按钮：把窗口恢复为默认范围。
struct ChartZoomResetButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("重置缩放")
        .accessibilityLabel("重置缩放")
    }
}

/// 图表标题栏的缩放按钮：手势之外的可用入口。
struct ChartZoomButton: View {
    enum Kind {
        case zoomIn
        case zoomOut
    }

    /// 每次点击的缩放倍率。
    static let step: Double = 1.8

    let kind: Kind
    let action: () -> Void

    private var symbol: String {
        switch kind {
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        }
    }

    private var title: String {
        switch kind {
        case .zoomIn: "放大时间轴"
        case .zoomOut: "缩小时间轴"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}

extension Binding where Value == ChartZoomWindow? {
    /// 以可见窗口中心为锚点缩放；窗口无变化时不写入状态。
    func zoom(by magnification: Double, effective: ChartZoomWindow) {
        let next = effective.zoomed(by: magnification, anchorFraction: 0.5)
        guard next != effective else { return }
        wrappedValue = next
    }
}

/// 图表标题栏的「放大查看」按钮：打开面板内放大浮层。
struct ChartExpandButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("放大查看")
        .accessibilityLabel("放大查看")
    }
}

/// 绘图区高度：固定值，或 `nil` 表示撑满父容器剩余空间（放大浮层内使用）。
struct ChartPlotHeightModifier: ViewModifier {
    let height: CGFloat?

    func body(content: Content) -> some View {
        if let height {
            content.frame(height: height)
        } else {
            content.frame(maxHeight: .infinity)
        }
    }
}

extension View {
    func chartPlotHeight(_ height: CGFloat?) -> some View {
        modifier(ChartPlotHeightModifier(height: height))
    }
}
