import Foundation

struct HistorySample: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var timestamp: Date
    var power: Double
    var consumptionPowerW: Double?
    var percent: Double
    var cycleCount: Int
    var healthPercent: Double?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        power: Double,
        consumptionPowerW: Double? = nil,
        percent: Double,
        cycleCount: Int,
        healthPercent: Double?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.power = power
        self.consumptionPowerW = consumptionPowerW
        self.percent = percent
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
    }
}

/// Known limitations and provenance for a daily energy value.
struct DailyEnergyQuality: Codable, Equatable, Sendable {
    var hasSamplingGaps: Bool
    var hasEstimatedSleepEnergy: Bool
    var hasUncalibratedCounterEnergy: Bool
    var hasLowerBoundSleepEnergy: Bool
    var hasUnknownHistoricalCoverage: Bool
    var hasUnmeasuredSleepEnergy: Bool

    init(
        hasSamplingGaps: Bool = false,
        hasEstimatedSleepEnergy: Bool = false,
        hasUncalibratedCounterEnergy: Bool = false,
        hasLowerBoundSleepEnergy: Bool = false,
        hasUnknownHistoricalCoverage: Bool = false,
        hasUnmeasuredSleepEnergy: Bool = false
    ) {
        self.hasSamplingGaps = hasSamplingGaps
        self.hasEstimatedSleepEnergy = hasEstimatedSleepEnergy
        self.hasUncalibratedCounterEnergy = hasUncalibratedCounterEnergy
        self.hasLowerBoundSleepEnergy = hasLowerBoundSleepEnergy
        self.hasUnknownHistoricalCoverage = hasUnknownHistoricalCoverage
        self.hasUnmeasuredSleepEnergy = hasUnmeasuredSleepEnergy
    }

    private enum CodingKeys: String, CodingKey {
        case hasSamplingGaps, hasEstimatedSleepEnergy, hasUncalibratedCounterEnergy
        case hasLowerBoundSleepEnergy, hasUnknownHistoricalCoverage, hasUnmeasuredSleepEnergy
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hasSamplingGaps = try values.decodeIfPresent(Bool.self, forKey: .hasSamplingGaps) ?? false
        hasEstimatedSleepEnergy = try values.decodeIfPresent(Bool.self, forKey: .hasEstimatedSleepEnergy) ?? false
        hasUncalibratedCounterEnergy = try values.decodeIfPresent(Bool.self, forKey: .hasUncalibratedCounterEnergy) ?? false
        hasLowerBoundSleepEnergy = try values.decodeIfPresent(Bool.self, forKey: .hasLowerBoundSleepEnergy) ?? false
        hasUnknownHistoricalCoverage = try values.decodeIfPresent(Bool.self, forKey: .hasUnknownHistoricalCoverage) ?? false
        hasUnmeasuredSleepEnergy = try values.decodeIfPresent(Bool.self, forKey: .hasUnmeasuredSleepEnergy) ?? false
    }

    /// 数值可能偏离真实值（采样断点 / 睡眠估算 / 未校准计数器 / 只统计到可观测来源）。
    /// 这类原因会让日合计「偏低或有偏差」，用橙色告警。
    var hasAccuracyWarning: Bool {
        hasSamplingGaps
            || hasEstimatedSleepEnergy
            || hasUncalibratedCounterEnergy
            || hasLowerBoundSleepEnergy
            || hasUnmeasuredSleepEnergy
    }

    /// 旧版本记录，统计口径未知。数值本身不一定偏低，因此不并入 `hasAccuracyWarning`，
    /// 避免整段历史一起变橙、把真正的缺口淹没掉。
    var hasUnknownProvenance: Bool {
        hasUnknownHistoricalCoverage
    }

    /// 告警原因文案；多条原因按标记顺序以「；」拼接。历史页角标与实时页「今日耗电」共用。
    var warningText: String? {
        var reasons: [String] = []
        if hasSamplingGaps {
            reasons.append("当天存在采样断点或累计功率读数缺失，耗电量可能偏低")
        }
        if hasUnmeasuredSleepEnergy {
            reasons.append("部分睡眠时段缺少能耗记录，耗电量可能偏低")
        }
        if hasEstimatedSleepEnergy {
            reasons.append("睡眠段为估算值（无可用计数器或未校准）")
        }
        if hasUncalibratedCounterEnergy {
            reasons.append("睡眠段使用未校准的遥测计数器，数值可能有系统性偏差")
        }
        if hasLowerBoundSleepEnergy {
            reasons.append("睡眠边界供电状态变化，仅统计到可观测来源，实际值不低于此")
        }
        if hasUnknownHistoricalCoverage {
            reasons.append("旧版本记录，统计口径未知")
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "；")
    }
}

struct DailySummary: Codable, Identifiable, Equatable, Sendable {
    var dayKey: String
    var date: Date
    var sampleCount: Int
    var maxCycleCount: Int
    var minHealthPercent: Double?
    var energyKWh: Double?
    var averagePower: Double
    var maxPower: Double
    var minPower: Double
    /// Nil for summaries written before energy provenance was tracked.
    var energyQuality: DailyEnergyQuality? = nil

    var id: String { dayKey }
}

extension DailySummary {
    /// 「有可用且合法的日耗电量」。缺值、NaN、负值都不算，
    /// 与 `EnergyCalculator` 积分时的有效性判断共用同一个谓词，避免两处漂移。
    var hasValidEnergy: Bool {
        EnergyCalculator.isValidPower(energyKWh)
    }

    /// 该日需要橙色告警：没有可用值，或存在会让数值偏低/有偏差的记录。
    var needsEnergyAttention: Bool {
        !hasValidEnergy || (energyQuality?.hasAccuracyWarning ?? false)
    }
}
