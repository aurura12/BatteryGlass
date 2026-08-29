import Foundation

enum HistoryLoadLimits {
    static let maxHistoryFileBytes = 20 * 1024 * 1024
    static let maxDiagnosticsFileBytes = 50 * 1024 * 1024
    static let maxHistorySamples = 100_000
    static let maxDailySummaries = 10_000
    static let maxDiagnosticsSamples = 100_000

    static func acceptsHistory(sampleCount: Int, summaryCount: Int) -> Bool {
        sampleCount <= maxHistorySamples && summaryCount <= maxDailySummaries
    }

    static func acceptsDiagnostics(sampleCount: Int) -> Bool {
        sampleCount <= maxDiagnosticsSamples
    }
}

enum BoundedFileReader {
    static func read(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0, maximumBytes < Int.max,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes else {
            return nil
        }
        return data
    }
}
