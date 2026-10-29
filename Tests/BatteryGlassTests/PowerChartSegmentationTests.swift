import Foundation
import XCTest
@testable import BatteryGlass

final class PowerChartSegmentationTests: XCTestCase {
    func testContinuousSamplesStayInOneSegment() {
        let start = date("2026-08-27 10:00:00")
        let samples = (0..<3).map { sample(at: start.addingTimeInterval(Double($0) * 5), power: 10) }

        let segments = PowerChartSegmentation.splitByGaps(samples)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].count, 3)
    }

    func testGapBeyondThresholdBreaksIntoSegments() {
        let start = date("2026-08-27 10:00:00")
        let samples = [
            sample(at: start, power: 10),
            sample(at: start.addingTimeInterval(60), power: 20),
            sample(at: start.addingTimeInterval(400), power: 30)
        ]

        let segments = PowerChartSegmentation.splitByGaps(samples)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].map(\.timestamp), [start, start.addingTimeInterval(60)])
        XCTAssertEqual(segments[1].map(\.timestamp), [start.addingTimeInterval(400)])
    }

    func testGapAtThresholdBoundaryStaysConnected() {
        let start = date("2026-08-27 10:00:00")
        let samples = [
            sample(at: start, power: 10),
            sample(at: start.addingTimeInterval(300), power: 20)
        ]

        let segments = PowerChartSegmentation.splitByGaps(samples)

        XCTAssertEqual(segments.count, 1)
    }

    func testUnsortedInputIsSortedBeforeSplitting() {
        let start = date("2026-08-27 10:00:00")
        let samples = [
            sample(at: start.addingTimeInterval(400), power: 30),
            sample(at: start, power: 10)
        ]

        let segments = PowerChartSegmentation.splitByGaps(samples)

        XCTAssertEqual(segments.count, 2)
    }

    func testEmptyInputYieldsNoSegments() {
        XCTAssertTrue(PowerChartSegmentation.splitByGaps([]).isEmpty)
    }

    func testPowerTimelineHandlesOverlappingSleepAndBoundarySamples() {
        let start = date("2026-08-27 10:00:00")
        let offsets = [-10, 0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50]
        let samples = offsets.reversed().map {
            sample(at: start.addingTimeInterval(Double($0)), power: 10)
        }
        let intervals = [
            SleepInterval(start: start.addingTimeInterval(30), end: start.addingTimeInterval(35)),
            SleepInterval(start: start.addingTimeInterval(15), end: start.addingTimeInterval(30)),
            SleepInterval(start: start.addingTimeInterval(42), end: start.addingTimeInterval(44)),
            SleepInterval(start: start.addingTimeInterval(10), end: start.addingTimeInterval(20)),
            SleepInterval(start: start.addingTimeInterval(50), end: start.addingTimeInterval(40)),
            SleepInterval(start: start.addingTimeInterval(5), end: start.addingTimeInterval(5))
        ]

        let segments = PowerChartSegmentation.splitForPowerTimeline(samples, sleepIntervals: intervals)

        XCTAssertEqual(segments.map { $0.map { $0.timestamp.timeIntervalSince(start) } }, [
            [-10, 0, 5], [35, 40], [45, 50]
        ])
    }

    func testSleepIntervalFilteringKeepsEndBoundaryAndIgnoresInvalidIntervals() {
        let start = date("2026-08-27 10:00:00")
        let offsets = [5, 10, 19, 20, 29, 30, 35, 40, 45]
        let samples = offsets.map { sample(at: start.addingTimeInterval(Double($0)), power: 10) }
        let intervals = [
            SleepInterval(start: start.addingTimeInterval(20), end: start.addingTimeInterval(30)),
            SleepInterval(start: start.addingTimeInterval(10), end: start.addingTimeInterval(20)),
            SleepInterval(start: start.addingTimeInterval(5), end: start.addingTimeInterval(5)),
            SleepInterval(start: start.addingTimeInterval(40), end: start.addingTimeInterval(35))
        ]

        let filtered = PowerChartSegmentation.excludingSleepIntervals(samples, sleepIntervals: intervals)

        XCTAssertEqual(filtered.map { $0.timestamp.timeIntervalSince(start) }, [5, 30, 35, 40, 45])
    }

    func testGapSplittingUsesHalfOpenSleepIntervalBoundaries() {
        let start = date("2026-08-27 10:00:00")
        let samples = (0...5).map { sample(at: start.addingTimeInterval(Double($0) * 10), power: 10) }
        let intervals = [
            SleepInterval(start: start.addingTimeInterval(35), end: start.addingTimeInterval(40)),
            SleepInterval(start: start.addingTimeInterval(10), end: start.addingTimeInterval(20)),
            SleepInterval(start: start.addingTimeInterval(20), end: start.addingTimeInterval(20))
        ]

        let segments = PowerChartSegmentation.splitByGaps(samples, breakingAt: intervals)

        XCTAssertEqual(segments.map { $0.map { $0.timestamp.timeIntervalSince(start) } }, [
            [0, 10], [20, 30], [40, 50]
        ])
    }

    func testExcludingSleepSegmentsFiltersInternalSamples() {
        let start = date("2026-08-27 22:00:00")
        let samples = (0..<5).map { sample(at: start.addingTimeInterval(Double($0) * 10), power: 10) }
        let segment = SleepSegment(
            id: UUID(),
            start: start.addingTimeInterval(10),
            end: start.addingTimeInterval(30),
            energyKWh: 0.01,
            averagePowerW: 2,
            mode: .discharging
        )

        let filtered = PowerChartSegmentation.excludingSleepSegments(samples, sleepSegments: [segment])

        XCTAssertEqual(filtered.map(\.timestamp), [
            start,
            start.addingTimeInterval(40)
        ])
    }

    func testExcludingSleepSegmentsKeepsAllWithoutSegments() {
        let start = date("2026-08-27 22:00:00")
        let samples = (0..<3).map { sample(at: start.addingTimeInterval(Double($0) * 10), power: 10) }

        let filtered = PowerChartSegmentation.excludingSleepSegments(samples, sleepSegments: [])

        XCTAssertEqual(filtered.count, 3)
    }

    private func sample(at timestamp: Date, power: Double) -> HistorySample {
        HistorySample(
            timestamp: timestamp,
            power: 0,
            consumptionPowerW: power,
            percent: 50,
            cycleCount: 1,
            healthPercent: 100
        )
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }
}
