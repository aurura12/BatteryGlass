import Foundation

struct HistorySampleRecovery {
    struct Result: Sendable {
        let samples: [HistorySample]
        let didChange: Bool
    }

    static func backfillConsumptionPower(
        in samples: [HistorySample],
        from diagnostics: [PowerDiagnosticsSample],
        maximumMatchGap: TimeInterval = 3
    ) -> Result {
        let candidates = diagnostics
            .compactMap { diagnostic -> (Date, Double)? in
                guard let power = diagnostic.consumptionPowerW,
                      power.isFinite,
                      power >= 0 else {
                    return nil
                }
                return (diagnostic.timestamp, power)
            }
            .sorted { $0.0 < $1.0 }

        guard !samples.isEmpty, !candidates.isEmpty else {
            return Result(samples: samples, didChange: false)
        }

        var recovered = samples
        var didChange = false

        for index in recovered.indices {
            guard recovered[index].consumptionPowerW == nil,
                  let match = nearestCandidate(
                      to: recovered[index].timestamp,
                      in: candidates
                  ),
                  abs(match.0.timeIntervalSince(recovered[index].timestamp)) <= maximumMatchGap else {
                continue
            }

            recovered[index].consumptionPowerW = match.1
            didChange = true
        }

        return Result(samples: recovered, didChange: didChange)
    }

    private static func nearestCandidate(
        to timestamp: Date,
        in candidates: [(Date, Double)]
    ) -> (Date, Double)? {
        guard !candidates.isEmpty else { return nil }

        var lower = 0
        var upper = candidates.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if candidates[middle].0 < timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        let upperCandidate = candidates[lower]
        guard lower > 0 else { return upperCandidate }

        let lowerCandidate = candidates[lower - 1]
        let lowerDistance = abs(lowerCandidate.0.timeIntervalSince(timestamp))
        let upperDistance = abs(upperCandidate.0.timeIntervalSince(timestamp))
        return lowerDistance <= upperDistance ? lowerCandidate : upperCandidate
    }
}

enum PowerDiagnosticsHistoryLoader {
    /// 诊断文件大小上限。正常轮换的单文件约 5 MB，超过上限视为被篡改，跳过加载。
    private static let maxDiagnosticsFileSize = 50 * 1024 * 1024

    static func load() -> [PowerDiagnosticsSample] {
        let current = PowerDiagnosticsLogger.logFileURL
        let rotated = current
            .deletingPathExtension()
            .appendingPathExtension("1.jsonl")

        return [rotated, current].flatMap(load(from:))
    }

    private static func load(from url: URL) -> [PowerDiagnosticsSample] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              size <= maxDiagnosticsFileSize,
              let data = try? Data(contentsOf: url) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data
            .split(separator: 0x0A)
            .compactMap { try? decoder.decode(PowerDiagnosticsSample.self, from: Data($0)) }
    }
}
