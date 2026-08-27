import Foundation

struct PowerSample: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let power: Double
    let percent: Double

    init(timestamp: Date = Date(), power: Double, percent: Double) {
        self.id = UUID()
        self.timestamp = timestamp
        self.power = power
        self.percent = percent
    }

    init?(snapshot: BatterySnapshot) {
        guard let power = snapshot.consumptionPowerW else { return nil }
        self.init(timestamp: snapshot.timestamp, power: power, percent: snapshot.percent)
    }
}
