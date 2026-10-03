import Foundation

enum PowerDisplayStatus: Equatable, Sendable {
    case ready
    case updating
    case unavailable

    var placeholder: String? {
        switch self {
        case .ready: return nil
        case .updating: return "更新中"
        case .unavailable: return "--"
        }
    }

    var message: String? {
        switch self {
        case .ready: return nil
        case .updating: return "功率更新中"
        case .unavailable: return "暂无有效功率数据"
        }
    }
}

/// 插拔电源时，连接信号可能先于电量计和功率遥测更新。
/// 只控制实时展示，不改动原始功率或历史能耗的取值。
struct PowerDisplayTransition: Sendable {
    private static let maximumWait: TimeInterval = 90

    private struct Pending: Sendable {
        let startedAt: Date
        let batteryUpdateTime: TimeInterval?
        let adapterInputPowerW: Double?
    }

    private var lastAdapterConnected: Bool?
    private var pending: Pending?

    mutating func update(
        snapshot: BatterySnapshot,
        batteryUpdateTime: TimeInterval?
    ) -> PowerDisplayStatus {
        guard snapshot.isPresent, snapshot.state != .unknown else {
            lastAdapterConnected = nil
            pending = nil
            return .ready
        }
        let updateTime = batteryUpdateTime.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }

        let sourceChanged = lastAdapterConnected.map { $0 != snapshot.adapterConnected } ?? false
        // 应用也可能恰好在插拔过渡期启动，此时没有上一拍连接状态。
        let startedWithConflictingReading = lastAdapterConnected == nil && (
            snapshot.adapterConnected
                ? snapshot.power < -BatteryPowerThresholds.minimumDischargeW && !hasAdapterInput(snapshot)
                : snapshot.power > 0
        )
        lastAdapterConnected = snapshot.adapterConnected

        if sourceChanged || startedWithConflictingReading {
            pending = Pending(
                startedAt: snapshot.timestamp,
                batteryUpdateTime: updateTime,
                adapterInputPowerW: snapshot.adapterInputPowerW
            )
        }
        guard let pending else { return .ready }

        // 已有与新供电方式一致的读数时立即展示，不固定等待一段时间。
        if readingsMatchSource(snapshot) {
            self.pending = nil
            return .ready
        }

        // UpdateTime 标记电量计实际更新；2 Hz 重读同一份缓存不算新测量。
        // 插电后的新测量即使仍为负也可以展示，以保留真实的混合供电。
        let batteryWasUpdated = updateTime.map { updated in
            pending.batteryUpdateTime.map { updated > $0 } ?? true
        } ?? false
        let adapterInputWasUpdated = hasAdapterInput(snapshot)
            && snapshot.adapterInputPowerW != pending.adapterInputPowerW
            && pending.batteryUpdateTime == nil && updateTime == nil
        let freshPowerAvailable = snapshot.adapterConnected
            ? batteryWasUpdated || adapterInputWasUpdated
            : batteryWasUpdated && (snapshot.systemPowerW ?? 0) > 0
        if snapshot.power.isFinite, freshPowerAvailable {
            self.pending = nil
            return .ready
        }

        // 长期缺少新测量时明确显示缺失；保留基线，读数恢复后仍可自动退出。
        return snapshot.timestamp.timeIntervalSince(pending.startedAt) < Self.maximumWait
            ? .updating : .unavailable
    }

    private func readingsMatchSource(_ snapshot: BatterySnapshot) -> Bool {
        guard snapshot.power.isFinite else { return false }
        if snapshot.adapterConnected {
            guard snapshot.power >= -BatteryPowerThresholds.minimumDischargeW else { return false }
            return hasAdapterInput(snapshot)
                || (snapshot.state == .charging && snapshot.power > 0)
                || snapshot.isCharged
        }
        return snapshot.power < -BatteryPowerThresholds.minimumDischargeW
    }

    private func hasAdapterInput(_ snapshot: BatterySnapshot) -> Bool {
        guard let input = snapshot.adapterInputPowerW, input.isFinite else { return false }
        return input > BatteryPowerThresholds.minimumDischargeW
    }
}
