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

/// Current two-minute consumption statistics, including expiry while readings are missing.
struct PowerTrendStatistics: Equatable {
    let peakPower: Double?
    let averagePower: Double?

    init(samples: [PowerSample], now: Date) {
        let cutoff = now.addingTimeInterval(-120)
        let powers = samples.filter {
            $0.timestamp >= cutoff && $0.timestamp <= now
                && $0.power.isFinite && $0.power >= 0
        }.map(\.power)
        peakPower = powers.max()
        averagePower = powers.isEmpty ? nil : powers.reduce(0, +) / Double(powers.count)
    }
}
