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
