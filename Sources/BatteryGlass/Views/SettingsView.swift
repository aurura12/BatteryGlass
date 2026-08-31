import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BatteryHistoryStore.self) private var history

    @State private var showingClearHistoryConfirmation = false
    @State private var showingNotificationDeniedAlert = false
    @State private var showingLoginItemApprovalAlert = false
    @State private var showingLoginItemErrorAlert = false
    @State private var showingExportErrorAlert = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("通用") {
                Toggle("开机自启动", isOn: $settings.launchAtLoginEnabled)
                    .disabled(!loginItemAvailable)
                    .onChange(of: settings.launchAtLoginEnabled) { oldValue, newValue in
                        guard oldValue != newValue else { return }
                        applyLaunchAtLoginChange(from: oldValue, to: newValue)
                    }

                if loginItemAvailable {
                    Text("登录 macOS 后自动启动 BatteryGlass。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("需通过 .app 应用运行后才能设置开机自启动。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("菜单栏图标", selection: $settings.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Toggle("启动时显示主窗口", isOn: $settings.showMainWindowAtLaunch)
            }

            Section("提醒") {
                Toggle("启用低电量通知", isOn: $settings.lowBatteryNotificationsEnabled)
                    .onChange(of: settings.lowBatteryNotificationsEnabled) { _, enabled in
                        if enabled {
                            Task {
                                let authorized = await NotificationService.shared.requestAuthorizationIfNeeded()
                                if !authorized {
                                    settings.lowBatteryNotificationsEnabled =
                                        NotificationPermissionPolicy.settingValue(afterAuthorization: authorized)
                                    showingNotificationDeniedAlert = true
                                }
                            }
                        }
                    }

                if settings.lowBatteryNotificationsEnabled {
                    HStack {
                        Text("提醒阈值")
                        Spacer()
                        Text("\(Int(settings.lowBatteryThreshold))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.lowBatteryThreshold, in: 10...50, step: 5)
                }

                Toggle("外接电源变化通知", isOn: $settings.adapterChangeNotificationsEnabled)
            }

            Section("流体玻璃动效") {
                HStack {
                    Text("玻璃浓度")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.animationIntensity * 100))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.animationIntensity, in: 0.1...1, step: 0.05)

                HStack {
                    Text("流动速度")
                    Spacer()
                    Text(String(format: "%.1fx", settings.animationSpeed))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.animationSpeed, in: 0.3...2.0, step: 0.1)
            }

            Section("桌面小组件") {
                Toggle("显示桌面小组件", isOn: $settings.desktopWidgetEnabled)

                Picker("尺寸", selection: $settings.desktopWidgetStyle) {
                    ForEach(DesktopWidgetStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.desktopWidgetStyle) { _, _ in
                    NotificationCenter.default.post(name: .desktopWidgetStyleChanged, object: nil)
                }

                Button("重置小组件位置") {
                    NotificationCenter.default.post(name: .resetDesktopWidgetPosition, object: nil)
                }
                Text("小组件会悬浮在桌面图标层级，可拖动调整位置，鼠标悬停右上角可关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("数据与历史") {
                Toggle("记录充放电历史", isOn: $settings.recordHistory)
                Button("清空历史数据", role: .destructive) {
                    showingClearHistoryConfirmation = true
                }

                Menu {
                    Button("导出 CSV…") { exportHistory(asCSV: true) }
                    Button("导出 JSON…") { exportHistory(asCSV: false) }
                } label: {
                    Label("导出历史数据", systemImage: "square.and.arrow.up")
                }

                Toggle("记录电源诊断日志", isOn: $settings.powerDiagnosticsLoggingEnabled)
                Text("启用后每秒记录一次原始功率遥测和应用计算结果，日志最多保留约 5 MB。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("打开诊断日志文件夹") {
                    PowerDiagnosticsLogger.shared.openLogDirectory()
                }
            }

            Section("关于") {
                LabeledContent("版本", value: "1.0.0")
                Text("BatteryGlass 通过 IOKit 实时读取电池数据，菜单栏常驻，无需任何网络权限。macOS 26+ 使用系统 Liquid Glass 材质，macOS 14/15 自动降级为原生毛玻璃。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 800)
        .confirmationDialog(
            "确定要清空全部历史数据吗？此操作不可撤销。",
            isPresented: $showingClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                history.clearHistory()
            }
            Button("取消", role: .cancel) {}
        }
        .alert("通知权限不可用", isPresented: $showingNotificationDeniedAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("BatteryGlass 的通知权限已被拒绝，低电量提醒将不会送达。请到「系统设置 → 通知」中为 BatteryGlass 开启权限后重试。")
        }
        .alert("开机自启动待批准", isPresented: $showingLoginItemApprovalAlert) {
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("BatteryGlass 已发起开机自启动注册，需要你在系统中批准后才能生效。请到「系统设置 → 通用 → 登录项」允许 BatteryGlass。")
        }
        .alert("设置开机自启动失败", isPresented: $showingLoginItemErrorAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("无法修改开机自启动设置，请稍后重试，或到「系统设置 → 通用 → 登录项」中手动管理。")
        }
        .alert("导出失败", isPresented: $showingExportErrorAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("无法写入导出文件，请检查目标位置是否可写。")
        }
    }

    /// 未从 .app 包运行时（如直接运行可执行文件）无法操作登录项，禁用开关。
    private var loginItemAvailable: Bool {
        LoginItemService.currentState != .unavailable
    }

    private func applyLaunchAtLoginChange(from oldValue: Bool, to newValue: Bool) {
        switch LoginItemService.apply(desiredEnabled: newValue) {
        case .applied:
            break
        case .needsApproval:
            showingLoginItemApprovalAlert = true
        case .unavailable:
            settings.launchAtLoginEnabled = oldValue
        case .failed:
            settings.launchAtLoginEnabled = oldValue
            showingLoginItemErrorAlert = true
        }
    }

    /// 导出历史数据：CSV 或 JSON，通过保存面板选择目标位置。
    private func exportHistory(asCSV: Bool) {
        let panel = NSSavePanel()
        if asCSV {
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "BatteryGlass-历史数据.csv"
        } else {
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "BatteryGlass-历史数据.json"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content = asCSV
            ? HistoryExporter.csvString(samples: history.samples, dailySummaries: history.dailySummaries)
            : HistoryExporter.jsonString(samples: history.samples, dailySummaries: history.dailySummaries)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showingExportErrorAlert = true
        }
    }
}
