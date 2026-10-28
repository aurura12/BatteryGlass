import SwiftUI

/// 设置页「电源校准」分节：引导式校准会话 + 记录管理。
///
/// 校准系数按「机型 + macOS 版本」归属，只有与当前系统匹配的记录才会被
/// `BatteryMonitor` 采纳（见 `PowerTelemetryCalibrationStore.activeRecord`）。
/// 由于校准 store 是共享引用类型，这里保存后睡眠能耗计量立即使用新系数。
struct PowerCalibrationSection: View {
    @Environment(PowerTelemetryCalibrationStore.self) private var store
    @Environment(BatteryMonitor.self) private var monitor

    @State private var showingCompleteSheet = false
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var showingNoCounterAlert = false

    private enum PendingConfirmation: Identifiable {
        case cancelSession
        case clearRecords

        var id: String {
            switch self {
            case .cancelSession: "cancelSession"
            case .clearRecords: "clearRecords"
            }
        }
    }

    var body: some View {
        Section("电源校准") {
            statusRows
            sessionRows
            recordsRows
        }
        .sheet(isPresented: $showingCompleteSheet) {
            CompleteCalibrationSheet()
                .environment(store)
                .environment(monitor)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { kind in
            switch kind {
            case .cancelSession:
                Button("取消校准", role: .destructive) { store.cancelSession() }
                Button("继续校准", role: .cancel) {}
            case .clearRecords:
                Button("清空", role: .destructive) { store.clearRecords() }
                Button("取消", role: .cancel) {}
            }
        }
        .alert("无法开始校准", isPresented: $showingNoCounterAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("当前无法读取墙上能量计数器，请接通电源后重试。")
        }
    }

    // MARK: - 状态

    @ViewBuilder
    private var statusRows: some View {
        LabeledContent("机型", value: store.currentContext.hardwareModel)
        LabeledContent("校准状态", value: store.isCalibrated ? "已校准" : "未校准")

        if store.isCalibrated {
            LabeledContent("校准系数", value: String(format: "%.3f", store.calibrationFactor))
        }

        Text("睡眠能耗优先使用系统墙上能量计数器，其单位未公开，必须用电表实测校准后才计入。校准按机型与系统版本生效，仅对今后新增的睡眠段生效。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - 会话

    @ViewBuilder
    private var sessionRows: some View {
        if let session = store.session {
            LabeledContent("开始时间", value: session.startedAt.formatted(date: .numeric, time: .shortened))

            TimelineView(.periodic(from: .now, by: 1)) { context in
                LabeledContent("已用时长", value: Self.elapsedText(from: session.startedAt, to: context.date))
            }

            LabeledContent("起始计数器", value: "\(session.startCounter)")

            if let current = monitor.currentWallEnergyCounter {
                LabeledContent("当前计数器", value: "\(current)")

                if current >= session.startCounter {
                    let delta = current - session.startCounter
                    let uncalibrated = PowerTelemetryEnergy.uncalibratedEnergyKWh(rawDelta: delta)
                    LabeledContent("计数器差值", value: "\(delta)")
                    LabeledContent("等效未校准电量", value: String(format: "%.4f kWh", uncalibrated))
                } else {
                    Text("计数器已低于起始值，可能期间重启过，请取消后重新开始。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("当前无法读取计数器。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("保持接通电源，用外接电表记录同一时段的用电量，然后点击「完成校准」输入实测值。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("完成校准…") {
                guard monitor.currentWallEnergyCounter != nil else {
                    showingNoCounterAlert = true
                    return
                }
                showingCompleteSheet = true
            }

            Button("取消校准", role: .destructive) {
                pendingConfirmation = .cancelSession
            }
        } else {
            Button("开始校准") {
                guard let counter = monitor.currentWallEnergyCounter else {
                    showingNoCounterAlert = true
                    return
                }
                store.startSession(
                    startCounter: counter,
                    batteryPercent: monitor.snapshot.percent
                )
            }
            .disabled(!canStartSession)

            if !canStartSession {
                Text(startBlockedReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 记录列表

    @ViewBuilder
    private var recordsRows: some View {
        if !store.records.isEmpty {
            ForEach(store.records.sorted { $0.createdAt > $1.createdAt }) { record in
                recordRow(record)
            }

            Button("清空校准记录", role: .destructive) {
                pendingConfirmation = .clearRecords
            }
        }
    }

    private func recordRow(_ record: PowerTelemetryCalibrationRecord) -> some View {
        let applies = record.context == store.currentContext

        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "系数 %.3f", record.calibrationFactor))
                    .font(.callout)
                Text(record.createdAt.formatted(date: .numeric, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(
                    format: "未校准 %.4f kWh → 实测 %.4f kWh",
                    record.uncalibratedEnergyKWh,
                    record.measuredEnergyKWh
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)

                if !applies {
                    Text("不适用于当前系统")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button(role: .destructive) {
                store.remove(id: record.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除此校准记录")
        }
    }

    // MARK: - 辅助

    private var canStartSession: Bool {
        monitor.currentWallEnergyCounter != nil && monitor.snapshot.adapterConnected
    }

    private var startBlockedReason: String {
        monitor.currentWallEnergyCounter == nil
            ? "此机型未提供墙上能量计数器，暂不支持校准。"
            : "请接通电源后再开始校准。"
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .cancelSession: "确定要取消本次校准吗？已记录的起始计数器将被丢弃。"
        case .clearRecords, .none: "确定要清空全部校准记录吗？清空后能耗将回退为未校准口径。"
        }
    }

    private static func elapsedText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分 \(secs) 秒" }
        return "\(secs) 秒"
    }
}

/// 完成校准的数值录入弹窗：用户输入电表实测电量（kWh），会话由 store 结算。
private struct CompleteCalibrationSheet: View {
    @Environment(PowerTelemetryCalibrationStore.self) private var store
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    @State private var measuredText = ""
    @State private var warningShown = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
            Text("完成校准")
                .font(.headline)

            if let session = store.session, let current = monitor.currentWallEnergyCounter {
                let delta = current >= session.startCounter ? current - session.startCounter : 0
                let uncalibrated = PowerTelemetryEnergy.uncalibratedEnergyKWh(rawDelta: delta)

                VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                    Text("本会话计数器差值：\(delta)")
                    Text(String(format: "按默认单位换算约 %.4f kWh，请输入你在此期间用外接电表测得的总用电量（kWh）。", uncalibrated))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("会话已失效，请关闭后重新开始校准。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TextField("例如 0.25", text: $measuredText)
                .textFieldStyle(.roundedBorder)

            if warningShown {
                Text("该系数明显偏离常见范围，可能把单位输错了（电表上的 Wh 需除以 1000 换算为 kWh）。确认无误请再次点击「仍然保存」。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(warningShown ? "仍然保存" : "保存") { attemptSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.session == nil || monitor.currentWallEnergyCounter == nil)
            }
        }
        .padding(DesignTokens.spacingXL)
        .frame(width: 400)
    }

    private func attemptSave() {
        guard let session = store.session, let current = monitor.currentWallEnergyCounter else {
            errorMessage = "会话已失效，请重新开始校准。"
            return
        }
        guard let measured = Self.parse(measuredText), measured > 0 else {
            errorMessage = "请输入大于 0 的电量数值，小数点请用「.」。"
            return
        }

        let delta = current >= session.startCounter ? current - session.startCounter : 0
        let uncalibrated = PowerTelemetryEnergy.uncalibratedEnergyKWh(rawDelta: delta)
        let factor = uncalibrated > 0 ? measured / uncalibrated : 0

        if !PowerTelemetryCalibrationStore.plausibleFactorRange.contains(factor), !warningShown {
            warningShown = true
            return
        }

        switch store.completeSession(endCounter: current, measuredEnergyKWh: measured) {
        case .saved:
            dismiss()
        case .counterReset:
            errorMessage = "计数器已重置（可能期间重启过），请重新开始校准。"
        case .contextChanged:
            errorMessage = "会话期间系统版本发生变化，请重新开始校准。"
        case .invalidInput:
            errorMessage = "计数器差值为 0 或输入无效，请检查后重试。"
        case .saveFailed:
            errorMessage = "校准结果无法写入磁盘，重启后会丢失。请检查磁盘空间与文件权限后重试。"
        }
    }

    private static func parse(_ text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }
}
