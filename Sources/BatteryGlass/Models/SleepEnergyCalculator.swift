import Foundation

/// 待机能耗计算（纯函数，便于单元测试）。
///
/// 睡眠期间进程被挂起、无法实时采样，优先使用系统累计遥测计数器补测：
/// - 不插电待机：消耗全部来自电池，能量 = (睡眠前电量 − 唤醒后电量) × 平均电压；
/// - 插电待机：优先使用累计墙上输入能量；若同时发生电池放电，则把可观测的
///   电池放电能量一并计入；计数器不可用时回退到电量差和唤醒后功率估算。
///
/// 待机模式以**睡眠前（即睡眠期间）的供电状态**为准：睡眠中无法操作电源，
/// `adapterConnectedBefore` 才是睡眠期间的实际供电状态；唤醒瞬间的插拔变化
/// （如睡前插电、早上拔电带走，或睡前未插电、唤醒后插上充电）不应改变归属。
enum SleepEnergyCalculator {
    struct Input {
        var sleepStart: Date
        var capacityBeforeMAh: Double
        var voltageBeforeV: Double
        /// 睡眠前的供电状态，即睡眠期间的实际供电状态（决定待机模式）。
        var adapterConnectedBefore: Bool
        var wakeTime: Date
        var capacityAfterMAh: Double
        var voltageAfterV: Double
        /// 唤醒瞬间的供电状态，仅用于参考；模式判断以 `adapterConnectedBefore` 为准。
        var adapterConnectedAfter: Bool
        /// 唤醒后延迟采样得到的系统维持直供功率最小值（W）
        var maintenanceDirectPowerW: Double?
        /// 睡眠前实际功率状态；用于识别接电但电池仍放电的混合状态。
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
            duration: duration
        )
        let batteryDischargeKWh = max(0, input.capacityBeforeMAh - input.capacityAfterMAh)
            * averageVoltage / 1_000_000

        // 用睡眠前的供电状态决定模式：睡眠期间插电时优先采用墙上输入累计值；
        // 未插电时采用电池放电量。若计数器不可用，才使用电量差和唤醒后功率回退。
        if input.adapterConnectedBefore, let wallCounterEnergy {
            // 混合供电时，累计墙上输入与电池下降量都属于 B 口径的能源贡献。
            energyKWh = wallCounterEnergy
                + (input.powerStateBefore == .discharging ? batteryDischargeKWh : 0)
            mode = input.powerStateBefore == .discharging ? .discharging :
                (input.capacityAfterMAh > input.capacityBeforeMAh ? .charging : .pluggedIdle)
            measurementMethod = .telemetryCounter
        } else if input.adapterConnectedBefore {
            let chargedInKWh = max(0, input.capacityAfterMAh - input.capacityBeforeMAh)
                * averageVoltage / 1_000_000
            let maintenanceKWh = max(0, input.maintenanceDirectPowerW ?? 0)
                * duration / 3_600_000
            if input.powerStateBefore == .discharging {
                energyKWh = batteryDischargeKWh + maintenanceKWh
                mode = .discharging
            } else {
                energyKWh = chargedInKWh + maintenanceKWh
                mode = chargedInKWh > 0 ? .charging : .pluggedIdle
            }
            measurementMethod = .fallbackEstimate
        } else {
            energyKWh = batteryDischargeKWh
            mode = .discharging
            measurementMethod = .fallbackEstimate
        }

        guard energyKWh.isFinite, energyKWh > 0 else { return nil }

        return SleepSegment(
            id: UUID(),
            start: input.sleepStart,
            end: input.wakeTime,
            energyKWh: energyKWh,
            averagePowerW: energyKWh * 3_600_000 / duration,
            mode: mode,
            measurementMethod: measurementMethod
        )
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
