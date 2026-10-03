import AppKit
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case live = "实时"
    case history = "历史"

    var id: String { rawValue }
}

struct DashboardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("BatteryGlass.panelTab") private var tabRaw = PanelTab.live.rawValue
    @State private var showingQuitConfirmation = false

    private var tab: PanelTab {
        get { PanelTab(rawValue: tabRaw) ?? .live }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    var body: some View {
        GlassContainerIfAvailable {
            VStack(spacing: DashboardLayout.sectionSpacing) {
                DashboardHeader()

                AnimatedSegmentedControl(
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
                        // 标准字号下直接展示完整实时面板，避免出现右侧滚动进度。
                        // 字体被系统放大导致空间不足时，自动回退到可滚动版本。
                        ViewThatFits(in: .vertical) {
                            LiveDashboardView()
                                .padding(.vertical, DashboardLayout.contentInset)

                            ScrollView {
                                LiveDashboardView()
                                    .padding(.vertical, DashboardLayout.contentInset)
                            }
                            .scrollIndicators(.hidden)
                        }
                        .transition(pageTransition)
                    } else {
                        HistoryView()
                            .transition(pageTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                footer
            }
            .padding(DashboardLayout.panelPadding)
            .background {
                DashboardPanelBackground(isAnimated: tab == .live)
            }
            .panelGlassSurface(cornerRadius: DesignTokens.cornerRadiusPanel)
        }
        .frame(width: 392, height: 672)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: tab)
        .confirmationDialog("确定要退出 BatteryGlass 吗？", isPresented: $showingQuitConfirmation, titleVisibility: .visible) {
            Button("退出", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 减弱动态时只做淡入淡出，去掉滑动/缩放/模糊位移。
    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .pageSwitch(insertionEdge: insertionEdge, removalEdge: removalEdge)
    }

    /// 历史页从右侧滑入，实时页从左侧滑入，形成方向感切换。
    private var insertionEdge: Edge {
        tab == .live ? .leading : .trailing
    }

    private var removalEdge: Edge {
        tab == .live ? .trailing : .leading
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

    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            AppMarkView(snapshot: monitor.snapshot)

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
                    .fill(BatteryStyling.tint(for: monitor.snapshot))
                    .frame(width: 6, height: 6)
                Text(stateShortLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BatteryStyling.tint(for: monitor.snapshot))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(BatteryStyling.tint(for: monitor.snapshot).opacity(0.12)))
        }
    }

    private var stateShortLabel: String {
        monitor.snapshot.displayState.rawValue
    }

    private var statusText: String {
        monitor.snapshot.displayStatusText
    }
}

/// Battery changes update the backdrop locally, leaving the history chart subtree untouched.
private struct DashboardPanelBackground: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    let isAnimated: Bool

    var body: some View {
        FluidGlassBackground(
            colors: BatteryStyling.gradient(for: monitor.snapshot),
            intensity: settings.animationIntensity,
            speed: settings.animationSpeed,
            isAnimated: isAnimated
        )
    }
}

/// 应用品牌标记：渐变圆角徽章 + 闪电。
struct AppMarkView: View {
    let snapshot: BatterySnapshot

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: BatteryStyling.gradient(for: snapshot),
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
