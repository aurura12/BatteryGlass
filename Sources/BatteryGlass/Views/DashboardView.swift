import AppKit
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case live = "实时"
    case history = "历史"

    var id: String { rawValue }
}

struct DashboardView: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(BatteryHistoryStore.self) private var history
    @Environment(AppSettings.self) private var settings
    @AppStorage("BatteryGlass.panelTab") private var tabRaw = PanelTab.live.rawValue

    private var tab: PanelTab {
        get { PanelTab(rawValue: tabRaw) ?? .live }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    var body: some View {
        GlassContainerIfAvailable {
            VStack(spacing: DesignTokens.spacingL) {
                header

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
                        ScrollView {
                            LiveDashboardView()
                                .padding(.vertical, DesignTokens.spacingXS)
                        }
                        .scrollIndicators(.hidden)
                        .transition(.pageSwitch(insertionEdge: insertionEdge, removalEdge: removalEdge))
                    } else {
                        HistoryView()
                            .transition(.pageSwitch(insertionEdge: insertionEdge, removalEdge: removalEdge))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                footer
            }
            .padding(DesignTokens.spacingXL)
            .background {
                FluidGlassBackground(
                    state: monitor.snapshot.state,
                    colors: BatteryStyling.gradient(for: monitor.snapshot),
                    intensity: settings.animationIntensity,
                    speed: settings.animationSpeed
                )
            }
            .panelGlassSurface(cornerRadius: DesignTokens.cornerRadiusPanel)
        }
        .frame(width: 392, height: 672)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: tab)
    }

    /// 历史页从右侧滑入，实时页从左侧滑入，形成方向感切换。
    private var insertionEdge: Edge {
        tab == .live ? .leading : .trailing
    }

    private var removalEdge: Edge {
        tab == .live ? .trailing : .leading
    }

    private var header: some View {
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
        switch monitor.snapshot.state {
        case .charging: return "充电中"
        case .discharging: return "电池供电"
        case .pluggedIn: return "已接通电源"
        case .unknown: return "未知"
        }
    }

    private var statusText: String {
        let s = monitor.snapshot
        if s.state == .charging {
            return s.isFinishingCharge ? "正在涓流充电" : "正在充电"
        }
        if s.state == .pluggedIn {
            return s.isCharged ? "已接通电源 · 电池已充满" : "已接通电源"
        }
        if s.state == .discharging {
            return "电池供电中"
        }
        return "未检测到电池"
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
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
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
