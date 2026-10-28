import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BatteryHistoryStore.self) private var history

    @State private var showingClearHistoryConfirmation = false
    @State private var showingNotificationDeniedAlert = false
    @State private var showingLoginItemApprovalAlert = false
    @State private var showingLoginItemUnconfirmedAlert = false
    @State private var showingLoginItemErrorAlert = false
    @State private var showingExportErrorAlert = false
    @State private var isExporting = false
    @State private var showingClearHistoryFailedAlert = false

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
            }

            Section("提醒") {
                Toggle("启用低电量通知", isOn: $settings.lowBatteryNotificationsEnabled)
                    .onChange(of: settings.lowBatteryNotificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        requestNotificationAuthorization {
                            settings.lowBatteryNotificationsEnabled =
                                NotificationPermissionPolicy.settingValue(afterAuthorization: false)
                        }
                    }

                if settings.lowBatteryNotificationsEnabled {
                    HStack {
                        Text("提醒阈值")
                        Spacer()
                        Text("\(Int(settings.lowBatteryThreshold))%")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
                    Slider(
                        value: $settings.lowBatteryThreshold,
                        in: AppSettings.lowBatteryThresholdRange,
                        step: 5
                    )
                    .accessibilityLabel("低电量提醒阈值")
                    .accessibilityValue("\(Int(settings.lowBatteryThreshold))%")
                }

                Toggle("外接电源变化通知", isOn: $settings.adapterChangeNotificationsEnabled)
                    .onChange(of: settings.adapterChangeNotificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        requestNotificationAuthorization {
                            settings.adapterChangeNotificationsEnabled =
                                NotificationPermissionPolicy.settingValue(afterAuthorization: false)
                        }
                    }
            }

            Section("外观") {
                HStack(spacing: DesignTokens.spacingS) {
                    Text("主题色")
                    Spacer()
                    ForEach(ThemeAccentPreset.allCases) { preset in
                        themeSwatch(preset)
                    }
                }

                ColorPicker("自定义颜色", selection: themeAccentBinding, supportsOpacity: false)
                    .accessibilityLabel("自定义主题色")

                Text("主题色用于曲线、强调数值与玻璃光晕；充电、低电量等状态仍使用绿/黄/红语义色。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("流体玻璃动效") {
                HStack {
                    Text("玻璃浓度")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.animationIntensity * 100))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
                Slider(value: $settings.animationIntensity, in: 0.1...1, step: 0.05)
                    .accessibilityLabel("玻璃浓度")
                    .accessibilityValue(String(format: "%.0f%%", settings.animationIntensity * 100))

                HStack {
                    Text("流动速度")
                    Spacer()
                    Text(String(format: "%.1fx", settings.animationSpeed))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
                Slider(value: $settings.animationSpeed, in: 0.3...2.0, step: 0.1)
                    .accessibilityLabel("流动速度")
                    .accessibilityValue(String(format: "%.1f 倍", settings.animationSpeed))
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
                Text("曲线长期保留：当天约每 5 秒记录一次，往日每分钟保留一个数据点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let issue = history.persistenceIssue {
                    Label(
                        "历史记录已暂停：\(issue)。本次运行不会写入新数据，原文件保持原样；可清除历史后重新开始记录。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Button("清空历史数据", role: .destructive) {
                    showingClearHistoryConfirmation = true
                }

                Menu {
                    Button("导出 CSV…") { exportHistory(asCSV: true) }
                    Button("导出 JSON…") { exportHistory(asCSV: false) }
                } label: {
                    Label("导出历史数据", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting)
                if isExporting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在导出…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Toggle("记录电源诊断日志", isOn: $settings.powerDiagnosticsLoggingEnabled)
                Text("启用后每秒记录一次原始功率遥测和应用计算结果，保留当前日志和上一份日志，合计最多约 10 MB。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("打开诊断日志文件夹") {
                    PowerDiagnosticsLogger.shared.openLogDirectory()
                }
            }

            PowerCalibrationSection()

            Section("关于") {
                LabeledContent("版本", value: appVersion)
                Text("BatteryGlass 通过 IOKit 实时读取电池数据，菜单栏常驻，无需任何网络权限。macOS 26+ 使用系统 Liquid Glass 材质，macOS 14/15 自动降级为原生毛玻璃。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // 高度留出小屏（可见高度约 700pt）余地，超出内容由 Form 滚动。
        .frame(width: 440, height: 640)
        .confirmationDialog(
            "确定要清空全部历史数据及其备份吗？此操作不可撤销。",
            isPresented: $showingClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                if !history.clearHistory() {
                    showingClearHistoryFailedAlert = true
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("通知权限不可用", isPresented: $showingNotificationDeniedAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("BatteryGlass 的通知权限已被拒绝，低电量与插拔电源提醒都不会送达。请到「系统设置 → 通知」中为 BatteryGlass 开启权限后重试。")
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
        .alert("无法确认开机自启动状态", isPresented: $showingLoginItemUnconfirmedAlert) {
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("系统当前未报告登录项状态，无法确认开机自启动是否已关闭。请到「系统设置 → 通用 → 登录项」中检查。")
        }
        .alert("设置开机自启动失败", isPresented: $showingLoginItemErrorAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("无法修改开机自启动设置，请稍后重试，或到「系统设置 → 通用 → 登录项」中手动管理。")
        }
        .alert("清空历史失败", isPresented: $showingClearHistoryFailedAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("部分历史文件无法删除（可能被其他程序占用或权限不足）。数据未被清空，请稍后重试。")
        }
        .alert("导出失败", isPresented: $showingExportErrorAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("无法读取历史或写入导出文件，请检查数据文件与目标位置是否可访问。")
        }
    }

    /// 取色器与持久化的十六进制值互转：写入时统一为 `#RRGGBB`，避免明暗外观下分量漂移。
    private var themeAccentBinding: Binding<Color> {
        Binding(
            get: { settings.themeAccent.color },
            set: { settings.themeAccentHex = ThemeAccent(color: $0).hexString }
        )
    }

    /// 预设色块：选中项外圈加一道深色细环，避免仅靠颜色本身表达选中态。
    private func themeSwatch(_ preset: ThemeAccentPreset) -> some View {
        let selected = settings.themeAccentHex.caseInsensitiveCompare(preset.accent.hexString) == .orderedSame
        return Button {
            settings.themeAccentHex = preset.accent.hexString
        } label: {
            Circle()
                .fill(preset.accent.color)
                .frame(width: 16, height: 16)
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(selected ? 0.55 : 0), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                }
        }
        .buttonStyle(.plain)
        .help(preset.title)
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// 系统无法查询登录项状态时禁用开关。
    private var loginItemAvailable: Bool {
        LoginItemService.currentState != .unavailable
    }

    /// 两个通知开关共用的授权流程：首次开启时请求系统授权，被拒绝就回滚开关并提示，
    /// 避免出现「开关是开的、通知却永远静默失败」。
    private func requestNotificationAuthorization(onDenied: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            let authorized = await NotificationService.shared.requestAuthorizationIfNeeded()
            guard !authorized else { return }
            onDenied()
            showingNotificationDeniedAlert = true
        }
    }

    /// 优先读取 bundle 中的正式版本号，取不到时回退到默认值。
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private func applyLaunchAtLoginChange(from oldValue: Bool, to newValue: Bool) {
        switch LoginItemService.apply(desiredEnabled: newValue) {
        case .applied:
            break
        case .needsApproval:
            showingLoginItemApprovalAlert = true
        case .unavailable:
            settings.launchAtLoginEnabled = oldValue
        case .cannotConfirm:
            settings.launchAtLoginEnabled = oldValue
            showingLoginItemUnconfirmedAlert = true
        case .failed:
            settings.launchAtLoginEnabled = oldValue
            showingLoginItemErrorAlert = true
        }
    }

    /// 导出历史数据：CSV 或 JSON，通过保存面板选择目标位置。
    private func exportHistory(asCSV: Bool) {
        guard !isExporting else { return }

        let panel = NSSavePanel()
        if asCSV {
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "BatteryGlass-历史数据.csv"
        } else {
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "BatteryGlass-历史数据.json"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 值快照：汇总与睡眠数据很小，先在主线程取好；样本由 store 在持久化队列读取。
        let summaries = history.dailySummaries
        let sleepSegments = history.sleepSegments
        let sleepIntervals = history.sleepIntervals
        let format: HistoryExporter.ExportFormat = asCSV ? .csv : .json

        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let samples = try await history.allCurveSamplesAsync()
                // 编码与写盘都离开主线程：多年按分钟归档时，光是 JSON 编码就能让面板卡住数秒。
                try await Task.detached(priority: .userInitiated) {
                    try HistoryExporter.write(
                        format,
                        samples: samples,
                        dailySummaries: summaries,
                        sleepSegments: sleepSegments,
                        sleepIntervals: sleepIntervals,
                        to: url
                    )
                }.value
            } catch {
                showingExportErrorAlert = true
            }
        }
    }
}
