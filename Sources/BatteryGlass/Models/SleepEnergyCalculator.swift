import Foundation

/// 待机能耗计算（纯函数，便于单元测试）。
///
/// 睡眠期间进程被挂起、无法实时采样，唤醒后按「电量差法」补测：
/// - 不插电待机：消耗全部来自电池，能量 = (睡眠前电量 − 唤醒后电量) × 平均电压；
/// - 插电待机：充入电池能量（电量差，精确）+ 系统维持功耗（唤醒后延迟采样
///   得到的最低直供功率 × 时长，估算）。
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

        // 用睡眠前的供电状态决定模式：睡眠期间插电则能量来自电源（充入电量 + 维持功耗），
        // 未插电则能量来自电池放电。若唤醒后插电掩盖了睡眠期间的放电量（唤醒后充电使
        // 容量回升），容量差被钳为 0 后无能量，不生成区间（保守丢弃）。
        if input.adapterConnectedBefore {
            let chargedInKWh = max(0, input.capacityAfterMAh - input.capacityBeforeMAh)
                * averageVoltage / 1_000_000
            let maintenanceKWh = max(0, input.maintenanceDirectPowerW ?? 0)
                * duration / 3_600_000
            energyKWh = chargedInKWh + maintenanceKWh
            mode = chargedInKWh > 0 ? .charging : .pluggedIdle
        } else {
            energyKWh = max(0, input.capacityBeforeMAh - input.capacityAfterMAh)
                * averageVoltage / 1_000_000
            mode = .discharging
        }

        guard energyKWh.isFinite, energyKWh > 0 else { return nil }

        return SleepSegment(
            id: UUID(),
            start: input.sleepStart,
            end: input.wakeTime,
            energyKWh: energyKWh,
            averagePowerW: energyKWh * 3_600_000 / duration,
            mode: mode
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
