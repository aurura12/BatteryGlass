import Foundation

struct PowerDiagnosticsSample: Codable, Sendable {
    let timestamp: Date
    let state: PowerState
    let adapterConnected: Bool
    let isCharging: Bool
    let batteryVoltageV: Double
    let batteryCurrentA: Double
    let batteryPowerW: Double
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
}
