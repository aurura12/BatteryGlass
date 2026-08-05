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
}
