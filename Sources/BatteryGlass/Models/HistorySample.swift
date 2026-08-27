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

    var id: String { dayKey }
}
