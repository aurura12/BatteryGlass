import Foundation

/// Confirms a real battery discharge while the adapter is connected.
///
/// The battery current can remain negative for a short period after an adapter
/// transition, so one sample is intentionally not enough to classify a mixed
/// source state.
struct BatteryDischargeConfirmation: Sendable {
    private static let requiredConsecutiveSamples = 2
    private static let minimumDischargePowerW = 0.01

    private var consecutiveNegativeSamples = 0

    mutating func update(
        adapterConnected: Bool,
        state: PowerState,
        batteryPowerW: Double
    ) -> Bool {
        guard adapterConnected,
              state == .pluggedIn,
              batteryPowerW.isFinite,
              batteryPowerW < -Self.minimumDischargePowerW else {
            consecutiveNegativeSamples = 0
            return false
        }

        consecutiveNegativeSamples += 1
        return consecutiveNegativeSamples >= Self.requiredConsecutiveSamples
    }
}
