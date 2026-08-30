import Foundation

enum PowerState: String, Codable, Sendable, Equatable {
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
    /// 适配器输入功率（W），包含系统运行、给电池充电和转换损耗。
    var adapterInputPowerW: Double?

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

    /// 系统直供估算（W）= 适配器总输入 - 电池充电功率。
    /// SystemLoad 的电源层级和 BatteryPower 存在耦合，不能直接作为直供功率。
    var directSupplyPowerW: Double? {
        guard adapterConnected,
              state != .discharging,
              let input = adapterInputPowerW,
              input > 0 else {
            return nil
        }
        return max(0, input - (chargingPowerW ?? 0))
    }

    /// 适配器总输出功率（W）：使用系统输入遥测值，避免重复累加。
    var adapterOutputPowerW: Double? {
        guard adapterConnected,
              state != .discharging,
              let input = adapterInputPowerW,
              input > 0 else {
            return nil
        }
        return input
    }

    /// 用于每日能耗统计的统一功率：适配器输入或电池放电功率。
    var consumptionPowerW: Double? {
        if state == .discharging, power < 0 {
            return abs(power)
        }

        if adapterConnected {
            guard let adapterInputPowerW, adapterInputPowerW > 0 else { return nil }
            return adapterInputPowerW
        }
        return nil
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

    /// 展示功率取值：与主面板"实时功率"卡保持一致——适配器供电（充电/已接通电源）时
    /// 优先显示系统功率（适配器输入 → 系统功率 → 电池功率），否则显示电池充放电功率。
    var displayPower: Double {
        switch state {
        case .charging, .pluggedIn:
            return adapterInputPowerW ?? systemPowerW ?? power
        case .discharging, .unknown:
            return power
        }
    }

    /// 展示功率文本：适配器供电时显示无符号系统功率，电池供电时保留正负号；
    /// 未检测到电池（unknown）时无数据，显示 "--"。
    var displayPowerText: String {
        switch state {
        case .charging, .pluggedIn:
            return String(format: "%.1f W", displayPower)
        case .discharging:
            return String(format: "%+.1f W", displayPower)
        case .unknown:
            return "--"
        }
    }

    var healthText: String {
        healthPercent.map { String(format: "%.0f%%", $0) } ?? "--"
    }
}
