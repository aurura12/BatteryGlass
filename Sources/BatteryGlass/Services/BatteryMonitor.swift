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
        s.maxCapacityMAh = ps.maxCapacityMAh
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
        // 系统直供：SystemLoad = 系统自身消耗（不含电池充电），充电时也不会虚高；
        // 旧设备无 SystemLoad 时回退：适配器输入 - 充电功率；电池供电时取放电功率。
        if io.telemetrySystemLoadMW > 0 {
            s.systemPowerW = io.telemetrySystemLoadMW / 1000
        } else if s.adapterConnected, io.telemetrySystemPowerMW > 0 {
            let chargeW = s.chargingPowerW ?? 0
            s.systemPowerW = max(0, io.telemetrySystemPowerMW / 1000 - chargeW)
        } else if s.state == .discharging, io.telemetryBatteryPowerMW < 0 {
            s.systemPowerW = abs(io.telemetryBatteryPowerMW) / 1000
        } else {
            s.systemPowerW = snapshot.systemPowerW
        }

        if s.adapterConnected, io.telemetrySystemPowerMW > 0 {
            s.adapterInputPowerW = io.telemetrySystemPowerMW / 1000
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
        let sample = PowerSample(timestamp: s.timestamp, power: s.power, percent: s.percent)
        recentPower.append(sample)
        if recentPower.count > recentSampleLimit {
            recentPower.removeFirst(recentPower.count - recentSampleLimit)
        }
    }

    // MARK: - IOKit 读取

    private struct PowerSourcesData {
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

    private func readPowerSources() -> PowerSourcesData {
        var data = PowerSourcesData()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue(),
              let sources = list as? [AnyObject] else {
            return data
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            guard Self.boolValue(description[kIOPSIsPresentKey as String]) else { continue }

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
            data.isCharging = Self.boolValue(description[kIOPSIsChargingKey as String])
            data.isCharged = Self.boolValue(description[kIOPSIsChargedKey as String])
            data.isFinishingCharge = Self.boolValue(description[kIOPSIsFinishingChargeKey as String])
            break
        }

        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            data.adapterWatts = Self.numberValue(adapter[kIOPSPowerAdapterWattsKey as String]).nilIfZero
            data.adapterCurrent = Self.numberValue(adapter[kIOPSPowerAdapterCurrentKey as String]).nilIfZero
        }
        return data
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
