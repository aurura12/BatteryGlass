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
    /// 读取上限内的完整文件；超过 `maximumBytes` 或读取失败时返回 nil。
    ///
    /// 单次 `read(upToCount:)` 可能短读（刚写过的文件、网络卷或受限句柄），
    /// 只读一次会把截断的 Data 当成完整文件，随后 JSON 解码失败并被误判为文件损坏。
    static func read(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0, maximumBytes < Int.max,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var data = Data()
        let chunkSize = 64 * 1024
        while true {
            let remaining = maximumBytes - data.count
            if remaining == 0 {
                // 已到上限：文件必须正好结束，否则视为超限。
                let extra: Data?
                do {
                    extra = try handle.read(upToCount: 1)
                } catch {
                    return nil
                }
                return (extra ?? Data()).isEmpty ? data : nil
            }
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: min(chunkSize, remaining + 1))
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { return data }
            if data.count + chunk.count > maximumBytes { return nil }
            data.append(chunk)
        }
    }
}
