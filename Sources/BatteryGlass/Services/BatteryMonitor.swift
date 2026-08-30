import AppKit
import IOKit
import IOKit.ps
import Observation

@MainActor
@Observable
final class BatteryMonitor {
    private(set) var snapshot = BatterySnapshot()
    private(set) var recentPower: [PowerSample] = []

    private let settings: AppSettings
    private var timer: Timer?
    private var lowBatteryNotified = false
    private let recentSampleLimit = 420

    init(settings: AppSettings) {
        self.settings = settings
        refresh()

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let io = readSmartBattery()
        let ps = readPowerSources()

        var s = BatterySnapshot(timestamp: Date())
        s.isPresent = io.batteryInstalled || ps.isPresent

        s.currentCapacityMAh = ps.currentCapacityMAh > 0 ? ps.currentCapacityMAh : io.currentCapacityMAh
        s.maxCapacityMAh = Self.resolvedMaxCapacity(
            powerSourcesMaximum: ps.maxCapacityMAh,
            smartBatteryFullCharge: io.fullChargeCapacityMAh
        )
        s.designCapacityMAh = ps.designCapacityMAh > 0 ? ps.designCapacityMAh : io.designCapacityMAh
        s.cycleCount = io.cycleCount > 0 ? io.cycleCount : ps.cycleCount
        s.healthPercent = io.healthPercent ?? ps.healthPercent
        s.voltage = io.voltage > 0 ? io.voltage : ps.voltage
        s.current = io.current != 0 ? io.current : ps.current
        s.temperatureCelsius = io.temperatureCelsius ?? ps.temperatureCelsius

        s.adapterConnected = io.externalConnected || ps.externalConnected
        s.adapterWatts = io.adapterWatts ?? ps.adapterWatts
        s.adapterVoltage = io.adapterVoltage ?? ps.adapterVoltage
        s.adapterCurrent = io.adapterCurrent ?? ps.adapterCurrent
        s.adapterName = io.adapterName ?? ps.adapterName
        s.adapterManufacturer = io.adapterManufacturer ?? ps.adapterManufacturer

        s.isCharged = io.isCharged || ps.isCharged
        s.isFinishingCharge = io.isFinishingCharge || ps.isFinishingCharge

        if ps.percent > 0 {
            s.percent = ps.percent
        } else if io.currentCapacityPercent > 0 {
            s.percent = io.currentCapacityPercent
        } else if s.maxCapacityMAh > 0 {
            s.percent = s.currentCapacityMAh / s.maxCapacityMAh * 100
        }
        s.percent = min(max(s.percent, 0), 100)

        s.state = resolveState(io: io, ps: ps, isPresent: s.isPresent)

        // 功率：优先电池电气参数；电量计为 0 时使用系统遥测 BatteryPower。
        if io.current != 0 {
            s.current = io.current
        } else if io.telemetryBatteryPowerMW != 0 {
            let magnitude = abs(io.telemetryBatteryPowerMW) / 1000
            let sign: Double = (s.state == .charging) ? 1 : -1
            s.telemetryPowerW = sign * magnitude
            if s.voltage > 0 {
                s.current = s.telemetryPowerW! / s.voltage
            }
        } else {
            s.current = ps.current
        }
        // 系统功耗与适配器输入取值：
        // 1. 有可靠适配器总输入（SystemPowerIn）且电池非放电时，
        //    用"总输入 − 充电功率"得到一致的系统直供估算（放电时 SystemPowerIn 含电池
        //    补充的电量，直接使用会让"系统功耗"偏低）；
        // 2. 否则优先 SystemLoad（系统自身消耗，不含电池充电）；
        // 3. 电池供电时取放电功率；
        // 4. 均不可用时，仅在供电方式未变化时沿用上次值，
        //    避免拔电后显示陈旧的适配器功耗。
        let resolved = Self.resolvedSystemPowerW(
            systemLoadMW: io.telemetrySystemLoadMW,
            adapterConnected: s.adapterConnected,
            state: s.state,
            systemPowerInMW: io.telemetrySystemPowerMW,
            chargingPowerW: s.chargingPowerW,
            telemetryBatteryPowerMW: io.telemetryBatteryPowerMW,
            electricalPowerW: s.power,
            previous: snapshot.systemPowerW,
            previousAdapterConnected: snapshot.adapterConnected
        )
        s.systemPowerW = resolved.systemPowerW
        s.adapterInputPowerW = resolved.adapterInputPowerW

        if settings.powerDiagnosticsLoggingEnabled {
            PowerDiagnosticsLogger.shared.record(
                PowerDiagnosticsSample(
                    timestamp: s.timestamp,
                    state: s.state,
                    adapterConnected: s.adapterConnected,
                    isCharging: io.isCharging,
                    batteryVoltageV: s.voltage,
                    batteryCurrentA: s.current,
                    batteryPowerW: s.power,
                    telemetryBatteryPowerW: io.telemetryBatteryPowerMW.nilIfZero.map { $0 / 1000 },
                    systemPowerInW: io.telemetrySystemPowerMW.nilIfZero.map { $0 / 1000 },
                    systemLoadW: io.telemetrySystemLoadMW.nilIfZero.map { $0 / 1000 },
                    systemVoltageInV: io.telemetrySystemVoltageInMV.nilIfZero.map { $0 / 1000 },
                    systemCurrentInA: io.telemetrySystemCurrentInMA.nilIfZero.map { $0 / 1000 },
                    adapterWatts: s.adapterWatts,
                    adapterVoltageV: s.adapterVoltage,
                    adapterCurrentA: s.adapterCurrent,
                    snapshotSystemPowerW: s.systemPowerW,
                    chargingPowerW: s.chargingPowerW,
                    directSupplyPowerW: s.directSupplyPowerW,
                    adapterOutputPowerW: s.adapterOutputPowerW,
                    consumptionPowerW: s.consumptionPowerW
                )
            )
        }

        s.timeRemaining = estimateTimeRemaining(for: s, io: io, ps: ps)

        snapshot = s
        recordPowerSample(s)
        checkLowBattery(s)

        NotificationCenter.default.post(
            name: .batterySnapshotUpdated,
            object: self,
            userInfo: ["snapshot": s]
        )
    }

    // MARK: - 状态解析

    private func resolveState(io: SmartBatteryData, ps: PowerSourcesData, isPresent: Bool) -> PowerState {
        let external = io.externalConnected || ps.externalConnected
        let charging = io.isCharging || ps.isCharging
        let finishing = io.isFinishingCharge || ps.isFinishingCharge
        let batteryCurrent = io.current != 0 ? io.current : ps.current

        if external {
            if charging || finishing {
                return .charging
            }
            if batteryCurrent < -0.01 {
                return .discharging
            }
            return .pluggedIn
        }
        if isPresent {
            return .discharging
        }
        return .unknown
    }

    private func estimateTimeRemaining(for s: BatterySnapshot, io: SmartBatteryData, ps: PowerSourcesData) -> TimeInterval? {
        switch s.state {
        case .discharging:
            if let t = ps.timeToEmpty, t > 0 { return t }
            let estimate = IOPSGetTimeRemainingEstimate()
            if estimate > 0 { return estimate }
            if s.current < -0.01, s.currentCapacityMAh > 0 {
                return (s.currentCapacityMAh / 1000.0) / abs(s.current) * 3600.0
            }
        case .charging:
            if let t = ps.timeToFull, t > 0 { return t }
            if s.current > 0.01, s.maxCapacityMAh > 0 {
                let missing = max(0, s.maxCapacityMAh - s.currentCapacityMAh) / 1000.0
                return missing / s.current * 3600.0
            }
        case .pluggedIn, .unknown:
            break
        }
        return nil
    }

    // MARK: - 低电量提醒

    private func checkLowBattery(_ s: BatterySnapshot) {
        guard settings.lowBatteryNotificationsEnabled, s.state == .discharging else {
            lowBatteryNotified = false
            return
        }
        if s.percent <= settings.lowBatteryThreshold {
            if !lowBatteryNotified {
                lowBatteryNotified = true
                NotificationService.shared.sendLowBattery(percent: s.percent, threshold: settings.lowBatteryThreshold)
            }
        } else if s.percent > settings.lowBatteryThreshold + 5 {
            lowBatteryNotified = false
        }
    }

    private func recordPowerSample(_ s: BatterySnapshot) {
        guard let sample = PowerSample(snapshot: s) else { return }
        recentPower.append(sample)
        if recentPower.count > recentSampleLimit {
            recentPower.removeFirst(recentPower.count - recentSampleLimit)
        }
    }

    // MARK: - IOKit 读取

    struct PowerSourcesData {
        var isPresent = false
        var percent = 0.0
        var currentCapacityMAh = 0.0
        var maxCapacityMAh = 0.0
        var designCapacityMAh = 0.0
        var cycleCount = 0
        var voltage = 0.0
        var current = 0.0
        var timeToEmpty: TimeInterval?
        var timeToFull: TimeInterval?
        var externalConnected = false
        var isCharging = false
        var isCharged = false
        var isFinishingCharge = false
        var temperatureCelsius: Double?
        var healthPercent: Double?
        var adapterWatts: Double?
        var adapterVoltage: Double?
        var adapterCurrent: Double?
        var adapterName: String?
        var adapterManufacturer: String?
    }

    /// IOPS 当前供电状态（`IOPSGetProvidingPowerSourceType` 的取值）。
    ///
    /// 从 MacBook 物理层面看只有两种电源：充电器（适配器供电）与内置电池（电池供电）。
    /// `ups` 是 macOS 系统层的第三种状态：当智能 UPS 直连电脑并被系统识别为供电来源时，
    /// 系统会报告 UPS 供电（典型场景是市电断电后由 UPS 电池顶班）。此时消耗的是 UPS
    /// 电池，笔记本电池并不放电，因此仍视为外部供电。
    enum IOPSPowerSourceState: String {
        case ac
        case battery
        case ups

        init?(rawIOPSValue: String) {
            switch rawIOPSValue {
            case kIOPMACPowerKey: self = .ac
            case kIOPMBatteryPowerKey: self = .battery
            case kIOPMUPSPowerKey: self = .ups
            default: return nil
            }
        }

        /// 是否视为外部供电（不消耗笔记本电池）。
        /// AC 与 UPS 供电时笔记本电池都不放电，仅 Battery 供电时才消耗笔记本电池。
        var isExternalPower: Bool {
            self != .battery
        }
    }

    private func readPowerSources() -> PowerSourcesData {
        var data = PowerSourcesData()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else {
            return data
        }
        // CFArray 到 [AnyObject] 的桥接恒成功，无需条件转换。
        let sources = list as [AnyObject]

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            guard Self.boolValue(description[kIOPSIsPresentKey as String]) else { continue }

            data = Self.parsePowerSourceDescription(description, initial: data)
            break
        }

        // externalConnected 判定分两步：
        // 1. 单个电源描述：kIOPSPowerSourceStateKey 取值只有 AC/Battery/Off Line，
        //    仅 AC Power 记为外部供电（见 parsePowerSourceDescription）。
        // 2. 当前供电来源：UPS 不在上述取值里，需用 IOPSGetProvidingPowerSourceType
        //    检测（返回 AC/Battery/UPS）。该结果比单描述更权威——UPS 供电时笔记本电池
        //    不放电，视为外部供电；Battery Power 时即使描述里状态缺失也判为非外部供电。
        if let providing = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?,
           let state = IOPSPowerSourceState(rawIOPSValue: providing) {
            data.externalConnected = state.isExternalPower
        }

        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            data = Self.applyAdapterDetails(adapter, to: data)
        }
        return data
    }

    /// 解析 IOPS 电源描述字典。提取为 static 以便单元测试。
    static func parsePowerSourceDescription(
        _ description: [String: Any],
        initial: PowerSourcesData = PowerSourcesData()
    ) -> PowerSourcesData {
        var data = initial
        data.isPresent = true
        let current = Self.numberValue(description[kIOPSCurrentCapacityKey as String])
        let maximum = Self.numberValue(description[kIOPSMaxCapacityKey as String])
        data.currentCapacityMAh = current
        data.maxCapacityMAh = maximum
        if maximum > 0 {
            data.percent = current / maximum * 100
        }
        data.designCapacityMAh = Self.numberValue(description[kIOPSDesignCapacityKey as String])
        data.voltage = Self.numberValue(description[kIOPSVoltageKey as String]) / 1000
        data.current = Self.numberValue(description[kIOPSCurrentKey as String]) / 1000
        data.timeToEmpty = Self.positiveTime(description[kIOPSTimeToEmptyKey as String])
        data.timeToFull = Self.positiveTime(description[kIOPSTimeToFullChargeKey as String])
        // IOPS 没有 ExternalConnected 键，用 Power Source State 判断是否接入交流电源。
        data.externalConnected = (description[kIOPSPowerSourceStateKey as String] as? String) == kIOPSACPowerValue
        data.isCharging = Self.boolValue(description[kIOPSIsChargingKey as String])
        data.isCharged = Self.boolValue(description[kIOPSIsChargedKey as String])
        data.isFinishingCharge = Self.boolValue(description[kIOPSIsFinishingChargeKey as String])
        return data
    }

    /// 解析 IOPS 外部电源适配器信息。提取为 static 以便单元测试。
    static func applyAdapterDetails(
        _ adapter: [String: Any],
        to data: PowerSourcesData = PowerSourcesData()
    ) -> PowerSourcesData {
        var data = data
        data.adapterWatts = Self.numberValue(adapter[kIOPSPowerAdapterWattsKey as String]).nilIfZero
        // kIOPSPowerAdapterCurrentKey 单位为 mA，与 SmartBattery 路径一致转换为 A。
        data.adapterCurrent = Self.numberValue(adapter[kIOPSPowerAdapterCurrentKey as String])
            .nilIfZero
            .map { $0 / 1000 }
        return data
    }

    nonisolated static func resolvedMaxCapacity(
        powerSourcesMaximum: Double,
        smartBatteryFullCharge: Double
    ) -> Double {
        if powerSourcesMaximum.isFinite, powerSourcesMaximum > 0 {
            return powerSourcesMaximum
        }
        if smartBatteryFullCharge.isFinite, smartBatteryFullCharge > 0 {
            return smartBatteryFullCharge
        }
        return 0
    }

    nonisolated static func dischargingSystemPowerW(
        telemetryBatteryPowerMW: Double,
        electricalPowerW: Double
    ) -> Double? {
        if telemetryBatteryPowerMW.isFinite, telemetryBatteryPowerMW < 0 {
            return abs(telemetryBatteryPowerMW) / 1000
        }
        if electricalPowerW.isFinite, electricalPowerW < -0.01 {
            return abs(electricalPowerW)
        }
        return nil
    }

    /// 计算系统功耗与适配器总输入（提取为纯函数便于单元测试）。
    ///
    /// 返回值：
    /// - `adapterInputPowerW`：仅在接入适配器且存在 SystemPowerIn 遥测时非 nil；
    /// - `systemPowerW`：优先取"适配器输入 − 充电功率"（电池非放电时），
    ///   其次 SystemLoad，再次电池放电功率，最后仅在供电方式未变化时沿用上次值。
    ///
    /// 放电状态下不使用适配器总输入覆盖：此时 SystemPowerIn 包含了电池补充的电量，
    /// 直接用会让"系统功耗"偏低，应改用 SystemLoad 或电池放电功率。
    nonisolated static func resolvedSystemPowerW(
        systemLoadMW: Double,
        adapterConnected: Bool,
        state: PowerState,
        systemPowerInMW: Double,
        chargingPowerW: Double?,
        telemetryBatteryPowerMW: Double,
        electricalPowerW: Double,
        previous: Double?,
        previousAdapterConnected: Bool
    ) -> (systemPowerW: Double?, adapterInputPowerW: Double?) {
        let adapterInput = adapterConnected && systemPowerInMW > 0
            ? systemPowerInMW / 1000
            : nil

        if let adapterInput, state != .discharging {
            return (max(0, adapterInput - (chargingPowerW ?? 0)), adapterInput)
        }
        if systemLoadMW > 0 {
            return (systemLoadMW / 1000, adapterInput)
        }
        if let dischargingPower = dischargingSystemPowerW(
            telemetryBatteryPowerMW: telemetryBatteryPowerMW,
            electricalPowerW: electricalPowerW
        ) {
            return (dischargingPower, adapterInput)
        }
        // 供电方式变化时不沿用旧值，避免拔电/接电后显示陈旧的功耗值。
        let retained = previousAdapterConnected == adapterConnected ? previous : nil
        return (retained, adapterInput)
    }

    private struct SmartBatteryData {
        var batteryInstalled = false
        var externalConnected = false
        var isCharging = false
        var isCharged = false
        var isFinishingCharge = false
        var cycleCount = 0
        var designCapacityMAh = 0.0
        var fullChargeCapacityMAh = 0.0
        var currentCapacityMAh = 0.0
        var maxCapacityMAh = 0.0
        var currentCapacityPercent = 0.0
        var voltage = 0.0
        var current = 0.0
        var temperatureCelsius: Double?
        var telemetryBatteryPowerMW = 0.0
        var telemetrySystemPowerMW = 0.0
        var telemetrySystemLoadMW = 0.0
        var telemetrySystemVoltageInMV = 0.0
        var telemetrySystemCurrentInMA = 0.0
        var adapterWatts: Double?
        var adapterVoltage: Double?
        var adapterCurrent: Double?
        var adapterName: String?
        var adapterManufacturer: String?

        var healthPercent: Double? {
            guard designCapacityMAh > 0, fullChargeCapacityMAh > 0 else { return nil }
            return min(max(fullChargeCapacityMAh / designCapacityMAh * 100, 0), 120)
        }
    }

    private func readSmartBattery() -> SmartBatteryData {
        var data = SmartBatteryData()
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return data }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return data
        }

        data.batteryInstalled = Self.boolValue(dict["BatteryInstalled"])
        data.externalConnected = Self.boolValue(dict["ExternalConnected"])
        data.isCharging = Self.boolValue(dict["IsCharging"])
        data.isCharged = Self.boolValue(dict["FullyCharged"])
        data.isFinishingCharge = Self.boolValue(dict["IsFinishingCharge"])
        data.cycleCount = Self.intValue(dict["CycleCount"])
        data.voltage = Self.numberValue(dict["Voltage"]) / 1000
        data.current = Self.numberValue(dict["InstantAmperage"]) / 1000
        if let temperature = Self.numberValue(dict["Temperature"]).nilIfZero {
            data.temperatureCelsius = temperature / 100
        }

        if let battery = dict["BatteryData"] as? [String: Any] {
            data.designCapacityMAh = Self.numberValue(battery["DesignCapacity"])
            data.fullChargeCapacityMAh = Self.numberValue(battery["FullChargeCapacity"])
            data.currentCapacityMAh = Self.numberValue(battery["RemainingCapacity"])
            data.currentCapacityPercent = Self.numberValue(battery["CurrentCapacity"])
        }

        if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
            data.telemetryBatteryPowerMW = Self.signedMW(telemetry["BatteryPower"])
            data.telemetrySystemPowerMW = Self.numberValue(telemetry["SystemPowerIn"])
            data.telemetrySystemLoadMW = Self.numberValue(telemetry["SystemLoad"])
            data.telemetrySystemVoltageInMV = Self.numberValue(telemetry["SystemVoltageIn"])
            data.telemetrySystemCurrentInMA = Self.numberValue(telemetry["SystemCurrentIn"])
        }

        if let adapter = dict["AdapterDetails"] as? [String: Any] {
            data.adapterWatts = Self.numberValue(adapter["Watts"]).nilIfZero
            data.adapterVoltage = Self.numberValue(adapter["AdapterVoltage"]).nilIfZero.map { $0 / 1000 }
            data.adapterCurrent = Self.numberValue(adapter["Current"]).nilIfZero.map { $0 / 1000 }
            data.adapterName = adapter["Name"] as? String
            data.adapterManufacturer = adapter["Manufacturer"] as? String
        }
        return data
    }

    // MARK: - CFNumber/CFBoolean 桥接

    private static func numberValue(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func intValue(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    /// PowerTelemetryData 中的功率为带符号 64 位整数（mW），
    /// 负值在 CFNumber 中表现为无符号位模式，需要按位转换回有符号。
    private static func signedMW(_ value: Any?) -> Double {
        guard let number = value as? NSNumber else { return 0 }
        let raw = number.uint64Value
        return Double(Int64(bitPattern: raw))
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func positiveTime(_ value: Any?) -> TimeInterval? {
        let time = (value as? NSNumber)?.doubleValue ?? -1
        return time > 0 ? time : nil
    }
}
