import Foundation

enum EnergyCalculator {
    static let maximumGap: TimeInterval = 60

    /// 一天内「缺少功率读数」（相邻样本间距正常，只是 `consumptionPowerW` 无效）的累计时长
    /// 达到该阈值才告警。
    ///
    /// 实测这类缺失集中在拔插电源前后约 1 分钟：`state` 已切到电池供电而电量计仍读 0，
    /// 一天 2~3 次、合计 2~3 分钟（约 1.5 Wh，占日合计 0.4%）。量级低于「日合计偏低」
    /// 的判断门槛，因此按累计时长过滤，避免天天点亮橙色告警；真正的长时间停摆
    /// （间隔 > `maximumGap`）仍由 `gapSeconds` 立即告警。
    static let missingReadingWarningSeconds: TimeInterval = 600

    /// 某一天未被积分覆盖的时长，按成因分开累计。
    struct DailyUnaccountedTime: Equatable {
        /// 采样断点：相邻样本间隔 > `maximumGap`，说明当时应用没在记录（退出/挂起）。
        var gapSeconds: TimeInterval = 0
        /// 间距正常但缺少有效功率读数：插拔电源时的电量计过渡等。
        var missingReadingSeconds: TimeInterval = 0

        var needsWarning: Bool {
            gapSeconds > 0 || missingReadingSeconds >= EnergyCalculator.missingReadingWarningSeconds
        }
    }

    static func dailyEnergyKWh(
        samples: [HistorySample],
        calendar: Calendar = .current,
        maximumGap: TimeInterval = EnergyCalculator.maximumGap,
        excludedIntervals: [SleepInterval] = []
    ) -> [String: Double] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count > 1 else { return [:] }

        var result: [String: Double] = [:]

        for pair in zip(sorted, sorted.dropFirst()) {
            let first = pair.0
            let second = pair.1
            let duration = second.timestamp.timeIntervalSince(first.timestamp)
            guard duration > 0, duration <= maximumGap,
                  !excludedIntervals.contains(where: {
                      $0.overlaps(first.timestamp, second.timestamp)
                  }),
                  let firstPower = validPower(first.consumptionPowerW),
                  let secondPower = validPower(second.consumptionPowerW) else {
                continue
            }

            var segmentStart = first.timestamp
            while segmentStart < second.timestamp {
                let dayStart = calendar.startOfDay(for: segmentStart)
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                    break
                }
                let segmentEnd = min(second.timestamp, nextDay)
                let startFraction = segmentStart.timeIntervalSince(first.timestamp) / duration
                let endFraction = segmentEnd.timeIntervalSince(first.timestamp) / duration
                let startPower = interpolatedPower(
                    first: firstPower,
                    second: secondPower,
                    fraction: startFraction
                )
                let endPower = interpolatedPower(
                    first: firstPower,
                    second: secondPower,
                    fraction: endFraction
                )
                let segmentDuration = segmentEnd.timeIntervalSince(segmentStart)
                let energy = ((startPower + endPower) / 2) * segmentDuration / 3_600_000
                let key = BatteryFormatters.dayKey(for: dayStart, calendar: calendar)
                result[key, default: 0] += energy
                segmentStart = segmentEnd
            }
        }

        return result
    }

    /// 每日未计入积分的时长，按成因拆分。
    ///
    /// 计入的区间与 `dailyEnergyKWh` 会跳过的区间一一对应：相邻样本间隔超过 `maximumGap`，
    /// 或任一端缺少有效功率读数——后者同样不会产生能量，但以前不会留下任何痕迹。
    /// 睡眠区间内不计（睡眠能量由 `SleepEnergyCalculator` 单独结算）。
    /// 时长按跨天比例拆到对应的日键，因此跨午夜的一条区间不会把整天时长记到某一天。
    static func unaccountedSecondsByDay(
        samples: [HistorySample],
        calendar: Calendar = .current,
        maximumGap: TimeInterval = EnergyCalculator.maximumGap,
        excludedIntervals: [SleepInterval] = []
    ) -> [String: DailyUnaccountedTime] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count > 1 else { return [:] }

        var result: [String: DailyUnaccountedTime] = [:]
        for pair in zip(sorted, sorted.dropFirst()) {
            let first = pair.0
            let second = pair.1
            let duration = second.timestamp.timeIntervalSince(first.timestamp)
            guard duration > 0,
                  !excludedIntervals.contains(where: {
                      $0.overlaps(first.timestamp, second.timestamp)
                  }),
                  duration > maximumGap
                    || !isValidPower(first.consumptionPowerW)
                    || !isValidPower(second.consumptionPowerW) else {
                continue
            }
            let isGap = duration > maximumGap
            for segment in daySegments(
                from: first.timestamp,
                to: second.timestamp,
                calendar: calendar
            ) {
                var value = result[segment.dayKey] ?? DailyUnaccountedTime()
                if isGap {
                    value.gapSeconds += segment.seconds
                } else {
                    value.missingReadingSeconds += segment.seconds
                }
                result[segment.dayKey] = value
            }
        }
        return result
    }

    /// 把 `[start, end)` 按日历切成「日键 + 秒数」，跨午夜时逐段拆分。
    static func daySegments(
        from start: Date,
        to end: Date,
        calendar: Calendar = .current
    ) -> [(dayKey: String, seconds: TimeInterval)] {
        guard end > start else { return [] }
        var result: [(dayKey: String, seconds: TimeInterval)] = []
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                break
            }
            let segmentEnd = min(end, nextDay)
            result.append((BatteryFormatters.dayKey(for: dayStart, calendar: calendar), segmentEnd.timeIntervalSince(cursor)))
            cursor = segmentEnd
        }
        return result
    }

    /// Day keys touched by the half-open interval `[start, end)`。
    /// 与 `daySegments` 同一套跨天拆分逻辑，只取键。
    static func dayKeys(
        from start: Date,
        to end: Date,
        calendar: Calendar = .current
    ) -> Set<String> {
        Set(daySegments(from: start, to: end, calendar: calendar).map(\.dayKey))
    }

    static func isValidPower(_ power: Double?) -> Bool {
        guard let power, power.isFinite, power >= 0 else { return false }
        return true
    }

    private static func validPower(_ power: Double?) -> Double? {
        guard let power, isValidPower(power) else { return nil }
        return power
    }

    private static func interpolatedPower(first: Double, second: Double, fraction: Double) -> Double {
        first + (second - first) * fraction
    }
}
