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
