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

    func testCSVIncludesHeaderAndRows() {
        let csv = HistoryExporter.csvString(samples: [makeSample()])

        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "时间,功率(W),消耗功率(W),电量(%),循环次数,健康度(%)")
        XCTAssertTrue(lines[1].contains("12.3"))
        XCTAssertTrue(lines[1].contains("88")) // percent 四舍五入
        XCTAssertTrue(lines[1].contains("42"))
        XCTAssertTrue(lines[1].contains("95.5"))
    }

    func testCSVLeavesNilFieldsEmpty() {
        let sample = makeSample(consumptionPowerW: nil, healthPercent: nil)
        let csv = HistoryExporter.csvString(samples: [sample])
        let dataLine = csv.split(separator: "\n")[1]

        // 消耗功率与健康度列为空：第 3、6 个字段为空字符串。
        let fields = dataLine.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields[2], "")
        XCTAssertEqual(fields[5], "")
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
        let json = HistoryExporter.jsonString(samples: [sample], dailySummaries: summaries)

        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode(ExportPayloadFixture.self, from: data)
        XCTAssertEqual(decoded?.version, 2)
        XCTAssertEqual(decoded?.samples.count, 1)
        XCTAssertEqual(decoded?.samples.first?.cycleCount, 42)
        XCTAssertEqual(decoded?.dailySummaries.count, 1)
        XCTAssertEqual(decoded?.dailySummaries.first?.dayKey, "2026-08-30")
    }
}

private struct ExportPayloadFixture: Decodable {
    var version: Int
    var samples: [HistorySample]
    var dailySummaries: [DailySummary]
}
