import Foundation

/// 待机能耗计算（纯函数，便于单元测试）。
///
/// 睡眠期间进程被挂起、无法实时采样，优先使用系统累计遥测计数器补测：
/// - 不插电待机：消耗全部来自电池，能量 = (睡眠前电量 − 唤醒后电量) × 平均电压；
/// - 插电待机：优先使用累计墙上输入能量；若同时发生电池放电，则把可观测的
///   电池放电能量一并计入；计数器不可用时回退到电量差和唤醒后功率估算。
///
/// 供电状态在睡眠边界两侧不同时（睡前未插电、醒时已插电，或反之），无法区分变化
/// 发生在睡眠途中还是唤醒瞬间，因此插电占睡眠的比例未知：此时**只累计可观测的
/// 积分量**（计数器差值、容量差），不使用"唤醒后瞬时功率 × 整段时长"外推
/// （那会把只插了几分钟的睡眠高估成全程插电），结果系统性偏低并把
/// `hasUnobservedSource` 置为 true。睡眠边界没有变化时，由睡眠前的供电状态决定模式。
enum SleepEnergyCalculator {
    struct Input {
        var sleepStart: Date
        var capacityBeforeMAh: Double
        var voltageBeforeV: Double
        /// 睡眠前的供电状态。
        var adapterConnectedBefore: Bool
        var wakeTime: Date
        var capacityAfterMAh: Double
        var voltageAfterV: Double
        /// 唤醒瞬间的供电状态；与 `adapterConnectedBefore` 不同即表示边界电源变化。
        var adapterConnectedAfter: Bool
        /// 唤醒后延迟采样得到的系统维持直供功率最小值（W）
        var maintenanceDirectPowerW: Double?
        /// 唤醒后延迟采样得到的适配器总输入功率最小值（W）。
        var maintenanceAdapterInputPowerW: Double? = nil
        /// 睡眠前已由连续带符号样本确认的插电同时放电状态。
        var batteryDischargingBefore: Bool = false
        /// 校准后的墙上输入计数器比例；默认 1 表示未校准。
        var wallEnergyCalibrationFactor: Double = 1.0
        var wallEnergyIsCalibrated: Bool = false
        /// Legacy source compatibility; runtime callers must use batteryDischargingBefore.
        @available(*, deprecated, message: "Use batteryDischargingBefore")
        var powerStateBefore: PowerState? = nil
        /// 睡眠前后累计墙上输入能量计数器的原始值。
        var wallEnergyCounterBefore: UInt64? = nil
        var wallEnergyCounterAfter: UInt64? = nil
    }

    /// 待机时长低于该值（秒）时读数噪声占比过大，不生成区间。
    static let minimumDuration: TimeInterval = 60

    static func segment(from input: Input) -> SleepSegment? {
        let duration = input.wakeTime.timeIntervalSince(input.sleepStart)
        guard duration >= minimumDuration else { return nil }

        let averageVoltage = resolvedAverageVoltage(
            before: input.voltageBeforeV,
            after: input.voltageAfterV
        )
        guard averageVoltage > 0 else { return nil }

        let energyKWh: Double
        let mode: SleepSegmentMode
        let measurementMethod: SleepEnergyMeasurementMethod

        let wallCounterEnergy = PowerTelemetryEnergy.wallEnergyKWh(
            before: input.wallEnergyCounterBefore,
            after: input.wallEnergyCounterAfter,
            duration: duration,
            calibrationFactor: input.wallEnergyCalibrationFactor
        )
        let capacityDeltaMAh = input.capacityAfterMAh - input.capacityBeforeMAh
        guard capacityDeltaMAh.isFinite else { return nil }
        let batteryDischargeKWh = max(0, -capacityDeltaMAh)
            * averageVoltage / 1_000_000
        let batteryChargeGainKWh = max(0, capacityDeltaMAh)
            * averageVoltage / 1_000_000

        // 睡眠边界两侧供电状态不同：无法区分变化发生在睡眠途中还是唤醒瞬间，
        // 因此只能保留可观测的积分量（计数器差值 / 容量差），另一时段无法从两个端点恢复。
        let sourceChanged = input.adapterConnectedBefore != input.adapterConnectedAfter
        let hasUnobservedSource = sourceChanged
        let boundaryPowerChange: SleepBoundaryPowerChange? = sourceChanged
            ? (input.adapterConnectedBefore ? .adapterToBattery : .batteryToAdapter)
            : nil

        if !sourceChanged {
            // 用睡眠前的供电来源决定模式：睡眠期间插电时优先采用墙上输入累计值；
            // 计数器不可用时，按电量净变化选择不重复的电源侧回退。
            if input.adapterConnectedBefore, let wallCounterEnergy {
                // 混合供电时，累计墙上输入与电池下降量都属于 B 口径的能源贡献。
                energyKWh = wallCounterEnergy
                    + (input.batteryDischargingBefore ? batteryDischargeKWh : 0)
                mode = input.batteryDischargingBefore ? .discharging :
                    (capacityDeltaMAh > 0 ? .charging : .pluggedIdle)
                measurementMethod = .telemetryCounter
            } else if input.adapterConnectedBefore {
                if capacityDeltaMAh > 0 {
                    energyKWh = batteryChargeGainKWh
                        + powerEnergyKWh(input.maintenanceDirectPowerW, duration: duration)
                    mode = .charging
                } else {
                    energyKWh = powerEnergyKWh(
                        input.maintenanceAdapterInputPowerW,
                        duration: duration
                    ) + (input.batteryDischargingBefore ? batteryDischargeKWh : 0)
                    mode = input.batteryDischargingBefore ? .discharging : .pluggedIdle
                }
                measurementMethod = .fallbackEstimate
            } else {
                energyKWh = batteryDischargeKWh
                mode = .discharging
                measurementMethod = .fallbackEstimate
            }
        } else {
            // 电源在睡眠边界发生变化（睡前未插电→醒时插电，或反之）。
            //
            // 插电占睡眠的比例未知，所以不使用"唤醒后功率 × 整段时长"：那会把只插了
            // 几分钟的睡眠高估成全程插电，误差无上界。只取积分量，结果一律是下界。
            if let wallCounterEnergy {
                // 计数器直接测到墙侧输入；电池净释放量是另一个独立来源，无条件累加。
                // 注意不能用 batteryDischargingBefore 门控：它要求睡前已插电，
                // 睡前未插电时恒为 false，会把"记放电量"错误退化成"只记墙侧"。
                energyKWh = wallCounterEnergy + batteryDischargeKWh
                if capacityDeltaMAh > 0 {
                    mode = .charging
                } else if capacityDeltaMAh < 0 {
                    mode = .discharging
                } else {
                    mode = input.batteryDischargingBefore ? .discharging : .pluggedIdle
                }
                measurementMethod = .telemetryCounter
            } else if capacityDeltaMAh > 0 {
                // 充入电池的能量是墙侧输入的下界（不含转换损耗与系统自身功耗）。
                energyKWh = batteryChargeGainKWh
                mode = .charging
                measurementMethod = .fallbackEstimate
            } else {
                energyKWh = batteryDischargeKWh
                mode = .discharging
                measurementMethod = .fallbackEstimate
            }
        }

        guard energyKWh.isFinite, energyKWh > 0 else { return nil }

        return SleepSegment(
            id: UUID(),
            start: input.sleepStart,
            end: input.wakeTime,
            energyKWh: energyKWh,
            averagePowerW: energyKWh * 3_600_000 / duration,
            mode: mode,
            measurementMethod: measurementMethod,
            isCalibrated: measurementMethod == .telemetryCounter && input.wallEnergyIsCalibrated,
            hasUnobservedSource: hasUnobservedSource,
            boundaryPowerChange: boundaryPowerChange
        )
    }

    private static func powerEnergyKWh(_ power: Double?, duration: TimeInterval) -> Double {
        guard let power, power.isFinite, power > 0 else { return 0 }
        return power * duration / 3_600_000
    }

    /// 取睡眠前后电压平均值；一侧为 0（读不到）时用另一侧。
    private static func resolvedAverageVoltage(before: Double, after: Double) -> Double {
        if before > 0, after > 0 { return (before + after) / 2 }
        return before > 0 ? before : after
    }

    /// 把待机区间能量按跨天时长比例拆分到各日（dayKey → kWh），供每日耗电量累计。
    static func dailyEnergySplit(
        energyKWh: Double,
        from start: Date,
        to end: Date,
        calendar: Calendar = .current
    ) -> [String: Double] {
        guard energyKWh.isFinite, energyKWh >= 0 else { return [:] }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return [:] }

        var result: [String: Double] = [:]
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let segmentEnd = min(end, nextDay)
            let fraction = segmentEnd.timeIntervalSince(cursor) / total
            let key = dayKey(for: cursor, calendar: calendar)
            result[key, default: 0] += energyKWh * fraction
            cursor = segmentEnd
        }
        return result
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
