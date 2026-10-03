import Foundation

struct HistorySample: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var timestamp: Date
    var power: Double
    var consumptionPowerW: Double?
    var percent: Double
    var cycleCount: Int
    var healthPercent: Double?
    /// 新增于 payload v6；旧样本缺键解码为 nil。
    var temperatureCelsius: Double? = nil

    init(
        id: UUID = UUID(),
        timestamp: Date,
        power: Double,
        consumptionPowerW: Double? = nil,
        percent: Double,
        cycleCount: Int,
        healthPercent: Double?,
        temperatureCelsius: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.power = power
        self.consumptionPowerW = consumptionPowerW
        self.percent = percent
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.temperatureCelsius = temperatureCelsius
    }
}

/// Known limitations and provenance for a daily energy value.
struct DailyEnergyQuality: Codable, Equatable, Sendable {
    var hasSamplingGaps: Bool
    var hasEstimatedSleepEnergy: Bool
    var hasUncalibratedCounterEnergy: Bool
    var hasLowerBoundSleepEnergy: Bool
    var hasUnknownHistoricalCoverage: Bool

    init(
        hasSamplingGaps: Bool = false,
        hasEstimatedSleepEnergy: Bool = false,
        hasUncalibratedCounterEnergy: Bool = false,
        hasLowerBoundSleepEnergy: Bool = false,
        hasUnknownHistoricalCoverage: Bool = false
    ) {
        self.hasSamplingGaps = hasSamplingGaps
        self.hasEstimatedSleepEnergy = hasEstimatedSleepEnergy
        self.hasUncalibratedCounterEnergy = hasUncalibratedCounterEnergy
        self.hasLowerBoundSleepEnergy = hasLowerBoundSleepEnergy
        self.hasUnknownHistoricalCoverage = hasUnknownHistoricalCoverage
    }

    /// 数值可能偏离真实值（采样断点 / 睡眠估算 / 未校准计数器 / 只统计到可观测来源）。
    /// 这类原因会让日合计「偏低或有偏差」，用橙色告警。
    var hasAccuracyWarning: Bool {
        hasSamplingGaps
            || hasEstimatedSleepEnergy
            || hasUncalibratedCounterEnergy
            || hasLowerBoundSleepEnergy
    }

    /// 旧版本记录，统计口径未知。数值本身不一定偏低，因此不并入 `hasAccuracyWarning`，
    /// 避免整段历史一起变橙、把真正的缺口淹没掉。
    var hasUnknownProvenance: Bool {
        hasUnknownHistoricalCoverage
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
