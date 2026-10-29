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

    func testTimelineCoordinatesStayInverseAcrossManyBreaks() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var segments: [[HistorySample]] = []
        for index in 0..<50 {
            let segmentStart = start.addingTimeInterval(Double(index) * 7_200)
            segments.append([
                historySample(at: segmentStart),
                historySample(at: segmentStart.addingTimeInterval(55))
            ])
        }
        let timeline = PowerChartTimeline(segments: segments)

        for segment in segments {
            let first = segment[0]
            // 段首位于断点结束处，反解应当回到自身。
            XCTAssertEqual(
                timeline.date(for: timeline.position(for: first.timestamp)).timeIntervalSince1970,
                first.timestamp.timeIntervalSince1970,
                accuracy: 0.001
            )
        }
        for (segment, next) in zip(segments, segments.dropFirst()) {
            // 段尾恰好是断点起点、下一段段首是断点终点：压缩后两者同位，
            // 反解会落到断点结束，这是压缩时间轴本身的歧义，不是映射错误。
            XCTAssertEqual(
                timeline.position(for: segment[1].timestamp),
                timeline.position(for: next[0].timestamp),
                accuracy: 0.001
            )
        }
        // 断点内的时刻同样压缩到断点起点。
        let insideBreak = start.addingTimeInterval(3_600)
        XCTAssertEqual(
            timeline.position(for: insideBreak),
            timeline.position(for: start.addingTimeInterval(55))
        )
    }

    func testPowerSegmentCacheReusesResultUntilWindowChanges() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<100).map {
            historySample(at: start.addingTimeInterval(Double($0) * 60))
        }
        let data = PowerChartData(samples: samples, maximumDisplayedSamples: 800)
        let cache = PowerChartSegmentCache()
        let fullDay = start...start.addingTimeInterval(10_000)

        let first = cache.segments(
            chartData: data, sleepIntervals: [], isZoomed: false, dateDomain: fullDay
        )
        let second = cache.segments(
            chartData: data, sleepIntervals: [], isZoomed: false, dateDomain: fullDay
        )
        XCTAssertEqual(
            first.rendered.map { $0.map(\.id) },
            second.rendered.map { $0.map(\.id) }
        )
        XCTAssertFalse(first.rendered.isEmpty)

        // 窗口变窄后必须重新筛选，不能返回上一次的整日结果。
        let narrow = start...start.addingTimeInterval(1_200)
        let zoomed = cache.segments(
            chartData: data, sleepIntervals: [], isZoomed: true, dateDomain: narrow
        )
        XCTAssertLessThan(
            zoomed.rendered.flatMap { $0 }.count,
            first.rendered.flatMap { $0 }.count
        )
    }

    func testLevelSegmentCacheCachesFillAndBridgesForSameWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = (0..<60).map {
            historySample(at: start.addingTimeInterval(Double($0) * 60))
        }
        let data = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 800)
        let cache = BatteryLevelSegmentCache()
        let bounds: ClosedRange<Double> =
            start.timeIntervalSinceReferenceDate...start.addingTimeInterval(4_000).timeIntervalSinceReferenceDate
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 60)
        let domain = start...start.addingTimeInterval(4_000)

        let first = cache.data(chartData: data, window: window, domain: domain)
        let second = cache.data(chartData: data, window: window, domain: domain)
        XCTAssertEqual(first.fillSamples.map { $0.id }, second.fillSamples.map { $0.id })
        XCTAssertEqual(first.bridges, second.bridges)
        XCTAssertEqual(first.yDomain, second.yDomain)
        XCTAssertFalse(first.fillSamples.isEmpty)
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

    func testCachesRebuildWhenSampleContentVersionChanges() {
        let start = Date(timeIntervalSince1970: 1_000)
        var samples = (0..<20).map {
            historySample(at: start.addingTimeInterval(Double($0) * 60))
        }
        let dayCache = TodaySamplesCache()
        let dataCache = PowerChartDataCache()
        let levelCache = BatteryLevelChartDataCache()
        let segmentCache = PowerChartSegmentCache()
        let levelSegmentCache = BatteryLevelSegmentCache()
        let fullDay = start...start.addingTimeInterval(10_000)

        XCTAssertEqual(dayCache.samples(from: samples, day: start, version: 0).count, 20)

        // 诊断回填只替换读数，样本数量与末条 id 都不变：只能靠版本号判定失效。
        samples[3].consumptionPowerW = 99
        XCTAssertEqual(
            dayCache.samples(from: samples, day: start, version: 0)[3].consumptionPowerW,
            20,
            "版本号不变时应继续复用缓存"
        )
        XCTAssertEqual(dayCache.samples(from: samples, day: start, version: 1)[3].consumptionPowerW, 99)

        XCTAssertEqual(dataCache.data(for: samples, sleepIntervals: [], version: 0).sourceVersion, 0)
        XCTAssertEqual(dataCache.data(for: samples, sleepIntervals: [], version: 1).sourceVersion, 1)
        XCTAssertEqual(levelCache.data(for: samples, version: 1).sourceVersion, 1)

        let levelData = BatteryLevelChartData(samples: samples, maximumDisplayedSamples: 800, sourceVersion: 1)
        let end = start.addingTimeInterval(10_000).timeIntervalSinceReferenceDate
        let bounds: ClosedRange<Double> = start.timeIntervalSinceReferenceDate...end
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 60)
        let levelResult = levelSegmentCache.data(chartData: levelData, window: window, domain: fullDay)
        XCTAssertEqual(levelResult.segments.flatMap { $0 }.count, 20)

        // 段缓存同样按源版本失效：旧版本的缓存不能继续喂给新数据。
        let oldData = PowerChartData(samples: samples, maximumDisplayedSamples: 800, sourceVersion: 0)
        let newData = PowerChartData(samples: samples, maximumDisplayedSamples: 800, sourceVersion: 1)
        _ = segmentCache.segments(chartData: oldData, sleepIntervals: [], isZoomed: false, dateDomain: fullDay)
        let refreshed = segmentCache.segments(
            chartData: newData, sleepIntervals: [], isZoomed: false, dateDomain: fullDay
        )
        XCTAssertEqual(refreshed.rendered.flatMap { $0 }[3].consumptionPowerW, 99)
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
