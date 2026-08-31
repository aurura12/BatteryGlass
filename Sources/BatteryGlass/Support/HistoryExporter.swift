import Foundation

/// 历史数据导出：纯函数生成 CSV / JSON 文本，便于单元测试。
enum HistoryExporter {
    /// 生成 CSV（逗号分隔，UTF-8，含表头）。
    static func csvString(samples: [HistorySample]) -> String {
        let rows = samples.map { sample in
            [
                Self.timeFormatter.string(from: sample.timestamp),
                Self.csvField(Self.decimal(sample.power)),
                Self.csvField(sample.consumptionPowerW.map { Self.decimal($0) }),
                Self.csvField(Self.decimal(sample.percent, 0)),
                Self.csvField("\(sample.cycleCount)"),
                Self.csvField(sample.healthPercent.map { Self.decimal($0) })
            ].joined(separator: ",")
        }
        return ([Self.header] + rows).joined(separator: "\n")
    }

    /// 生成包含保留原始采样与完整每日汇总的 CSV，避免高频采样长期累积导致文件无限增长。
    static func csvString(
        samples: [HistorySample],
        dailySummaries: [DailySummary]
    ) -> String {
        let sampleRows = samples.map { sample in
            [
                "采样",
                Self.timeFormatter.string(from: sample.timestamp),
                Self.decimal(sample.power),
                sample.consumptionPowerW.map { Self.decimal($0) } ?? "",
                Self.decimal(sample.percent, 0),
                "\(sample.cycleCount)",
                sample.healthPercent.map { Self.decimal($0) } ?? "",
                "",
                "",
                "",
                "",
                ""
            ].map(Self.csvField).joined(separator: ",")
        }

        let summaryRows = dailySummaries.sorted { $0.date < $1.date }.map { summary in
            [
                "每日汇总",
                summary.dayKey,
                "",
                "",
                "",
                "\(summary.maxCycleCount)",
                summary.minHealthPercent.map { Self.decimal($0) } ?? "",
                summary.energyKWh.map { Self.decimal($0, 3) } ?? "",
                Self.decimal(summary.averagePower),
                Self.decimal(summary.maxPower),
                Self.decimal(summary.minPower),
                "\(summary.sampleCount)"
            ].map(Self.csvField).joined(separator: ",")
        }

        return ([Self.extendedHeader] + sampleRows + summaryRows).joined(separator: "\n")
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
    private static let extendedHeader = "类型,时间,功率(W),消耗功率(W),电量(%),循环次数,健康度(%),耗电量(kWh),平均功率(W),最大功率(W),最小功率(W),样本数"

    private static let timeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 数值转字符串固定用 POSIX locale，避免系统 locale 使用逗号小数分隔符
    /// （如 de_DE/fr_FR）时输出 "3,5" 破坏 CSV 的列结构。
    private static func decimal(_ value: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

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
