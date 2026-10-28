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
    var powerDisplayStatus: PowerDisplayStatus = .ready

    /// 过渡期先显示已检测到的供电方式，避免沿用旧的充电标志。
    var displayState: PowerState {
        guard powerDisplayStatus != .ready, state != .unknown else { return state }
        return adapterConnected ? .pluggedIn : .discharging
    }

    var displayStatusText: String {
        if let message = powerDisplayStatus.message {
            return "\(displayState.rawValue) · \(message)"
        }
        switch state {
        case .charging: return isFinishingCharge ? "正在涓流充电" : "正在充电"
        case .pluggedIn: return isCharged ? "已接通电源 · 电池已充满" : "已接通电源"
        case .discharging: return "电池供电中"
        case .unknown: return "未检测到电池"
        }
    }

    var displayTimeRemaining: TimeInterval? {
        powerDisplayStatus == .ready ? timeRemaining : nil
    }

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
        if abs(electrical) >= BatteryPowerThresholds.minimumDischargeW {
            return electrical
        }
        return telemetryPowerW ?? electrical
    }

    /// The positive battery-side contribution when the signed reading confirms discharge.
    var batteryDischargePowerW: Double? {
        let batteryPower = power
        guard batteryPower.isFinite, batteryPower < -BatteryPowerThresholds.minimumDischargeW else { return nil }
        return -batteryPower
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
    ///
    /// 放电分支在电量计读数不可用时回退到 `systemPowerW`：拔插电源瞬间电量计会冻结在
    /// 0 或残留的充电值上数十秒，而同期 SystemLoad 依然有效。实测放电状态下两者中位
    /// 误差仅 1 mW，且拔电前后 SystemLoad 保持同一数值，因此回退值能与拔电前无缝衔接；
    /// 不回退会把这几十秒的功率整个丢掉（实测每天 2~3 次，合计 0.4~1.5 Wh）。
    var consumptionPowerW: Double? {
        if state == .discharging {
            return batteryDischargePowerW ?? positiveSystemPowerW
        }

        if adapterConnected {
            guard let adapterInputPowerW, adapterInputPowerW > 0 else {
                return batteryDischargingWhilePlugged ? batteryDischargePowerW : nil
            }
            return adapterInputPowerW
                + (batteryDischargingWhilePlugged ? (batteryDischargePowerW ?? 0) : 0)
        }
        // 未接入适配器、状态尚未切到放电（拔插瞬间的状态残留）：电池侧读数若已明确指向
        // 放电，仍应计量。此处原先返回 nil，会让这类瞬态窗口同样丢功率。
        return batteryDischargePowerW
    }

    /// 放电时可用于替代电池读数的系统侧功率（W）。
    ///
    /// 放电状态下 `systemPowerW` 由 SystemLoad 得出、恒为正，是电池输出的独立观测；
    /// 缺失或不合法时返回 nil，交由上层标记为读数缺失。
    private var positiveSystemPowerW: Double? {
        guard let systemPowerW, systemPowerW.isFinite, systemPowerW > 0 else { return nil }
        return systemPowerW
    }

    var temperatureCelsius: Double?
    var timeRemaining: TimeInterval?

    // 电源适配器
    var adapterConnected = false
    /// 由 BatteryMonitor 连续样本确认的插电同时放电状态。
    var batteryDischargingWhilePlugged = false
    var adapterWatts: Double?
    var adapterVoltage: Double?
    var adapterCurrent: Double?
    var adapterName: String?
    var adapterManufacturer: String?

    var percentText: String {
        state == .unknown ? "--" : "\(Int(percent.rounded()))%"
    }

    /// 展示功率取值：与主面板"实时功率"卡保持一致——适配器供电（充电/已接通电源）时
    /// 优先显示适配器输出功率（适配器输入 → 系统功耗 → 电池功率 逐级回退），否则显示电池充放电功率。
    ///
    /// 放电时若电池读数不可用则显示系统侧观测，而不是冻结的 0.0 W：面板数值与
    /// `consumptionPowerW` 记入的能量必须出自同一观测，否则会出现"面板显示 0 W、
    /// 当日能耗却在增长"。两个口径的取值链各自独立（见设计文档
    /// `docs/superpowers/plans/2026-09-06-precision-energy-accounting.md`），此处只是
    /// 让显示在读数失效时也有回退，不改变任一方的定义。
    var displayPower: Double {
        switch state {
        case .charging, .pluggedIn:
            return adapterInputPowerW ?? systemPowerW ?? power
        case .discharging:
            if let fallback = batteryDischargePowerW ?? positiveSystemPowerW {
                return -fallback
            }
            return power
        case .unknown:
            return power
        }
    }

    /// 展示功率文本：适配器供电时显示无符号适配器输出功率，电池供电时保留正负号；
    /// 未检测到电池（unknown）时无数据，显示 "--"。
    var displayPowerText: String {
        if let placeholder = powerDisplayStatus.placeholder { return placeholder }
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
