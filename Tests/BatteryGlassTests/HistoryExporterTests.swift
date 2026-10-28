import Foundation
import XCTest
@testable import BatteryGlass

final class HistoryExporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryGlassExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeSample(
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        power: Double = 12.34,
        consumptionPowerW: Double? = 12.3,
        percent: Double = 87.6,
        cycleCount: Int = 42,
        healthPercent: Double? = 95.5
    ) -> HistorySample {
        HistorySample(
            timestamp: timestamp,
            power: power,
            consumptionPowerW: consumptionPowerW,
            percent: percent,
            cycleCount: cycleCount,
            healthPercent: healthPercent
        )
    }

    func testCSVIncludesExtendedHeader() {
        let csv = HistoryExporter.csvString(samples: [makeSample()], dailySummaries: [])
        let header = csv.split(separator: "\n").first

        XCTAssertEqual(
            header,
            "类型,时间,功率(W),消耗功率(W),电量(%),循环次数,健康度(%),耗电量(kWh),平均功率(W),最大功率(W),最小功率(W),样本数"
        )
    }

    func testCSVHasNoTemperatureColumn() {
        let csv = HistoryExporter.csvString(samples: [makeSample()], dailySummaries: [])
        let fields = csv.split(separator: "\n")[1]
            .split(separator: ",", omittingEmptySubsequences: false)

        XCTAssertEqual(fields.count, 12)
        XCTAssertFalse(csv.contains("温度"))
    }

    func testCSVLeavesNilFieldsEmpty() {
        let sample = makeSample(consumptionPowerW: nil, healthPercent: nil)
        let csv = HistoryExporter.csvString(samples: [sample], dailySummaries: [])
        let dataLine = csv.split(separator: "\n")[1]

        // 消耗功率与健康度列为空：第 4、7 个字段（索引 3、6）为空字符串。
        let fields = dataLine.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields[3], "")
        XCTAssertEqual(fields[6], "")
    }

    func testCSVIncludesDailySummariesAlongsideRetainedSamples() {
        let summary = DailySummary(
            dayKey: "2026-08-20",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            sampleCount: 120,
            maxCycleCount: 42,
            minHealthPercent: 95.5,
            energyKWh: 0.123,
            averagePower: 10,
            maxPower: 20,
            minPower: 5
        )

        let csv = HistoryExporter.csvString(
            samples: [makeSample()],
            dailySummaries: [summary]
        )

        XCTAssertTrue(csv.contains("每日汇总,2026-08-20"))
        XCTAssertTrue(csv.contains("0.123"))
        XCTAssertTrue(csv.contains("120"))
    }

    func testJSONExportThrowsInsteadOfReturningEmptyStringForInvalidNumbers() {
        var sample = makeSample()
        sample.power = .nan

        XCTAssertThrowsError(
            try HistoryExporter.jsonString(samples: [sample], dailySummaries: [])
        )
    }

    func testWriteCSVProducesHeaderAndSampleRows() throws {
        let url = directory.appendingPathComponent("history.csv")
        try HistoryExporter.write(.csv, samples: [makeSample()], dailySummaries: [], to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.hasPrefix("类型,时间,"))
    }

    func testWriteJSONProducesDecodablePayload() throws {
        let url = directory.appendingPathComponent("history.json")
        try HistoryExporter.write(.json, samples: [makeSample()], dailySummaries: [], to: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ExportPayloadFixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(payload.version, 8)
        XCTAssertEqual(payload.samples.count, 1)
        XCTAssertEqual(payload.samples.first?.cycleCount, 42)
    }

    /// 编码失败时不能碰目标文件：导出是在保存面板选好的路径上直接写，失败后不应留下半份或空文件。
    func testWriteJSONKeepsExistingFileWhenEncodingFails() throws {
        let url = directory.appendingPathComponent("history.json")
        let original = Data("existing".utf8)
        try original.write(to: url)

        var sample = makeSample()
        sample.power = .nan

        XCTAssertThrowsError(
            try HistoryExporter.write(.json, samples: [sample], dailySummaries: [], to: url)
        )
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testJSONRoundTripsSamplesAndSummaries() throws {
        let summaries = [
            DailySummary(
                dayKey: "2026-08-30",
                date: Date(timeIntervalSince1970: 1_700_000_000),
                sampleCount: 3,
                maxCycleCount: 42,
                minHealthPercent: 95.5,
                energyKWh: 0.123,
                averagePower: 10,
                maxPower: 20,
                minPower: 5
            )
        ]
        let sample = makeSample()
        let sleepSegments = [
            SleepSegment(
                id: UUID(),
                start: Date(timeIntervalSince1970: 1_700_000_000),
                end: Date(timeIntervalSince1970: 1_700_003_600),
                energyKWh: 0.002,
                averagePowerW: 2.0,
                mode: .discharging,
                hasUnobservedSource: true,
                boundaryPowerChange: .batteryToAdapter
            )
        ]
        let sleepIntervals = [
            SleepInterval(
                start: Date(timeIntervalSince1970: 1_700_000_000),
                end: Date(timeIntervalSince1970: 1_700_000_030)
            )
        ]
        let json = try HistoryExporter.jsonString(
            samples: [sample],
            dailySummaries: summaries,
            sleepSegments: sleepSegments,
            sleepIntervals: sleepIntervals
        )

        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode(ExportPayloadFixture.self, from: data)
        XCTAssertEqual(decoded?.version, 8)
        XCTAssertEqual(decoded?.samples.count, 1)
        XCTAssertEqual(decoded?.samples.first?.cycleCount, 42)
        XCTAssertEqual(decoded?.dailySummaries.count, 1)
        XCTAssertEqual(decoded?.dailySummaries.first?.dayKey, "2026-08-30")
        // v3 起导出包含待机区间，v4 起包含睡眠边界，v5 起包含低估值与边界电源变化，往返不丢失。
        XCTAssertEqual(decoded?.sleepSegments?.count, 1)
        XCTAssertEqual(decoded?.sleepSegments?.first?.mode, .discharging)
        XCTAssertEqual(decoded?.sleepSegments?.first?.hasUnobservedSource, true)
        XCTAssertEqual(decoded?.sleepSegments?.first?.boundaryPowerChange, .batteryToAdapter)
        XCTAssertEqual(decoded?.sleepIntervals?.count, 1)
    }
}

private struct ExportPayloadFixture: Decodable {
    var version: Int
    var samples: [HistorySample]
    var dailySummaries: [DailySummary]
    var sleepSegments: [SleepSegment]?
    var sleepIntervals: [SleepInterval]?
}
