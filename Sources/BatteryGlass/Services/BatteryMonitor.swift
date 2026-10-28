import AppKit
import IOKit
import IOKit.ps
import Observation
import OSLog

@MainActor
@Observable
final class BatteryMonitor {
    /// 供界面消费的快照。只有「界面真的看得见」或菜单栏需要刷新时才更新，
    /// 详见 `shouldPublish` 与 `setPanelVisible(_:)`。
    private(set) var snapshot = BatterySnapshot()
    private(set) var recentPower: [PowerSample] = []

    /// 内部最新快照：每个采样周期都会更新，历史记录、诊断日志、睡眠结算与状态判定
    /// 一律读它，因此降低界面发布频率不会丢数据。
    @ObservationIgnored private var latest = BatterySnapshot()
    /// 界面的发布节流。`latest` 每拍都变，`snapshot` 只在有意义的字段变化时才跟。
    @ObservationIgnored private var lastPublishAt = Date.distantPast
    /// 面板（MenuBarExtra 窗口）是否真正在屏幕上，由 `PanelVisibilityObserver` 上报。
    @ObservationIgnored private var panelVisible = false
    /// 桌面小组件窗口是否在屏幕上，由 `DesktopWidgetController` 上报。
    @ObservationIgnored private var desktopWidgetVisible = false

    /// 可见时的采样间隔：面板/小组件在屏幕上，2 Hz 保持数值平滑。
    nonisolated static let activeRefreshInterval: TimeInterval = 0.5
    /// 不可见时的采样间隔：历史是 5 秒一条，1 Hz 已经把界面驱动降到最低而数据无损。
    nonisolated static let idleRefreshInterval: TimeInterval = 1.0
    /// 仅桌面小组件可见时的最低发布间隔（小组件带毛玻璃材质，重绘成本不低）。
    nonisolated static let widgetRefreshInterval: TimeInterval = 1.0
    /// 不可见时仍定期发布一次，兜底视图里与时间相关的文案（剩余时间等）。
    nonisolated static let hiddenPublishHeartbeat: TimeInterval = 30

    private let settings: AppSettings
    private let telemetryCalibrationStore: PowerTelemetryCalibrationStore
    /// 以下资源只在主线程创建/修改，但 `deinit` 是 nonisolated：用 `nonisolated(unsafe)`
    /// 允许销毁时撤销它们（否则实例释放后定时器仍会空转、观察者永久驻留）。
    private nonisolated(unsafe) var timer: Timer?
    /// NSWorkspace 睡眠/唤醒观察者，销毁时成对移除。
    private nonisolated(unsafe) var workspaceObservers: [NSObjectProtocol] = []
    private var lowBatteryNotified = false
    private var lastAdapterConnected: Bool?
    private var pluggedDischargeConfirmation = BatteryDischargeConfirmation()
    private var powerDisplayTransition = PowerDisplayTransition()
    private let recentSampleLimit = 420
    /// 每拍都追加的原始功率环形缓冲；`recentPower` 只在发布时与它同步一次。
    @ObservationIgnored private var powerBuffer: [PowerSample] = []

    /// 睡眠/唤醒补测的诊断通道。睡眠窗口没有实时采样，只能靠这几个端点值人工核对
    /// （用 `./script/build_and_run.sh --telemetry` 跟随）。
    private static let sleepLogger = Logger(subsystem: "com.batteryglass.app", category: "Sleep")

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
        batteryDischargingBefore: Bool,
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
    /// 已开始但尚未关闭的睡眠区间。与 `sleepBaseline` 分开保存：基线读数不可用时
    /// 仍必须在唤醒后关闭区间，否则历史层会把之后的样本全部当成睡眠排除掉。
    private var sleepIntervalStart: Date?
    /// 唤醒端点读数不可用时的补采任务与已尝试次数。
    private nonisolated(unsafe) var wakeValidationTask: Task<Void, Never>?
    private var wakeValidationAttempts = 0
    /// 唤醒后电量计可能仍停在旧值，最多重试 5 次、每次间隔 2 秒。
    private let wakeValidationInterval: TimeInterval = 2
    private let wakeValidationMaxAttempts = 5
    /// 唤醒后延迟采样得到的直供功率样本（W）。
    private var maintenanceSamples: [Double] = []
    /// 唤醒后延迟采样得到的适配器总输入样本（W）。
    private var maintenanceAdapterInputSamples: [Double] = []
    private var maintenanceSampleTick = 0
    private nonisolated(unsafe) var maintenanceTimer: Timer?
    private let maintenanceSampleInterval: TimeInterval = 5
    private let maintenanceSampleCount = 6
    private var latestTelemetryCounters = PowerTelemetryCounters(accumulatedWallEnergyEstimate: nil)

    /// 当前累计墙上能量计数器原始值，供设置页校准会话读取；机型不提供时为 nil。
    /// 读取 `latestTelemetryCounters`（`@Observable` 存储属性），随采样自动驱动视图刷新。
    var currentWallEnergyCounter: UInt64? {
        latestTelemetryCounters.accumulatedWallEnergyEstimate
    }

    init(
        settings: AppSettings,
        telemetryCalibrationStore: PowerTelemetryCalibrationStore? = nil
    ) {
        self.settings = settings
        self.telemetryCalibrationStore = telemetryCalibrationStore ?? PowerTelemetryCalibrationStore()
        refresh()
        scheduleRefreshTimer(interval: Self.idleRefreshInterval)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleWillSleep()
                }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleDidWake()
                }
            }
        )
    }

    /// 定时器挂在主 RunLoop 上、观察者由通知中心持有：不主动释放会让实例销毁后
    /// 仍留下 1 Hz 空转与永久回调（对测试与实例重建尤其明显）。
    deinit {
        timer?.invalidate()
        maintenanceTimer?.invalidate()
        wakeValidationTask?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
    }

    // MARK: - 采样节拍与界面可见性

    /// 按当前是否需要高频界面更新重建采样定时器。
    ///
    /// 定时器带 `tolerance`：2 Hz 本身对数据没有精度要求，允许系统把唤醒和其它
    /// 定时器合并，减少 standby 期间的 package 唤醒次数。
    private func scheduleRefreshTimer(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // 定时器挂在主 RunLoop 上，回调必定在主线程；用 assumeIsolated 省掉
            // 每拍一次的 Task 分配与 actor 跳转。
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 界面刷新档位：决定采样与发布节拍。
    ///
    /// 三档的取舍来自实测：面板打开时需要数值平滑（2 Hz）；桌面小组件挂在桌面上、
    /// 只看一眼，1 Hz 足够；两者都不在屏幕上时完全没有理由按帧刷新，只在内容变化时发布。
    nonisolated enum UIPublishMode: Equatable {
        /// 菜单栏弹窗在屏幕上：每拍都发布。
        case live
        /// 仅桌面小组件在屏幕上：最多每秒发布一次（小组件带毛玻璃材质，重绘不便宜）。
        case widget
        /// 界面上什么都不在：只在菜单栏相关字段变化时发布。
        case background
    }

    private var publishMode: UIPublishMode {
        if panelVisible { return .live }
        if desktopWidgetVisible { return .widget }
        return .background
    }

    private var samplingInterval: TimeInterval {
        panelVisible ? Self.activeRefreshInterval : Self.idleRefreshInterval
    }

    /// 面板（菜单栏弹窗）可见性变化。由 `PanelVisibilityObserver` 上报。
    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        handleVisibilityChange()
    }

    /// 桌面小组件可见性变化。由 `DesktopWidgetController` 上报。
    func setDesktopWidgetVisible(_ visible: Bool) {
        guard desktopWidgetVisible != visible else { return }
        desktopWidgetVisible = visible
        handleVisibilityChange()
    }

    private func handleVisibilityChange() {
        // 变可见时立刻用最新内部快照刷一次，避免面板打开后先显示一拍旧值；
        // 变不可见时无需额外动作，下一次 `shouldPublish` 自然会拒绝发布。
        if publishMode != .background { publish(latest) }
        scheduleRefreshTimer(interval: samplingInterval)
    }

    /// 决定这一拍的内部快照要不要同步给界面。
    ///
    /// 面板离屏时 SwiftUI 仍会完整重算视图图，因此「采样频率」不能等于「界面刷新频率」。
    /// 背景档只在用户看得见的东西变化时发布：菜单栏的百分比 / 供电状态 / 剩余时间文本、
    /// 以及插拔电源这类状态跃迁；另加一个低频心跳兜底。
    nonisolated static func shouldPublish(
        previous: BatterySnapshot,
        next: BatterySnapshot,
        mode: UIPublishMode,
        menuBarMode: MenuBarDisplayMode,
        secondsSinceLastPublish: TimeInterval,
        heartbeat: TimeInterval = hiddenPublishHeartbeat
    ) -> Bool {
        switch mode {
        case .live:
            return true
        case .widget:
            // 毛玻璃小组件只在真正显示的内容变化时才重绘，最多每秒一次。
            // 不足一秒时仍走下面的判定，让插拔/百分比跃迁立即跟上。
            if secondsSinceLastPublish >= widgetRefreshInterval,
               Self.widgetDisplayChanged(previous: previous, next: next) {
                return true
            }
        case .background:
            break
        }
        if secondsSinceLastPublish >= heartbeat { return true }
        if previous.isPresent != next.isPresent { return true }
        if previous.state != next.state { return true }
        if previous.adapterConnected != next.adapterConnected { return true }
        if previous.displayState != next.displayState { return true }
        if previous.powerDisplayStatus != next.powerDisplayStatus { return true }
        // 菜单栏百分比图标与文字都只依赖整数百分比。
        if previous.percentText != next.percentText { return true }
        if menuBarMode == .timeRemaining {
            let previousText = BatteryFormatters.menuBarTimeRemaining(previous.displayTimeRemaining)
            let nextText = BatteryFormatters.menuBarTimeRemaining(next.displayTimeRemaining)
            if previousText != nextText { return true }
        }
        return false
    }

    /// 桌面小组件实际渲染的字段（百分比、状态、功率与剩余时间文本等）。
    /// 只有这些内容变化才值得重绘一次毛玻璃卡片；待机时功率与百分比不动，
    /// 就不该跟着每秒采样重新布局。
    nonisolated static func widgetDisplayChanged(
        previous: BatterySnapshot,
        next: BatterySnapshot
    ) -> Bool {
        if previous.percentText != next.percentText { return true }
        if previous.displayState != next.displayState { return true }
        if previous.powerDisplayStatus != next.powerDisplayStatus { return true }
        if previous.displayPowerText != next.displayPowerText { return true }
        if previous.adapterConnected != next.adapterConnected { return true }
        if previous.adapterWatts != next.adapterWatts { return true }
        if previous.healthText != next.healthText { return true }
        if previous.cycleCount != next.cycleCount { return true }
        let previousTime = BatteryFormatters.menuBarTimeRemaining(previous.displayTimeRemaining)
        let nextTime = BatteryFormatters.menuBarTimeRemaining(next.displayTimeRemaining)
        return previousTime != nextTime
    }

    private func publish(_ s: BatterySnapshot) {
        lastPublishAt = s.timestamp
        snapshot = s
        // 面板关闭时 recentPower 没有消费者（实时页已冻结），赋值只会让
        // 下一次 append 多拷一份缓冲，并让离屏视图继续建立观察依赖。
        if panelVisible {
            recentPower = powerBuffer
        }
    }

    private func publishIfNeeded(_ s: BatterySnapshot) {
        let elapsed = s.timestamp.timeIntervalSince(lastPublishAt)
        guard Self.shouldPublish(
            previous: snapshot,
            next: s,
            mode: publishMode,
            menuBarMode: settings.menuBarDisplayMode,
            secondsSinceLastPublish: elapsed
        ) else { return }
        publish(s)
    }

    func refresh() {
        let io = readSmartBattery()
        let ps = readPowerSources()
        if io.telemetryCounters != latestTelemetryCounters {
            latestTelemetryCounters = io.telemetryCounters
        }

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
        s.batteryDischargingWhilePlugged = pluggedDischargeConfirmation.update(
            adapterConnected: s.adapterConnected,
            state: s.state,
            batteryPowerW: s.power
        )
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
            previous: latest.systemPowerW,
            previousAdapterConnected: latest.adapterConnected,
            batteryDischargingWhilePlugged: s.batteryDischargingWhilePlugged
        )
        s.systemPowerW = resolved.systemPowerW
        s.adapterInputPowerW = resolved.adapterInputPowerW
        s.powerDisplayStatus = powerDisplayTransition.update(
            snapshot: s,
            batteryUpdateTime: io.batteryUpdateTime
        )

        if settings.powerDiagnosticsLoggingEnabled {
            let diagnosticSample = PowerDiagnosticsSample(
                timestamp: s.timestamp,
                state: s.state,
                adapterConnected: s.adapterConnected,
                isCharging: io.isCharging,
                batteryVoltageV: s.voltage,
                batteryCurrentA: s.current,
                batteryPowerW: s.power,
                batteryDischargePowerW: s.batteryDischargePowerW,
                batteryDischargingWhilePlugged: s.batteryDischargingWhilePlugged,
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

        latest = s
        // 历史、诊断与状态判定都消费上面这条通知，因此界面发布可以独立节流。
        recordPowerSample(s)
        checkLowBattery(s)
        checkAdapterChange(s)
        publishIfNeeded(s)

        NotificationCenter.default.post(
            name: .batterySnapshotUpdated,
            object: self,
            userInfo: ["snapshot": s]
        )
    }

    // MARK: - 睡眠/唤醒补测

    /// 保存或退出前，使用已采集的端点和维持功率结算一次；不等待剩余定时器。
    func finishPendingSleepEnergy() {
        guard wakeBaseline != nil else { return }
        finalizeSleepSegment()
    }

    /// 清空历史时丢弃尚未结算的旧睡眠，防止稍后重新写回已删除的记录。
    func cancelPendingSleepEnergy() {
        cancelMaintenanceSampling()
        cancelWakeValidation()
        sleepIntervalStart = nil
        sleepBaseline = nil
        wakeBaseline = nil
    }

    /// 系统即将睡眠：记录当前快照作为基线。回调要轻，系统可能随即挂起。
    private func handleWillSleep() {
        // 上次唤醒后的维持功耗采样窗口尚未结束就再次睡眠（典型：开盖后又马上合盖）：
        // 此时 wakeBaseline 仍在，说明上一段待机还没结算。先用已采集的样本把它结算掉，
        // 否则其能量会被下方的 cancelMaintenanceSampling 连同基线一起丢弃。
        finishPendingSleepEnergy()
        cancelMaintenanceSampling()
        cancelWakeValidation()
        // 定时器可能因 App Nap 被延后，缓存快照会偏早。先读一次最新值再定格起点：
        // 起点偏早会把睡前正常使用的时间并进睡眠区间、从能耗积分里排除掉，
        // 也会放大插电待机按 duration 外推的分支。
        refresh()
        // 没等到唤醒事件就再次入睡（如唤醒通知丢失）时，先用当前时刻关闭上一条区间。
        closeStaleSleepInterval(at: latest.timestamp)

        let start = latest.timestamp
        sleepIntervalStart = start
        // 启动后立刻入睡时电量计可能还读不到容量/电压：区间边界照常记录，但放弃能耗
        // 结算，避免用 0 容量做差值得出"整块电池在睡眠中放空"的假能耗。
        if Self.isUsableSleepEndpoint(latest) {
            sleepBaseline = (
                date: start,
                capacityMAh: latest.currentCapacityMAh,
                voltageV: latest.voltage,
                adapterConnected: latest.adapterConnected,
                batteryDischargingBefore: latest.batteryDischargingWhilePlugged,
                telemetryCounters: latestTelemetryCounters
            )
        } else {
            sleepBaseline = nil
            Self.sleepLogger.error("睡眠开始但读数不完整，放弃本次能耗结算")
        }
        NotificationCenter.default.post(
            name: .sleepIntervalStarted,
            object: self,
            userInfo: ["start": start]
        )
        let state = Self.describeSleepState(
            adapterConnected: latest.adapterConnected,
            batteryDischarging: latest.batteryDischargingWhilePlugged,
            capacityMAh: latest.currentCapacityMAh,
            voltageV: latest.voltage,
            wallCounter: latestTelemetryCounters.accumulatedWallEnergyEstimate
        )
        Self.sleepLogger.notice("睡眠开始 \(state, privacy: .public)")
    }

    private func handleDidWake() {
        guard sleepIntervalStart != nil || sleepBaseline != nil else { return }
        refresh()
        // 唤醒瞬间电量计常停在旧值（容量/电压读到 0）。这种端点直接参与容量差会把
        // 整块电池记成一次睡眠耗电，因此先补采几次再结算。
        guard Self.isUsableSleepEndpoint(latest) else {
            startWakeValidation()
            return
        }
        completeWakeMeasurement()
    }

    /// 用当前 `latest` 作为唤醒端点关闭睡眠区间，并开始维持功耗采样。
    private func completeWakeMeasurement() {
        cancelWakeValidation()
        guard let start = sleepIntervalStart ?? sleepBaseline?.date else { return }
        let baseline = sleepBaseline
        sleepIntervalStart = nil
        if baseline != nil {
            wakeBaseline = (
                date: latest.timestamp,
                capacityMAh: latest.currentCapacityMAh,
                voltageV: latest.voltage,
                adapterConnected: latest.adapterConnected,
                telemetryCounters: latestTelemetryCounters
            )
        }
        NotificationCenter.default.post(
            name: .sleepIntervalEnded,
            object: self,
            userInfo: [
                "start": start,
                "end": latest.timestamp
            ]
        )
        if let baseline {
            let boundaryChange = baseline.adapterConnected == latest.adapterConnected
                ? "无"
                : (baseline.adapterConnected ? "adapterToBattery" : "batteryToAdapter")
            let wakeState = Self.describeSleepState(
                adapterConnected: latest.adapterConnected,
                batteryDischarging: latest.batteryDischargingWhilePlugged,
                capacityMAh: latest.currentCapacityMAh,
                voltageV: latest.voltage,
                wallCounter: latestTelemetryCounters.accumulatedWallEnergyEstimate
            )
            let beforeCounter = baseline.telemetryCounters.accumulatedWallEnergyEstimate
                .map(String.init) ?? "无"
            let summary = "睡眠结束 \(wakeState)"
                + " 睡前插电=\(baseline.adapterConnected) 睡前容量=\(Int(baseline.capacityMAh.rounded()))mAh"
                + " 睡前计数=\(beforeCounter) 边界变化=\(boundaryChange)"
            Self.sleepLogger.notice("\(summary, privacy: .public)")
            startMaintenanceSampling()
        } else {
            Self.sleepLogger.error("睡眠结束但起点读数不完整，只记录区间未结算能耗")
        }
    }

    /// 唤醒端点不可用时的补采：电量计通常在一两秒内恢复，重试仍失败就放弃能耗。
    private func startWakeValidation() {
        guard wakeValidationTask == nil else { return }
        wakeValidationAttempts = 0
        wakeValidationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.wakeValidationInterval))
                if Task.isCancelled { return }
                guard self.sleepIntervalStart != nil || self.sleepBaseline != nil else { return }
                self.wakeValidationAttempts += 1
                self.refresh()
                if Self.isUsableSleepEndpoint(self.latest) {
                    self.completeWakeMeasurement()
                    return
                }
                if self.wakeValidationAttempts >= self.wakeValidationMaxAttempts {
                    self.abandonUnmeasurableWake()
                    return
                }
            }
        }
    }

    private func cancelWakeValidation() {
        wakeValidationTask?.cancel()
        wakeValidationTask = nil
        wakeValidationAttempts = 0
    }

    /// 端点始终不可用：只关闭区间，不产生能耗记录。历史层会把它标成
    /// 「未测量的睡眠」，而不是采样缺口。
    private func abandonUnmeasurableWake() {
        let attempts = wakeValidationAttempts
        cancelWakeValidation()
        guard let start = sleepIntervalStart ?? sleepBaseline?.date else { return }
        let end = max(latest.timestamp, start.addingTimeInterval(SleepEnergyCalculator.minimumDuration))
        sleepIntervalStart = nil
        sleepBaseline = nil
        wakeBaseline = nil
        cancelMaintenanceSampling()
        NotificationCenter.default.post(
            name: .sleepIntervalEnded,
            object: self,
            userInfo: ["start": start, "end": end]
        )
        Self.sleepLogger.error("睡眠端点读数不可用（重试 \(attempts) 次），已放弃能耗结算")
    }

    /// 上一条睡眠区间没有收到唤醒事件就再次入睡时，先用传入时刻关闭它，
    /// 避免区间永远保持打开、把之后的所有样本都排除出能耗积分。
    private func closeStaleSleepInterval(at end: Date) {
        guard let start = sleepIntervalStart, end > start else { return }
        sleepIntervalStart = nil
        NotificationCenter.default.post(
            name: .sleepIntervalEnded,
            object: self,
            userInfo: ["start": start, "end": end]
        )
    }

    /// 唤醒后约 30 秒内每 5 秒采样一次直供功率，取最小值作为系统维持功耗估算。
    private func startMaintenanceSampling() {
        cancelMaintenanceSampling()
        let timer = Timer(timeInterval: maintenanceSampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleMaintenancePower()
            }
        }
        timer.tolerance = maintenanceSampleInterval * 0.2
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
        if let direct = latest.directSupplyPowerW {
            maintenanceSamples.append(max(0, direct))
        }
        if let adapterInput = latest.adapterInputPowerW,
           latest.adapterConnected,
           adapterInput.isFinite,
           adapterInput > 0 {
            maintenanceAdapterInputSamples.append(adapterInput)
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
        maintenanceAdapterInputSamples = []
        maintenanceSampleTick = 0
    }

    private func finalizeSleepSegment() {
        guard let baseline = sleepBaseline, let wake = wakeBaseline else {
            cancelMaintenanceSampling()
            sleepBaseline = nil
            wakeBaseline = nil
            return
        }
        let minimums = Self.minimumMaintenancePowers(
            directSamples: maintenanceSamples,
            adapterInputSamples: maintenanceAdapterInputSamples
        )
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
            maintenanceDirectPowerW: minimums.directSupplyPowerW,
            maintenanceAdapterInputPowerW: minimums.adapterInputPowerW,
            batteryDischargingBefore: baseline.batteryDischargingBefore,
            wallEnergyCalibrationFactor: telemetryCalibrationStore.calibrationFactor,
            wallEnergyIsCalibrated: telemetryCalibrationStore.isCalibrated,
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

    nonisolated static func minimumMaintenancePowers(
        directSamples: [Double],
        adapterInputSamples: [Double]
    ) -> (directSupplyPowerW: Double?, adapterInputPowerW: Double?) {
        let minimumDirect = directSamples
            .filter { $0.isFinite && $0 > 0 }
            .min()
        let minimumAdapterInput = adapterInputSamples
            .filter { $0.isFinite && $0 > 0 }
            .min()
        return (minimumDirect, minimumAdapterInput)
    }

    /// 睡眠端点必须来自一次完整读数。
    ///
    /// 电池服务不可用时 `refresh()` 仍会生成带时间戳的快照，但容量与电压为 0；
    /// 用这种端点做容量差会把整块电池记成一次睡眠耗电，必须在结算前拦截。
    nonisolated static func isUsableSleepEndpoint(_ snapshot: BatterySnapshot) -> Bool {
        snapshot.isPresent
            && snapshot.currentCapacityMAh.isFinite
            && snapshot.currentCapacityMAh > 0
            && snapshot.voltage.isFinite
            && snapshot.voltage > 0
    }

    /// 睡眠端点状态的一行摘要，仅用于诊断日志（非 UI）。
    nonisolated static func describeSleepState(
        adapterConnected: Bool,
        batteryDischarging: Bool,
        capacityMAh: Double,
        voltageV: Double,
        wallCounter: UInt64?
    ) -> String {
        let counter = wallCounter.map(String.init) ?? "无"
        return "插电=\(adapterConnected) 插电放电=\(batteryDischarging)"
            + " 容量=\(Int(capacityMAh.rounded()))mAh 电压=\(String(format: "%.2f", voltageV))V"
            + " 墙上计数=\(counter)"
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
        } else if s.percent > settings.lowBatteryThreshold + AppSettings.lowBatteryNotifyHysteresis {
            lowBatteryNotified = false
        }
    }

    /// 外接电源接入/断开时发送通知（需在设置中开启；首次读取不触发）。
    private func checkAdapterChange(_ s: BatterySnapshot) {
        // 瞬态无电池样本（isPresent == false）不更新基准，避免写坏基准后误报一次「已接入电源」。
        guard s.isPresent else { return }
        defer { lastAdapterConnected = s.adapterConnected }
        guard settings.adapterChangeNotificationsEnabled,
              let previous = lastAdapterConnected,
              previous != s.adapterConnected else { return }
        NotificationService.shared.sendAdapterChange(connected: s.adapterConnected, percent: s.percent)
    }

    private func recordPowerSample(_ s: BatterySnapshot) {
        guard let sample = PowerSample(snapshot: s) else { return }
        powerBuffer.append(sample)
        if powerBuffer.count > recentSampleLimit {
            powerBuffer.removeFirst(powerBuffer.count - recentSampleLimit)
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
        if electricalPowerW.isFinite, electricalPowerW < -BatteryPowerThresholds.minimumDischargeW {
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
    /// - `systemPowerW`：电池非放电时取"适配器输入 − 充电功率"；已确认混合供电时取
    ///   "适配器输入 + 电池放电功率"（与 `consumptionPowerW` 同一口径）；其次 SystemLoad；
    ///   再次电池放电功率；最后仅在供电方式未变化时沿用上次值。
    ///
    /// 放电状态下不单独用适配器总输入覆盖：此时它只覆盖适配器这一路，缺少电池补充的部分。
    nonisolated static func resolvedSystemPowerW(
        systemLoadMW: Double,
        adapterConnected: Bool,
        state: PowerState,
        systemPowerInMW: Double,
        chargingPowerW: Double?,
        telemetryBatteryPowerMW: Double,
        electricalPowerW: Double,
        previous: Double?,
        previousAdapterConnected: Bool,
        batteryDischargingWhilePlugged: Bool = false
    ) -> (systemPowerW: Double?, adapterInputPowerW: Double?) {
        let adapterInput = adapterConnected && systemPowerInMW.isFinite && systemPowerInMW > 0
            ? systemPowerInMW / 1000
            : nil
        // 已确认的插电放电优先于 IsCharging 状态；未确认的充电遥测仍沿用原口径。
        let batteryIsDischarging = state == .discharging ||
            batteryDischargingWhilePlugged ||
            (state == .pluggedIn && dischargingSystemPowerW(
                telemetryBatteryPowerMW: telemetryBatteryPowerMW,
                electricalPowerW: electricalPowerW
            ) != nil)

        if let adapterInput, state != .discharging, !batteryIsDischarging {
            return (max(0, adapterInput - (chargingPowerW ?? 0)), adapterInput)
        }
        // 已确认混合供电：两个可观测电源来源相加，必须先于 SystemLoad 判定——SystemLoad 是
        // 机器内部负载口径（在部分机型上还与 BatteryPower 耦合），按设计文档它不是主指标，
        // 排在前面会让这一支在上述机型上永远走不到。
        if batteryDischargingWhilePlugged,
           let adapterInput,
           let batteryDischarge = dischargingSystemPowerW(
               telemetryBatteryPowerMW: telemetryBatteryPowerMW,
               electricalPowerW: electricalPowerW
           ) {
            return (adapterInput + batteryDischarge, adapterInput)
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
        var batteryUpdateTime: TimeInterval?
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
        data.batteryUpdateTime = Self.numberValue(dict["UpdateTime"]).nilIfZero
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
