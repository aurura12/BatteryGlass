import Foundation
import XCTest
@testable import BatteryGlass

final class PowerChartDataTests: XCTestCase {
    func testScrollBoundsUseChartCoordinates() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = [
            historySample(at: first),
            historySample(at: first.addingTimeInterval(10_000))
        ]
        let timeline = PowerChartTimeline(segments: [samples])

        let bounds = PowerChartWindow.scrollBounds(timeline: timeline, samples: samples)

        // 无断点时曲线坐标等于真实秒数，末端留出一屏。
        XCTAssertEqual(bounds?.lowerBound, timeline.position(for: first))
        XCTAssertEqual(
            bounds?.upperBound,
            timeline.position(for: first.addingTimeInterval(10_000)) - 7_200
        )
    }

    func testScrollBoundsAbsentWhenDataFitsOneScreen() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = [
            historySample(at: first),
            historySample(at: first.addingTimeInterval(3_600))
        ]

        XCTAssertNil(
            PowerChartWindow.scrollBounds(
                timeline: PowerChartTimeline(segments: [samples]),
                samples: samples
            )
        )
    }

    func testVisibleChartDomainKeepsConstantWidthWhileScrolling() {
        let end = 100_000.0

        let first = PowerChartWindow.visibleChartDomain(startingAt: 0, end: end)
        let later = PowerChartWindow.visibleChartDomain(startingAt: 3_600, end: end)

        // 滑动时窗口等宽平移，横向比例不变（修复「左右滑动有拉伸感」）。
        XCTAssertEqual(first.upperBound - first.lowerBound, 7_200, accuracy: 0.001)
        XCTAssertEqual(later.upperBound - later.lowerBound, 7_200, accuracy: 0.001)
    }

    func testVisibleChartDomainClampsToLatestData() {
        let domain = PowerChartWindow.visibleChartDomain(startingAt: 1_000, end: 5_000)

        XCTAssertEqual(domain.lowerBound, 1_000)
        XCTAssertEqual(domain.upperBound, 5_000)
    }

    func testScrollFollowsLatestWhenUserIsAtPreviousEnd() {
        XCTAssertTrue(
            PowerChartWindow.shouldFollowLatest(currentPosition: 7_200, previousEnd: 7_200)
        )
    }

    func testScrollDoesNotFollowLatestAfterUserMovesToHistory() {
        XCTAssertFalse(
            PowerChartWindow.shouldFollowLatest(currentPosition: 3_600, previousEnd: 7_200)
        )
    }

    func testChartDataFiltersMissingPowerAndDownsamplesToLimit() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<6).map { index in
            HistorySample(
                timestamp: first.addingTimeInterval(Double(index)),
                power: Double(index),
                consumptionPowerW: index.isMultiple(of: 2) ? Double(index) : nil,
                percent: 50,
                cycleCount: 1,
                healthPercent: 100
            )
        }

        let data = PowerChartData(samples: samples, maximumDisplayedSamples: 2)

        XCTAssertEqual(data.energySamples.map(\.consumptionPowerW), [0, 2, 4])
        XCTAssertEqual(data.chartSamples.map(\.consumptionPowerW), [0, 4])
    }

    func testChartDataKeepsAllSamplesWhenUnderLimit() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = [
            HistorySample(
                timestamp: first,
                power: 10,
                consumptionPowerW: 10,
                percent: 50,
                cycleCount: 1,
                healthPercent: 100
            ),
            HistorySample(
                timestamp: first.addingTimeInterval(5),
                power: 20,
                consumptionPowerW: 20,
                percent: 50,
                cycleCount: 1,
                healthPercent: 100
            )
        ]

        let data = PowerChartData(samples: samples, maximumDisplayedSamples: 10)

        XCTAssertEqual(data.chartSamples, data.energySamples)
    }

    func testChartSamplesExcludePointsOutsideVisibleDomain() {
        let start = Date(timeIntervalSince1970: 1_000)
        let domain = start...start.addingTimeInterval(10)
        let samples = [
            historySample(at: start.addingTimeInterval(-5)),
            historySample(at: start),
            historySample(at: start.addingTimeInterval(5)),
            historySample(at: start.addingTimeInterval(15))
        ]

        XCTAssertEqual(
            PowerChartWindow.samples(in: domain, from: samples).map(\.timestamp),
            [start, start.addingTimeInterval(5)]
        )
    }

    func testTimelineCollapsesBreakToZeroWidth() {
        let first = Date(timeIntervalSince1970: 1_000)
        let timeline = PowerChartTimeline(segments: twoSegmentsSplitByOneHour(from: first))

        XCTAssertEqual(timeline.breaks.count, 1)
        XCTAssertEqual(timeline.breaks[0].duration, 3_600)

        // 断点不占宽度：前段末与后段首落在同一个图表坐标上。
        let jump = timeline.position(for: first.addingTimeInterval(60))
        XCTAssertEqual(
            timeline.position(for: first.addingTimeInterval(3_660)),
            jump,
            accuracy: 0.001
        )

        // 断点内部任意时刻都塌缩到跳变点。
        XCTAssertEqual(
            timeline.position(for: first.addingTimeInterval(1_800)),
            jump,
            accuracy: 0.001
        )

        // 跳变点之后仍按真实秒数推进，只是整体前移了被跳过的时长。
        XCTAssertEqual(
            timeline.position(for: first.addingTimeInterval(3_720)),
            jump + 60,
            accuracy: 0.001
        )
    }

    func testTimelineDateForPositionResumesAtBreakEnd() {
        let first = Date(timeIntervalSince1970: 1_000)
        let timeline = PowerChartTimeline(segments: twoSegmentsSplitByOneHour(from: first))
        let jump = timeline.position(for: first.addingTimeInterval(60))

        XCTAssertEqual(timeline.date(for: jump), first.addingTimeInterval(3_660))
        XCTAssertEqual(timeline.date(for: jump + 30), first.addingTimeInterval(3_690))
        XCTAssertEqual(
            timeline.date(for: timeline.position(for: first.addingTimeInterval(30))),
            first.addingTimeInterval(30)
        )
    }

    func testTimelineBreakDetectionUsesRealTime() {
        let first = Date(timeIntervalSince1970: 1_000)
        let timeline = PowerChartTimeline(segments: twoSegmentsSplitByOneHour(from: first))

        XCTAssertTrue(timeline.isInsideBreak(first.addingTimeInterval(1_800)))
        XCTAssertFalse(timeline.isInsideBreak(first.addingTimeInterval(30)))
        XCTAssertFalse(timeline.isInsideBreak(first.addingTimeInterval(3_660)))
    }

    private func twoSegmentsSplitByOneHour(from first: Date) -> [[HistorySample]] {
        [
            [
                historySample(at: first),
                historySample(at: first.addingTimeInterval(60))
            ],
            [
                historySample(at: first.addingTimeInterval(3_660)),
                historySample(at: first.addingTimeInterval(3_720))
            ]
        ]
    }

    private func historySample(at timestamp: Date) -> HistorySample {
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
