import Foundation

/// Raw cumulative values exposed by AppleSmartBattery's PowerTelemetryData.
/// These values are intentionally kept as UInt64 until validated and converted.
struct PowerTelemetryCounters: Equatable, Sendable {
    var accumulatedWallEnergyEstimate: UInt64?
}

enum PowerTelemetryEnergy {
    /// Current implementations are treated as micro-watt-hours. This unit
    /// assumption must still be calibrated against a physical wattmeter on
    /// each supported hardware family; plausibility checks reject bad deltas.
    private static let rawUnitsPerKWh = 1_000_000.0
    private static let maximumPlausiblePowerW = 500.0

    /// Converts a counter delta to kWh, rejecting resets and implausible jumps.
    static func wallEnergyKWh(
        before: UInt64?,
        after: UInt64?,
        duration: TimeInterval,
        calibrationFactor: Double = 1.0
    ) -> Double? {
        guard let before,
              let after,
              after >= before,
              duration > 0,
              calibrationFactor.isFinite,
              calibrationFactor > 0 else {
            return nil
        }
        let rawDelta = after - before
        guard rawDelta > 0 else { return nil }

        let energyKWh = Double(rawDelta) / rawUnitsPerKWh * calibrationFactor
        let averagePowerW = energyKWh * 3_600_000 / duration
        guard energyKWh.isFinite,
              averagePowerW.isFinite,
              averagePowerW > 0,
              averagePowerW <= maximumPlausiblePowerW else {
            return nil
        }
        return energyKWh
    }
}
