import Foundation

enum PowerState: String, Sendable, Equatable {
    case charging = "充电中"
    case discharging = "电池供电"
    case pluggedIn = "已接通电源"
    case unknown = "未知"

    var isEnergyFlowing: Bool {
        self == .charging || self == .discharging
    }
}

struct BatterySnapshot: Equatable, Sendable {
    var timestamp = Date()
    var isPresent = false
    var state: PowerState = .unknown
    var percent = 0.0
    var isCharged = false
    var isFinishingCharge = false

    // 容量（mAh）
    var currentCapacityMAh = 0.0
    var maxCapacityMAh = 0.0
    var designCapacityMAh = 0.0

    var cycleCount = 0
    var healthPercent: Double?

    // 电气参数（电压 V，电流 A，功率 W；充电为正，放电为负）
    var voltage = 0.0
    var current = 0.0
    var telemetryPowerW: Double?
    var systemPowerW: Double?

    /// 展示功率：优先电池电气参数（电压×电流），否则使用系统遥测电池功率。
    var power: Double {
        let electrical = voltage * current
        if abs(electrical) >= 0.01 {
            return electrical
        }
        return telemetryPowerW ?? electrical
    }

    /// 电池充电功率（W）：仅充电状态下有意义，数值为正。
    var chargingPowerW: Double? {
        state == .charging ? max(0, power) : nil
    }

    /// 适配器直供系统功率（W）：仅外接电源时存在（PowerTelemetryData.SystemLoad）。
    var directSupplyPowerW: Double? {
        adapterConnected ? systemPowerW : nil
    }

    /// 适配器总输出功率（W）= 给电池充电 + 系统直供。
    var adapterOutputPowerW: Double? {
        guard let direct = directSupplyPowerW else { return nil }
        return direct + (chargingPowerW ?? 0)
    }

    var temperatureCelsius: Double?
    var timeRemaining: TimeInterval?

    // 电源适配器
    var adapterConnected = false
    var adapterWatts: Double?
    var adapterVoltage: Double?
    var adapterCurrent: Double?
    var adapterName: String?
    var adapterManufacturer: String?

    var percentText: String {
        "\(Int(percent.rounded()))%"
    }

    var powerText: String {
        String(format: "%+.1f W", power)
    }

    var healthText: String {
        healthPercent.map { String(format: "%.0f%%", $0) } ?? "--"
    }
}
