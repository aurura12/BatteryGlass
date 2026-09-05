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
    private var lastAdapterConnected: Bool?
    private let recentSampleLimit = 420

    // MARK: - 「充满还需 / 剩余时间」估算状态

    /// 充电速率滚动追踪：记录爬升点，在系统估计缺失时给出实测充速（%/s）。
    private var chargeRateTracker = ChargeRateTracker()
    /// 估算秒值平滑器：抑制 2Hz 跳变，状态切换即复位。
    private var timeRemainingSmoother = TimeRemainingSmoother()

    // MARK: - 待机（睡眠）监听状态

    /// 睡眠前基线：日期、电量、电压、供电状态及累计遥测计数。
    private var sleepBaseline: (
        date: Date,
        capacityMAh: Double,
        voltageV: Double,
        adapterConnected: Bool,
        state: PowerState,
        telemetryCounters: PowerTelemetryCounters
    )?
    /// 唤醒瞬间基线：睡眠结束瞬间的数据，用于计数器差值和回退计算。
    private var wakeBaseline: (
        date: Date,
        capacityMAh: Double,
        voltageV: Double,
        adapterConnected: Bool,
        telemetryCounters: PowerTelemetryCounters
    )?
    /// 唤醒后延迟采样得到的直供功率样本（W）。
    private var maintenanceSamples: [Double] = []
    private var maintenanceSampleTick = 0
    private var maintenanceTimer: Timer?
    private let maintenanceSampleInterval: TimeInterval = 5
    private let maintenanceSampleCount = 6
    private var latestTelemetryCounters = PowerTelemetryCounters(accumulatedWallEnergyEstimate: nil)

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

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillSleep()
            }
        }
        workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidWake()
            }
        }
    }

    func refresh() {
        let io = readSmartBattery()
        let ps = readPowerSources()
        latestTelemetryCounters = io.telemetryCounters

        var s = BatterySnapshot(timestamp: Date())
        s.isPresent = io.batteryInstalled || ps.isPresent

        // 容量字段统一为真 mAh 语义：SmartBattery（gas gauge）在 AS 与 Intel 上
        // 均为真 mAh，优先采用；IOPS 容量键在 Apple Silicon 上是 0-100 归一化值
        // 而非 mAh，仅当量级像真 mAh（>500，如 Intel）且 SmartBattery 缺失时兜底。
        s.currentCapacityMAh = Self.resolvedCapacityMAh(
            powerSources: ps.currentCapacityMAh,
            smartBattery: io.currentCapacityMAh
        )
        s.maxCapacityMAh = Self.resolvedCapacityMAh(
            powerSources: ps.maxCapacityMAh,
            smartBattery: io.fullChargeCapacityMAh
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
        // 遥测功率经 signedMW 解析后自带符号（充电为正、放电为负），直接采用实测
        // 符号，不再按状态猜测，避免瞬时状态错位（如刚插电仍在放电、充满停充微放）
        // 时功率符号显示错误。
        if io.current != 0 {
            s.current = io.current
        } else if io.telemetryBatteryPowerMW != 0 {
            let telemetryPower = io.telemetryBatteryPowerMW / 1000
            s.telemetryPowerW = telemetryPower
            if s.voltage > 0 {
                s.current = telemetryPower / s.voltage
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
            let diagnosticSample = PowerDiagnosticsSample(
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
                consumptionPowerW: s.consumptionPowerW,
                accumulatedWallEnergyEstimate: io.telemetryCounters.accumulatedWallEnergyEstimate
            )
            PowerDiagnosticsLogger.shared.record(diagnosticSample)
        }

        // 充电/放电剩余时间估算：
        // 先记录本拍充电进度（供短窗实测速率外推），再按防御顺序估算——
        // 系统估计（IOPS）优先；充电缺失时用实测充速或真 mAh 缺口；放电缺失时
        // 用真 mAh ÷ 放电电流。估算输入刻意使用 SmartBattery 侧真 mAh
        // （io.*），不读被 IOPS 归一化容量污染的 s.currentCapacityMAh/maxCapacityMAh。
        chargeRateTracker.record(
            percent: s.percent,
            at: s.timestamp,
            isCharging: s.state == .charging
        )
        var estimateInput = TimeRemainingEstimator.Input()
        estimateInput.state = s.state
        estimateInput.percent = s.percent
        estimateInput.isCharged = s.isCharged
        estimateInput.currentCapacityMAh = io.currentCapacityMAh
        estimateInput.fullChargeCapacityMAh = io.fullChargeCapacityMAh
        estimateInput.currentA = s.current
        estimateInput.systemTimeToEmpty = ps.timeToEmpty
        estimateInput.systemTimeToFull = ps.timeToFull
        if s.state == .discharging {
            let iopsEstimate = IOPSGetTimeRemainingEstimate()
            estimateInput.systemEstimateSeconds = (iopsEstimate.isFinite && iopsEstimate > 0) ? iopsEstimate : nil
        }
        estimateInput.chargePercentPerSecond = chargeRateTracker.slopePercentPerSecond(now: s.timestamp)
        s.timeRemaining = timeRemainingSmoother.update(
            raw: TimeRemainingEstimator.estimateSeconds(estimateInput),
            state: s.state
        )

        snapshot = s
        recordPowerSample(s)
        checkLowBattery(s)
        checkAdapterChange(s)

        NotificationCenter.default.post(
            name: .batterySnapshotUpdated,
            object: self,
            userInfo: ["snapshot": s]
        )
    }

    // MARK: - 睡眠/唤醒补测

    /// 系统即将睡眠：记录当前快照作为基线。回调要轻，系统可能随即挂起。
    private func handleWillSleep() {
        // 上次唤醒后 30 秒采样窗口内再次睡眠：丢弃未完成采样，避免生成不完整区间。
        cancelMaintenanceSampling()
        sleepBaseline = (
            date: snapshot.timestamp,
            capacityMAh: snapshot.currentCapacityMAh,
            voltageV: snapshot.voltage,
            adapterConnected: snapshot.adapterConnected,
            state: snapshot.state,
            telemetryCounters: latestTelemetryCounters
        )
    }

    private func handleDidWake() {
        guard sleepBaseline != nil else { return }
        refresh()
        wakeBaseline = (
            date: snapshot.timestamp,
            capacityMAh: snapshot.currentCapacityMAh,
            voltageV: snapshot.voltage,
            adapterConnected: snapshot.adapterConnected,
            telemetryCounters: latestTelemetryCounters
        )
        startMaintenanceSampling()
    }

    /// 唤醒后约 30 秒内每 5 秒采样一次直供功率，取最小值作为系统维持功耗估算。
    private func startMaintenanceSampling() {
        cancelMaintenanceSampling()
        let timer = Timer(timeInterval: maintenanceSampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleMaintenancePower()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
        sampleMaintenancePower()
    }

    private func sampleMaintenancePower() {
        guard maintenanceTimer != nil, sleepBaseline != nil else {
            cancelMaintenanceSampling()
            return
        }
        refresh()
        // 直供功率仅插电场景有意义；不插电（电池供电）时无直供样本也照常推进采样计数，
        // 保证采样窗口能结束并生成放电待机区间。
        if let direct = snapshot.directSupplyPowerW {
            maintenanceSamples.append(max(0, direct))
        }
        maintenanceSampleTick += 1
        if maintenanceSampleTick >= maintenanceSampleCount {
            finalizeSleepSegment()
        }
    }

    private func cancelMaintenanceSampling() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        maintenanceSamples = []
        maintenanceSampleTick = 0
    }

    private func finalizeSleepSegment() {
        guard let baseline = sleepBaseline, let wake = wakeBaseline else {
            cancelMaintenanceSampling()
            sleepBaseline = nil
            wakeBaseline = nil
            return
        }
        let minimumDirectPower = maintenanceSamples.min()
        cancelMaintenanceSampling()
        sleepBaseline = nil
        wakeBaseline = nil

        let input = SleepEnergyCalculator.Input(
            sleepStart: baseline.date,
            capacityBeforeMAh: baseline.capacityMAh,
            voltageBeforeV: baseline.voltageV,
            adapterConnectedBefore: baseline.adapterConnected,
            wakeTime: wake.date,
            capacityAfterMAh: wake.capacityMAh,
            voltageAfterV: wake.voltageV,
            adapterConnectedAfter: wake.adapterConnected,
            maintenanceDirectPowerW: minimumDirectPower,
            powerStateBefore: baseline.state,
            wallEnergyCounterBefore: baseline.telemetryCounters.accumulatedWallEnergyEstimate,
            wallEnergyCounterAfter: wake.telemetryCounters.accumulatedWallEnergyEstimate
        )
        guard let segment = SleepEnergyCalculator.segment(from: input) else { return }

        NotificationCenter.default.post(
            name: .sleepSegmentRecorded,
            object: self,
            userInfo: ["segment": segment]
        )
    }

    // MARK: - 状态解析

    private func resolveState(io: SmartBatteryData, ps: PowerSourcesData, isPresent: Bool) -> PowerState {
        let external = io.externalConnected || ps.externalConnected
        let charging = io.isCharging || ps.isCharging
        let finishing = io.isFinishingCharge || ps.isFinishingCharge
        return Self.resolvedPowerState(
            externalConnected: external,
            isCharging: charging,
            isFinishingCharge: finishing,
            isPresent: isPresent
        )
    }

    /// Resolve the user-facing power source state.
    ///
    /// The external-power signal is the authoritative source for the transition.
    /// Battery current is intentionally not used here: during adapter insertion,
    /// AppleSmartBattery can report the previous negative current for several
    /// refreshes, which otherwise leaves the UI stuck on "battery power".
    nonisolated static func resolvedPowerState(
        externalConnected: Bool,
        isCharging: Bool,
        isFinishingCharge: Bool,
        isPresent: Bool,
        batteryCurrent: Double = 0
    ) -> PowerState {
        if externalConnected {
            return isCharging || isFinishingCharge ? .charging : .pluggedIn
        }
        return isPresent ? .discharging : .unknown
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

    /// 外接电源接入/断开时发送通知（需在设置中开启；首次读取不触发）。
    private func checkAdapterChange(_ s: BatterySnapshot) {
        defer { lastAdapterConnected = s.adapterConnected }
        guard settings.adapterChangeNotificationsEnabled,
              s.isPresent,
              let previous = lastAdapterConnected,
              previous != s.adapterConnected else { return }
        NotificationService.shared.sendAdapterChange(connected: s.adapterConnected, percent: s.percent)
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
        if let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?,
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
        // 注意：Apple Silicon 上 IOPS 的 Current/Max Capacity 是 0-100 归一化值而非
        // mAh（单位不可信）。此处仅暂存原始值，mAh 语义统一发生在 refresh() 的
        // resolvedCapacityMAh（SmartBattery 真值优先、IOPS 仅量级 >500 时兜底）。
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

    /// 统一「当前/满充容量」合并语义：返回值恒为真 mAh。
    /// 背景：Apple Silicon 上 IOPS 的 Current/Max Capacity 是 0-100 归一化值而非 mAh，
    /// 直接存入快照会污染睡眠能耗计量与 HealthKpiCard 文案。策略：
    /// - SmartBattery（gas gauge）在 AS 与 Intel 上均为真 mAh → 优先采用（有限且 >0）；
    /// - IOPS 仅在值 > 500 时视为真 mAh（Intel 且 SmartBattery 缺失时兜底）；
    ///   归一化值 ≤100 一律拒绝，避免污染再次发生。
    nonisolated static func resolvedCapacityMAh(powerSources: Double, smartBattery: Double) -> Double {
        // 真 mAh 保守下界：Mac 电池满充 mAh 恒 >1000；归一化 IOPS 值 ≤100。
        let mAhMagnitudeBound = 500.0
        if smartBattery.isFinite, smartBattery > 0 {
            return smartBattery
        }
        if powerSources.isFinite, powerSources > mAhMagnitudeBound {
            return powerSources
        }
        return 0
    }

    /// 解析电池设计容量（mAh）。
    /// Intel 优先读 `BatteryData["DesignCapacity"]`；Apple Silicon 该键通常缺失，
    /// 回退到顶层 `DesignCapacity` → `NominalChargeCapacity`（提取为纯函数便于单元测试）。
    nonisolated static func resolvedDesignCapacityMAh(
        batteryDesignCapacity: Double,
        topLevelDesignCapacity: Double,
        nominalChargeCapacity: Double
    ) -> Double {
        firstPositive(batteryDesignCapacity, topLevelDesignCapacity, nominalChargeCapacity)
    }

    /// 解析电池当前满充容量（mAh）。
    /// Intel 读 `BatteryData["FullChargeCapacity"]`；Apple Silicon 该键缺失，
    /// 满充容量位于 `BatteryData["FccComp2"]` 或顶层 `AppleRawMaxCapacity`
    /// （提取为纯函数便于单元测试）。
    nonisolated static func resolvedFullChargeCapacityMAh(
        batteryFullChargeCapacity: Double,
        batteryFccComp2: Double,
        topLevelAppleRawMaxCapacity: Double
    ) -> Double {
        firstPositive(batteryFullChargeCapacity, batteryFccComp2, topLevelAppleRawMaxCapacity)
    }

    /// 解析电池当前剩余容量（mAh）。
    /// Intel 读 `BatteryData["RemainingCapacity"]`；Apple Silicon 该键可能缺失，
    /// 剩余容量位于顶层 `AppleRawCurrentCapacity`
    /// （仿 resolvedFullChargeCapacityMAh 键位风格，提取为纯函数便于单元测试）。
    nonisolated static func resolvedCurrentCapacityMAh(
        batteryRemainingCapacity: Double,
        topLevelAppleRawCurrentCapacity: Double
    ) -> Double {
        firstPositive(batteryRemainingCapacity, topLevelAppleRawCurrentCapacity)
    }

    nonisolated private static func firstPositive(_ values: Double...) -> Double {
        values.first { $0.isFinite && $0 > 0 } ?? 0
    }

    nonisolated static func dischargingSystemPowerW(
        telemetryBatteryPowerMW: Double,
        electricalPowerW: Double
    ) -> Double? {
        if electricalPowerW.isFinite, electricalPowerW < -0.01 {
            return abs(electricalPowerW)
        }
        // BatteryPower 在部分 Apple Silicon 机型上会相对 IsCharging 滞后；
        // 只有电气功率不可判定时才使用该遥测回退，避免充电时被误判为放电。
        if telemetryBatteryPowerMW.isFinite, telemetryBatteryPowerMW < 0 {
            return abs(telemetryBatteryPowerMW) / 1000
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
        let adapterInput = adapterConnected && systemPowerInMW.isFinite && systemPowerInMW > 0
            ? systemPowerInMW / 1000
            : nil
        // 充电状态以 IsCharging/电气功率为准，不让滞后的 BatteryPower 覆盖；
        // 已接通但未充电时才允许负功率遥测触发放电回退。
        let batteryIsDischarging = state == .discharging ||
            (state == .pluggedIn && dischargingSystemPowerW(
                telemetryBatteryPowerMW: telemetryBatteryPowerMW,
                electricalPowerW: electricalPowerW
            ) != nil)

        if let adapterInput, state != .discharging, !batteryIsDischarging {
            return (max(0, adapterInput - (chargingPowerW ?? 0)), adapterInput)
        }
        if systemLoadMW.isFinite && systemLoadMW > 0 {
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
        var telemetryCounters = PowerTelemetryCounters(accumulatedWallEnergyEstimate: nil)
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
            // 容量键在 Intel / Apple Silicon 上不一致：Intel 读 BatteryData 内
            // DesignCapacity / FullChargeCapacity / RemainingCapacity；Apple Silicon
            // 缺 FullChargeCapacity，设计容量在顶层 DesignCapacity / NominalChargeCapacity，
            // 满充容量在 BatteryData["FccComp2"] / 顶层 AppleRawMaxCapacity，剩余容量
            // 可能缺 RemainingCapacity，回退顶层 AppleRawCurrentCapacity，见 resolved* 解析函数。
            data.designCapacityMAh = Self.resolvedDesignCapacityMAh(
                batteryDesignCapacity: Self.numberValue(battery["DesignCapacity"]),
                topLevelDesignCapacity: Self.numberValue(dict["DesignCapacity"]),
                nominalChargeCapacity: Self.numberValue(dict["NominalChargeCapacity"])
            )
            data.fullChargeCapacityMAh = Self.resolvedFullChargeCapacityMAh(
                batteryFullChargeCapacity: Self.numberValue(battery["FullChargeCapacity"]),
                batteryFccComp2: Self.numberValue(battery["FccComp2"]),
                topLevelAppleRawMaxCapacity: Self.numberValue(dict["AppleRawMaxCapacity"])
            )
            data.currentCapacityMAh = Self.resolvedCurrentCapacityMAh(
                batteryRemainingCapacity: Self.numberValue(battery["RemainingCapacity"]),
                topLevelAppleRawCurrentCapacity: Self.numberValue(dict["AppleRawCurrentCapacity"])
            )
            data.currentCapacityPercent = Self.numberValue(battery["CurrentCapacity"])
        }

        if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
            data.telemetryBatteryPowerMW = Self.signedMW(telemetry["BatteryPower"])
            data.telemetrySystemPowerMW = Self.numberValue(telemetry["SystemPowerIn"])
            data.telemetrySystemLoadMW = Self.numberValue(telemetry["SystemLoad"])
            data.telemetrySystemVoltageInMV = Self.numberValue(telemetry["SystemVoltageIn"])
            data.telemetrySystemCurrentInMA = Self.numberValue(telemetry["SystemCurrentIn"])
            data.telemetryCounters = Self.parsePowerTelemetryCounters(telemetry)
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

    nonisolated static func parsePowerTelemetryCounters(_ telemetry: [String: Any]) -> PowerTelemetryCounters {
        PowerTelemetryCounters(
            accumulatedWallEnergyEstimate: (telemetry["AccumulatedWallEnergyEstimate"] as? NSNumber)
                .map(\.uint64Value)
        )
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
        // IOPS 的 Time to Empty / Time to Full Charge 单位是分钟，内部统一使用秒。
        return time > 0 ? time * 60 : nil
    }
}
