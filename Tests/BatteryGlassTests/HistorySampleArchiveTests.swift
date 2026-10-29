import Foundation
import SQLite3
import XCTest
@testable import BatteryGlass

final class HistorySampleArchiveTests: XCTestCase {
    func testMinuteUpsertsKeepLatestPointAndAreIdempotent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = HistorySampleArchive(fileURL: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_040)
        let first = sample(at: start)
        let last = sample(at: start.addingTimeInterval(55))
        let next = sample(at: start.addingTimeInterval(60))
        try archive.store([last, first, next])
        try archive.store([first, last, next])

        XCTAssertEqual(try archive.allSamples(), [last, next])
    }

    func testDayQueriesRespectTimeZoneAndExcludeNextMidnight() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = HistorySampleArchive(fileURL: directory.appendingPathComponent("history.sqlite"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))!
        let points = [-60.0, 0, 60, 86_340, 86_400].map { sample(at: day.addingTimeInterval($0)) }
        try archive.store(points)

        XCTAssertEqual(try archive.samples(forDay: day, calendar: calendar), Array(points[1...3]))
        XCTAssertEqual(try archive.availableDays(calendar: calendar), [day.addingTimeInterval(-86_400), day, day.addingTimeInterval(86_400)])
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3_600)!
        XCTAssertEqual(
            try archive.availableDays(calendar: calendar),
            HistoryRetention.availableDays(from: points, calendar: calendar)
        )
    }

    func testDayQueriesRespectDaylightSavingBoundaries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = HistorySampleArchive(fileURL: directory.appendingPathComponent("history.sqlite"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        XCTAssertEqual(end.timeIntervalSince(day), 25 * 3_600)
        let points = [sample(at: day), sample(at: end.addingTimeInterval(-60)), sample(at: end)]
        try archive.store(points)
        XCTAssertEqual(try archive.samples(forDay: day, calendar: calendar), Array(points.prefix(2)))
    }

    func testFailedBatchRollsBackInsteadOfPartiallyArchiving() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = HistorySampleArchive(fileURL: directory.appendingPathComponent("history.sqlite"))
        let first = sample(at: Date(timeIntervalSince1970: 1_700_000_040))
        try archive.store([first])
        let second = sample(at: first.timestamp.addingTimeInterval(60))
        var invalid = sample(at: first.timestamp.addingTimeInterval(120))
        invalid.power = .nan
        XCTAssertThrowsError(try archive.store([second, invalid]))
        XCTAssertEqual(try archive.allSamples(), [first])
    }

    func testCorruptPayloadIsSkippedInsteadOfFailingWholeDay() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let archive = HistorySampleArchive(fileURL: databaseURL)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        try archive.store([
            sample(at: day.addingTimeInterval(60)),
            sample(at: day.addingTimeInterval(120))
        ])

        // 把一条 payload 改成非法 JSON，模拟写入中断留下的坏行。
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let corrupt = "UPDATE samples SET payload = X'7B' "
            + "WHERE rowid = (SELECT rowid FROM samples LIMIT 1)"
        XCTAssertEqual(sqlite3_exec(database, corrupt, nil, nil, nil), SQLITE_OK)

        XCTAssertEqual(try archive.samples(forDay: day).count, 1)
        XCTAssertEqual(try archive.allSamples().count, 1)
    }

    func testLiveSamplesKeepNativeResolutionAndReplaceSameTimestamp() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = HistorySampleArchive(fileURL: directory.appendingPathComponent("history.sqlite"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 10))!
        let first = sample(at: day)
        let second = sample(at: day.addingTimeInterval(5))

        try archive.storeLiveSamples([first, second])
        XCTAssertEqual(try archive.liveSamples(forDay: day, calendar: calendar), [first, second])
        XCTAssertEqual(try archive.latestLiveTimestamp(), second.timestamp)
        XCTAssertEqual(try archive.lastLiveSample(before: day.addingTimeInterval(5)), first)
        XCTAssertNil(try archive.lastLiveSample(before: day))
        XCTAssertTrue(try archive.allSamples().isEmpty, "当天样本不应写进分钟表")

        // 同一时间戳重复写入是幂等的（后台写盘与 flush 可能重叠）。
        try archive.storeLiveSamples([first, second])
        XCTAssertEqual(try archive.liveSamples(forDay: day, calendar: calendar).count, 2)
    }

    func testLiveSamplesPreserveSubsecondTimestamps() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = HistorySampleArchive(fileURL: directory.appendingPathComponent("history.sqlite"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 10))!
        let precise = sample(at: day.addingTimeInterval(0.375))

        try archive.storeLiveSamples([precise])
        // ISO 8601 payload 不带小数秒，读取必须以行主键为准：否则按时间戳回写会
        // 因微秒差新增一行，而不是覆盖原记录。
        XCTAssertEqual(try archive.liveSamples(forDay: day, calendar: calendar), [precise])
        XCTAssertEqual(try archive.lastLiveSample(before: day.addingTimeInterval(60)), precise)
    }

    func testDuplicateRepairKeepsConflictingOrUnrelatedRows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = HistorySampleArchive(fileURL: directory.appendingPathComponent("history.sqlite"))
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        var original = sample(at: day.addingTimeInterval(0.375))
        original.consumptionPowerW = 20
        var conflicting = original
        conflicting.timestamp = day
        conflicting.consumptionPowerW = 42
        let unrelated = sample(at: day.addingTimeInterval(5.5))
        try archive.storeLiveSamples([original, conflicting, unrelated])

        try archive.removeTemperatureHistory()
        try archive.repairDuplicateLiveSamples()
        try archive.repairDuplicateLiveSamples()

        XCTAssertEqual(try archive.liveSamples(forDay: day), [conflicting, original, unrelated])
    }

    func testArchivingLiveSamplesDowngradesToMinuteRowsAndDeletesLive() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = HistorySampleArchive(fileURL: directory.appendingPathComponent("history.sqlite"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 27))!
        let points = [5.0, 10, 65, 70].map { sample(at: day.addingTimeInterval($0)) }
        try archive.storeLiveSamples(points)

        XCTAssertEqual(try archive.archiveLiveSamples(before: day.addingTimeInterval(3_600)), 4)
        XCTAssertTrue(try archive.liveSamples(forDay: day, calendar: calendar).isEmpty)
        // 分钟桶各保留最后一条：第 1 分钟留 +10s，第 2 分钟留 +70s。
        XCTAssertEqual(
            try archive.samples(forDay: day, calendar: calendar).map(\.timestamp),
            [points[1].timestamp, points[3].timestamp]
        )
        XCTAssertNil(try archive.latestLiveTimestamp())
    }

    func testLatestLiveTimestampIsNilWithoutLiveTable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = HistorySampleArchive(fileURL: directory.appendingPathComponent("missing.sqlite"))
        XCTAssertNil(try archive.latestLiveTimestamp())
        XCTAssertNil(try archive.lastLiveSample(before: Date()))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryGlassArchive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sample(at timestamp: Date) -> HistorySample {
        HistorySample(timestamp: timestamp, power: -20, consumptionPowerW: 20, percent: 50, cycleCount: 1, healthPercent: 98)
    }
}
