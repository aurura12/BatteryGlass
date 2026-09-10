import Foundation
import XCTest
@testable import BatteryGlass

final class HistoryExporterTests: XCTestCase {
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

    func testJSONRoundTripsSamplesAndSummaries() {
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
                mode: .discharging
            )
        ]
        let sleepIntervals = [
            SleepInterval(
                start: Date(timeIntervalSince1970: 1_700_000_000),
                end: Date(timeIntervalSince1970: 1_700_000_030)
            )
        ]
        let json = HistoryExporter.jsonString(
            samples: [sample],
            dailySummaries: summaries,
            sleepSegments: sleepSegments,
            sleepIntervals: sleepIntervals
        )

        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode(ExportPayloadFixture.self, from: data)
        XCTAssertEqual(decoded?.version, 4)
        XCTAssertEqual(decoded?.samples.count, 1)
        XCTAssertEqual(decoded?.samples.first?.cycleCount, 42)
        XCTAssertEqual(decoded?.dailySummaries.count, 1)
        XCTAssertEqual(decoded?.dailySummaries.first?.dayKey, "2026-08-30")
        // v3 起导出包含待机区间，v4 起包含睡眠边界，往返不丢失。
        XCTAssertEqual(decoded?.sleepSegments?.count, 1)
        XCTAssertEqual(decoded?.sleepSegments?.first?.mode, .discharging)
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
