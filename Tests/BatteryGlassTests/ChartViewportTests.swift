import Foundation
import XCTest
@testable import BatteryGlass

final class ChartViewportTests: XCTestCase {
    func testKeepsOnlySamplesInsideDomain() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = [
            sample(at: start.addingTimeInterval(-5)),
            sample(at: start),
            sample(at: start.addingTimeInterval(5)),
            sample(at: start.addingTimeInterval(15))
        ]

        let visible = ChartViewport.visibleSamples(
            samples,
            in: start...start.addingTimeInterval(10)
        )

        XCTAssertEqual(
            visible.map(\.timestamp),
            [start, start.addingTimeInterval(5)]
        )
    }

    func testReturnsAllWhenUnderCap() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<5).map { sample(at: start.addingTimeInterval(Double($0))) }

        let visible = ChartViewport.visibleSamples(
            samples,
            in: start...start.addingTimeInterval(100),
            maximum: 800
        )

        XCTAssertEqual(visible, samples)
    }

    func testDownsamplesPreservingEndpoints() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<1_000).map { sample(at: start.addingTimeInterval(Double($0))) }

        let visible = ChartViewport.visibleSamples(
            samples,
            in: start...start.addingTimeInterval(10_000),
            maximum: 800
        )

        XCTAssertEqual(visible.count, 800)
        XCTAssertEqual(visible.first?.timestamp, samples.first?.timestamp)
        XCTAssertEqual(visible.last?.timestamp, samples.last?.timestamp)
    }

    func testReturnsEmptyWhenNoSamplesInDomainOrNoSamples() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = [sample(at: start)]

        XCTAssertTrue(
            ChartViewport.visibleSamples(
                samples,
                in: start.addingTimeInterval(100)...start.addingTimeInterval(200)
            ).isEmpty
        )
        XCTAssertTrue(
            ChartViewport.visibleSamples([], in: start...start.addingTimeInterval(10)).isEmpty
        )
    }

    // MARK: - Helpers

    private func sample(at timestamp: Date) -> HistorySample {
        HistorySample(
            timestamp: timestamp,
            power: 20,
            consumptionPowerW: 20,
            percent: 50,
            cycleCount: 1,
            healthPercent: 100
        )
    }
}
