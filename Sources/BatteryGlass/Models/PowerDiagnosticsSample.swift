import Foundation

struct PowerDiagnosticsSample: Codable, Sendable {
    let timestamp: Date
    let state: PowerState
    let adapterConnected: Bool
    let isCharging: Bool
    let batteryVoltageV: Double
    let batteryCurrentA: Double
    let batteryPowerW: Double
    let batteryDischargePowerW: Double?
    let batteryDischargingWhilePlugged: Bool
    let telemetryBatteryPowerW: Double?
    let systemPowerInW: Double?
    let systemLoadW: Double?
    let systemVoltageInV: Double?
    let systemCurrentInA: Double?
    let adapterWatts: Double?
    let adapterVoltageV: Double?
    let adapterCurrentA: Double?
    let snapshotSystemPowerW: Double?
    let chargingPowerW: Double?
    let directSupplyPowerW: Double?
    let adapterOutputPowerW: Double?
    let consumptionPowerW: Double?
    /// AppleSmartBattery 的原始累计墙上输入能量计数，用于硬件校准。
    var accumulatedWallEnergyEstimate: UInt64? = nil
}
