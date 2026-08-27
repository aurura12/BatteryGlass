import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BatteryHistoryStore.self) private var history

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("低电量提醒") {
                Toggle("启用低电量通知", isOn: $settings.lowBatteryNotificationsEnabled)
                    .onChange(of: settings.lowBatteryNotificationsEnabled) { _, enabled in
                        if enabled {
                            Task {
                                await NotificationService.shared.requestAuthorizationIfNeeded()
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
                    history.clearHistory()
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
        .frame(width: 440, height: 560)
    }
}
