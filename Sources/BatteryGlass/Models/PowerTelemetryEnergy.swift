import Foundation

/// Raw cumulative values exposed by AppleSmartBattery's PowerTelemetryData.
/// These values are intentionally kept as UInt64 until validated and converted.
struct PowerTelemetryCounters: Equatable, Sendable {
    var accumulatedWallEnergyEstimate: UInt64?
}

enum PowerTelemetryEnergy {
    /// Provisional normalization for the private raw counter (counter units per kWh).
    /// This conversion alone is not trusted; SleepEnergyCalculator only accepts it
    /// after a physical wattmeter calibration for the active hardware/OS context.
    ///
    /// Empirically derived on MacBookPro18,1 from `power-diagnostics.jsonl`:
    /// the counter's true scale is ~1e9 units/kWh — 1000× finer than the earlier
    /// `1e6` placeholder. Still only a starting point; the wattmeter calibration
    /// remains authoritative.
    static let rawUnitsPerKWh = 1_000_000_000.0
    private static let maximumPlausiblePowerW = 500.0

    /// Converts a raw counter delta with the default unit assumption only.
    /// Used when recording a calibration session, so the stored
    /// `uncalibratedEnergyKWh` stays consistent with `wallEnergyKWh`.
    static func uncalibratedEnergyKWh(rawDelta: UInt64) -> Double {
        Double(rawDelta) / rawUnitsPerKWh
    }

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
