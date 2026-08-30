import Foundation

/// 历史数据导出：纯函数生成 CSV / JSON 文本，便于单元测试。
enum HistoryExporter {
    /// 生成 CSV（逗号分隔，UTF-8，含表头）。
    static func csvString(samples: [HistorySample]) -> String {
        let rows = samples.map { sample in
            [
                Self.timeFormatter.string(from: sample.timestamp),
                Self.csvField(String(format: "%.1f", sample.power)),
                Self.csvField(sample.consumptionPowerW.map { String(format: "%.1f", $0) }),
                Self.csvField(String(format: "%.0f", sample.percent)),
                Self.csvField("\(sample.cycleCount)"),
                Self.csvField(sample.healthPercent.map { String(format: "%.1f", $0) })
            ].joined(separator: ",")
        }
        return ([Self.header] + rows).joined(separator: "\n")
    }

    /// 生成 JSON（与 history.json 相同结构，版本 2，含每日汇总）。
    static func jsonString(samples: [HistorySample], dailySummaries: [DailySummary]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = ExportPayload(
            version: 2,
            samples: samples,
            dailySummaries: dailySummaries
        )
        guard let data = try? encoder.encode(payload) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static let header = "时间,功率(W),消耗功率(W),电量(%),循环次数,健康度(%)"

    private static let timeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 空值导出为空字段，其余按原样返回（数值字段不含逗号/引号，无需转义）。
    private static func csvField(_ value: String?) -> String {
        value ?? ""
    }
}

private struct ExportPayload: Codable {
    var version: Int
    var samples: [HistorySample]
    var dailySummaries: [DailySummary]
}
