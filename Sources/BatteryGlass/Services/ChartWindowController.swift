import AppKit
import SwiftUI

/// 放大查看曲线的独立窗口（普通可缩放窗口，不置顶）。
///
/// 菜单栏面板固定 392×672，绘图区（约 304×407）对时间序列来说长宽比并不合适；
/// 这里开一个宽窗口用于看图。窗口位置与大小经 `setFrameAutosaveName` 记住，
/// 重复打开沿用上次的尺寸与位置；只维护一个窗口实例，切换曲线不重建窗口。
@MainActor
@Observable
final class ChartWindowController {
    @ObservationIgnored private let history: BatteryHistoryStore
    @ObservationIgnored private let model = ChartDetailModel()
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private let visibilityDelegate = ChartWindowVisibilityDelegate()

    private static let autosaveName = "BatteryGlass.chartWindow"
    private static let defaultSize = NSSize(width: 1_000, height: 600)
    private static let minimumSize = NSSize(width: 480, height: 320)

    init(history: BatteryHistoryStore) {
        self.history = history
    }

    /// 打开（或复用）窗口并切到指定曲线；日期重置为今天。
    func show(_ kind: ExpandedChart) {
        model.kind = kind
        model.selectedDay = Calendar.current.startOfDay(for: Date())
        model.isVisible = true
        let window = window ?? makeWindow()
        self.window = window
        window.title = kind.title(day: model.selectedDay)
        // 普通窗口需要 App 处于前台才能正常交互。
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.kind.title(day: model.selectedDay)
        window.contentMinSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.contentView = NSHostingView(
            rootView: ChartDetailView(model: model) { [weak window] kind, day in
                // 窗口内切换曲线或日期时同步标题。
                window?.title = kind.title(day: day)
            }
            .environment(history)
        )

        visibilityDelegate.onChange = { [weak self] visible in
            self?.model.isVisible = visible
        }
        window.delegate = visibilityDelegate

        // 有历史记录时按上次的位置与大小恢复；没有记录则保持默认尺寸与居中位置。
        window.setFrameAutosaveName(Self.autosaveName)
        ensureOnScreen(window)
        return window
    }

    /// 显示配置变化后恢复出的 frame 可能落在屏幕之外，此时拉回主屏。
    private func ensureOnScreen(_ window: NSWindow) {
        let isVisible = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        guard !isVisible else { return }
        window.setContentSize(Self.defaultSize)
        window.center()
    }
}

/// 把窗口的关闭 / 最小化 / 遮挡状态同步给 `ChartDetailModel.isVisible`。
/// 视图据此停止在后台按采样节拍重算整日曲线。
@MainActor
private final class ChartWindowVisibilityDelegate: NSObject, NSWindowDelegate {
    var onChange: ((Bool) -> Void)?

    func windowDidMiniaturize(_ notification: Notification) {
        onChange?(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        onChange?(true)
    }

    func windowWillClose(_ notification: Notification) {
        onChange?(false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onChange?(window.occlusionState.contains(.visible))
    }
}
