import Foundation

/// Confirms a real battery discharge while the adapter is connected.
///
/// The battery current can remain negative for a short period after an adapter
/// transition, so one sample is intentionally not enough to classify a mixed
/// source state. `.charging` needs a longer run than `.pluggedIn`, where macOS
/// has already stopped charging: a negative reading there can lag the state change.
///
/// 判定带滞回：进入需要跨过 `confirmedDischargeW`，维持只要求读数仍低于噪声下限。
/// 没有滞回时，读数在 0.01–0.1 W 之间抖动就会让面板在「电池放电」和「给电池 0.0 W」
/// 之间来回跳，并把电池放电贡献反复从能耗里摘掉。
struct BatteryDischargeConfirmation: Sendable {
    private static let requiredPluggedInSamples = 2
    private static let requiredChargingSamples = 6

    private var consecutiveNegativeSamples = 0
    private var isConfirmed = false
    /// 连续样本数按状态分开计数，因此状态切换必须重置，否则
    /// 「充电中攒了 5 个 → 变成已接通电源」会立刻满足 2 个样本的门槛。
    private var countingState: PowerState?

    mutating func update(
        adapterConnected: Bool,
        state: PowerState,
        batteryPowerW: Double
    ) -> Bool {
        guard adapterConnected,
              state == .pluggedIn || state == .charging,
              batteryPowerW.isFinite,
              batteryPowerW < -BatteryPowerThresholds.minimumDischargeW else {
            reset()
            return false
        }

        // 已确认：只要读数仍在噪声下限之上就维持（退出条件由上面的 guard 负责）。
        if isConfirmed {
            return true
        }

        if countingState != state {
            countingState = state
            consecutiveNegativeSamples = 0
        }
        guard batteryPowerW < -BatteryPowerThresholds.confirmedDischargeW else {
            consecutiveNegativeSamples = 0
            return false
        }

        consecutiveNegativeSamples += 1
        let requiredSamples = state == .charging
            ? Self.requiredChargingSamples
            : Self.requiredPluggedInSamples
        guard consecutiveNegativeSamples >= requiredSamples else { return false }

        isConfirmed = true
        return true
    }

    private mutating func reset() {
        consecutiveNegativeSamples = 0
        countingState = nil
        isConfirmed = false
    }
}
