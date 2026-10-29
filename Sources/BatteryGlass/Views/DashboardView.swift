import AppKit
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case live = "实时"
    case history = "历史"

    var id: String { rawValue }
}

struct DashboardView: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(BatteryHistoryStore.self) private var history
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("BatteryGlass.panelTab") private var tabRaw = PanelTab.live.rawValue
    @State private var showingQuitConfirmation = false
    /// 承载面板的窗口是否真正可见。面板关闭后 MenuBarExtra 只把窗口 order out，
    /// 内容视图仍存活，需要据此暂停持续动画，否则离屏窗口会被反复布局（见 `PanelVisibilityObserver`）。
    @State private var panelVisible = false
    /// 面板关闭时冻结的实时页数据。离屏内容改为读取这份快照，
    /// 不再订阅 `BatteryMonitor` / `BatteryHistoryStore`（否则每秒发布与每 5 秒
    /// 汇总更新都会重算整页 KPI 卡片）。
    @State private var frozenDashboard: LiveDashboardRenderedData?

    private var tab: PanelTab {
        get { PanelTab(rawValue: tabRaw) ?? .live }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    /// 面板尺寸固定 392×672：标准字号下直接展示完整内容，系统字号放大到 `.xLarge` 及以上时
    /// 回退到滚动版本。判定与可用字号范围集中在 `PanelLayoutPolicy`（可单测）。
    /// 相比 `ViewThatFits`（每个布局周期都会测量两个分支），这里只测量一个。
    private var usesScrollFallback: Bool {
        PanelLayoutPolicy.usesScrollFallback(for: dynamicTypeSize)
    }

    var body: some View {
        GlassContainerIfAvailable {
            VStack(spacing: DashboardLayout.sectionSpacing) {
                DashboardHeader(renderedSnapshot: frozenDashboard?.snapshot)

                PanelSegmentedControl(
                    items: PanelTab.allCases,
                    selection: Binding(
                        get: { tab },
                        set: { tab = $0 }
                    ),
                    label: { $0.rawValue }
                )
                .frame(width: 200)

                ZStack {
                    if tab == .live {
                        // 标准字号下直接展示完整实时面板，避免出现右侧滚动进度；
                        // 字体被系统放大导致空间不足时才回退到可滚动版本。
                        Group {
                            if usesScrollFallback {
                                ScrollView {
                                    LiveDashboardView(rendered: frozenDashboard)
                                        .padding(.vertical, DashboardLayout.contentInset)
                                }
                                .scrollIndicators(.hidden)
                            } else {
                                LiveDashboardView(rendered: frozenDashboard)
                                .padding(.vertical, DashboardLayout.contentInset)
                            }
                        }
                        .transition(.identity)
                    } else {
                        HistoryView(isVisible: panelVisible)
                            .transition(.identity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                footer
            }
            .padding(DashboardLayout.panelPadding)
            .background {
                DashboardPanelBackground(
                    isAnimated: tab == .live && panelVisible,
                    renderedSnapshot: frozenDashboard?.snapshot
                )
            }
            .background {
                PanelVisibilityObserver { visible in
                    // 先冻结再切到隐藏态：隐藏后的第一帧就只读快照，不再订阅 monitor。
                    if visible {
                        frozenDashboard = nil
                    } else {
                        frozenDashboard = LiveDashboardRenderedData(
                            snapshot: monitor.snapshot,
                            recentPower: monitor.recentPower,
                            todayEnergy: TodayEnergyDisplay(
                                summary: history.todaySummary,
                                recordingEnabled: settings.recordHistory
                            )
                        )
                    }
                    panelVisible = visible
                    // 采样频率与界面发布频率跟随可见性：离屏时不再 2 Hz 重算视图图。
                    monitor.setPanelVisible(visible)
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .panelGlassSurface(cornerRadius: DesignTokens.cornerRadiusPanel)
        }
        .frame(width: 392, height: 672)
        // 固定面板只支持到 xxxLarge：超出后说明文字会撑破卡片高度，而数值仍不缩放。
        .dynamicTypeSize(PanelLayoutPolicy.supportedDynamicTypeSizes)
        // 主题色在此注入：设置页改动 `themeAccentHex` 会让本视图重算，环境值随之更新。
        .environment(\.themeAccent, settings.themeAccent.color)
        .confirmationDialog("确定要退出 BatteryGlass 吗？", isPresented: $showingQuitConfirmation, titleVisibility: .visible) {
            Button("退出", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Button {
                showingQuitConfirmation = true
            } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

/// Keeps 2 Hz battery observations inside the header instead of invalidating the page host.
private struct DashboardHeader: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(\.themeAccent) private var themeAccent
    /// 非 nil 表示面板已离屏：只读冻结快照，不订阅 `BatteryMonitor`。
    var renderedSnapshot: BatterySnapshot?

    private var snapshot: BatterySnapshot { renderedSnapshot ?? monitor.snapshot }

    private var tint: Color {
        BatteryStyling.tint(for: snapshot, accent: themeAccent)
    }

    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            AppMarkView(snapshot: snapshot)

            VStack(alignment: .leading, spacing: 1) {
                Text("BatteryGlass")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(stateShortLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.12)))
        }
        // 应用名、状态说明与状态胶囊合成一个 VoiceOver 焦点。
        .accessibilityElement(children: .combine)
    }

    private var stateShortLabel: String {
        snapshot.displayState.rawValue
    }

    private var statusText: String {
        snapshot.displayStatusText
    }
}

/// Battery changes update the backdrop locally, leaving the history chart subtree untouched.
private struct DashboardPanelBackground: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    let isAnimated: Bool
    /// 非 nil 表示面板已离屏：背景光晕跟随冻结快照，不再按采样节拍重算。
    var renderedSnapshot: BatterySnapshot?

    private var snapshot: BatterySnapshot { renderedSnapshot ?? monitor.snapshot }

    var body: some View {
        FluidGlassBackground(
            colors: BatteryStyling.gradient(for: snapshot, accent: settings.themeAccent.color),
            intensity: settings.animationIntensity,
            speed: settings.animationSpeed,
            isAnimated: isAnimated
        )
    }
}


/// 应用品牌标记：渐变圆角徽章 + 闪电。
struct AppMarkView: View {
    let snapshot: BatterySnapshot
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: BatteryStyling.gradient(for: snapshot, accent: themeAccent),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                )

            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
    }
}
