import Foundation

enum EnergyCalculator {
    static func dailyEnergyKWh(
        samples: [HistorySample],
        calendar: Calendar = .current,
        maximumGap: TimeInterval = 60
    ) -> [String: Double] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count > 1 else { return [:] }

        var result: [String: Double] = [:]

        for pair in zip(sorted, sorted.dropFirst()) {
            let first = pair.0
            let second = pair.1
            let duration = second.timestamp.timeIntervalSince(first.timestamp)
            guard duration > 0, duration <= maximumGap,
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
                let key = dayKey(for: dayStart, calendar: calendar)
                result[key, default: 0] += energy
                segmentStart = segmentEnd
            }
        }

        return result
    }

    private static func validPower(_ power: Double?) -> Double? {
        guard let power, power.isFinite, power >= 0 else { return nil }
        return power
    }

    private static func interpolatedPower(first: Double, second: Double, fraction: Double) -> Double {
        first + (second - first) * fraction
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
