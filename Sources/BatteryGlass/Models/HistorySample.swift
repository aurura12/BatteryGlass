import Foundation

struct HistorySample: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var timestamp: Date
    var power: Double
    var percent: Double
    var cycleCount: Int
    var healthPercent: Double?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        power: Double,
        percent: Double,
        cycleCount: Int,
        healthPercent: Double?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.power = power
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
    var averagePower: Double
    var maxPower: Double
    var minPower: Double

    var id: String { dayKey }
}
