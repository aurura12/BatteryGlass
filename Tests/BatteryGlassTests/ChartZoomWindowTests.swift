import Foundation
import XCTest
@testable import BatteryGlass

final class ChartZoomWindowTests: XCTestCase {
    private let bounds: ClosedRange<Double> = 100...1_000

    // MARK: - 默认态

    func testFullRangeIsNotZoomed() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 300)

        XCTAssertFalse(window.isZoomed)
        XCTAssertEqual(window.start, 100)
        XCTAssertEqual(window.span, 900)
        XCTAssertEqual(window.domain, 100...1_000)
        XCTAssertFalse(window.canPan)
    }

    func testLatestWindowAnchorsToUpperBound() {
        let window = ChartZoomWindow.latest(bounds: bounds, defaultSpan: 200, minimumSpan: 60)

        XCTAssertFalse(window.isZoomed)
        XCTAssertTrue(window.isAtLatestEdge)
        XCTAssertEqual(window.span, 200)
        XCTAssertEqual(window.start, 800)
        XCTAssertTrue(window.canPan)
    }

    // MARK: - 缩放

    func testZoomInHalvesSpanAroundCenterAnchor() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 300)
            .zoomed(by: 2, anchorFraction: 0.5)

        XCTAssertEqual(window.span, 450, accuracy: 0.001)
        XCTAssertEqual(window.domain, 325...775)
        XCTAssertTrue(window.isZoomed)
    }

    func testZoomAtLeftEdgeKeepsLowerBound() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 300)
            .zoomed(by: 2, anchorFraction: 0)

        XCTAssertEqual(window.start, 100, accuracy: 0.001)
        XCTAssertEqual(window.span, 450, accuracy: 0.001)
    }

    func testZoomAtRightEdgeKeepsUpperBound() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 300)
            .zoomed(by: 2, anchorFraction: 1)

        XCTAssertEqual(window.upper, 1_000, accuracy: 0.001)
        XCTAssertEqual(window.span, 450, accuracy: 0.001)
    }

    func testZoomClampsToMinimumSpan() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 60)
            .zoomed(by: 100, anchorFraction: 0.5)

        XCTAssertEqual(window.span, 60, accuracy: 0.001)
        XCTAssertTrue(window.canPan)
    }

    func testZoomOutClampsToFullRangeAndReportsNotZoomed() {
        let zoomed = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 60)
            .zoomed(by: 2, anchorFraction: 0.5)
        let restored = zoomed.zoomed(by: 0.1, anchorFraction: 0.5)

        XCTAssertEqual(restored.span, 900, accuracy: 0.001)
        XCTAssertEqual(restored.start, 100, accuracy: 0.001)
        XCTAssertFalse(restored.isZoomed)
    }

    func testZoomIgnoresNonPositiveOrNonFiniteMagnification() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 60)

        for magnification in [0.0, -1.0, .nan, .infinity] {
            XCTAssertEqual(window.zoomed(by: magnification, anchorFraction: 0.5), window)
        }
    }

    func testInvalidAnchorFractionDefaultsToCenter() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 60)

        XCTAssertEqual(
            window.zoomed(by: 2, anchorFraction: .nan),
            window.zoomed(by: 2, anchorFraction: 0.5)
        )
    }

    func testAnchorFractionIsClampedToUnitRange() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 60)

        XCTAssertEqual(
            window.zoomed(by: 2, anchorFraction: 5),
            window.zoomed(by: 2, anchorFraction: 1)
        )
        XCTAssertEqual(
            window.zoomed(by: 2, anchorFraction: -3),
            window.zoomed(by: 2, anchorFraction: 0)
        )
    }

    // MARK: - 平移

    func testPanMovesWindowAndClampsAtBothEdges() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 60)
            .zoomed(by: 2, anchorFraction: 0.5)   // start 325, span 450

        XCTAssertEqual(window.panned(by: -10_000).start, 100, accuracy: 0.001)
        XCTAssertEqual(window.panned(by: 10_000).start, 550, accuracy: 0.001)
        XCTAssertEqual(window.panned(by: 50).start, 375, accuracy: 0.001)
    }

    func testPanIsNoOpAtFullRange() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 60)

        XCTAssertEqual(window.panned(by: 100), window)
    }

    // MARK: - 重置

    func testResetPowerWindowReturnsToDefaultSpanAnchoredAtLatest() {
        let window = ChartZoomWindow.latest(bounds: bounds, defaultSpan: 200, minimumSpan: 60)
            .moved(toStart: 100)
            .reset()

        XCTAssertEqual(window.start, 800, accuracy: 0.001)
        XCTAssertEqual(window.span, 200, accuracy: 0.001)
        XCTAssertFalse(window.isZoomed)
    }

    func testResetDayWindowReturnsToFullBoundsLowerBound() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 60)
            .zoomed(by: 2, anchorFraction: 0.5)
            .reset()

        XCTAssertEqual(window.start, 100, accuracy: 0.001)
        XCTAssertEqual(window.span, 900, accuracy: 0.001)
    }

    // MARK: - 退化与边界

    func testDegenerateBoundsProducesSingletonWindowWithoutZoom() {
        let window = ChartZoomWindow.fullRange(bounds: 500...500, minimumSpan: 300)

        XCTAssertFalse(window.isZoomed)
        XCTAssertFalse(window.canPan)
        XCTAssertEqual(window.span, 0)
        XCTAssertGreaterThanOrEqual(window.domain.upperBound - window.domain.lowerBound, 1)
        XCTAssertEqual(window.zoomed(by: 2, anchorFraction: 0.5), window)
        XCTAssertEqual(window.panned(by: 100), window)
    }

    func testMinimumSpanLargerThanBoundsFallsBackToFullWidth() {
        let window = ChartZoomWindow.fullRange(bounds: 100...200, minimumSpan: 300)

        XCTAssertEqual(window.span, 100, accuracy: 0.001)
        XCTAssertFalse(window.isZoomed)
        // 无法进一步放大：最小宽度就是整段。
        XCTAssertEqual(window.zoomed(by: 2, anchorFraction: 0.5).span, 100, accuracy: 0.001)
    }

    func testDomainIsNeverDegenerate() {
        var window = ChartZoomWindow.fullRange(bounds: 100...1_000, minimumSpan: 60)
        window.span = 0
        window.start = 400

        XCTAssertGreaterThanOrEqual(window.domain.upperBound - window.domain.lowerBound, 1)
    }

    // MARK: - 重新基准化

    func testRebaseKeepsHistoricalWindowWhenNotAtEdge() {
        let window = ChartZoomWindow.latest(bounds: bounds, defaultSpan: 200, minimumSpan: 60)
            .moved(toStart: 100)   // 平移到历史区间，不再贴边

        let rebased = window.rebased(to: 100...1_200)

        XCTAssertEqual(rebased.start, 100, accuracy: 0.001)
        XCTAssertEqual(rebased.span, 200, accuracy: 0.001)
    }

    func testRebaseFollowsLatestWhenAtEdge() {
        let window = ChartZoomWindow.latest(bounds: bounds, defaultSpan: 200, minimumSpan: 60)

        let rebased = window.rebased(to: 100...1_200)

        XCTAssertEqual(rebased.start, 1_000, accuracy: 0.001)
        XCTAssertEqual(rebased.upper, 1_200, accuracy: 0.001)
    }

    func testRebaseFullRangeDayWindowTracksNewBounds() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 300)

        let rebased = window.rebased(to: 100...1_300)

        XCTAssertEqual(rebased.start, 100, accuracy: 0.001)
        XCTAssertEqual(rebased.span, 1_200, accuracy: 0.001)
        XCTAssertFalse(rebased.isZoomed)
    }

    func testRebaseZoomedDayWindowKeepsAbsoluteWindow() {
        let window = ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: 300)
            .zoomed(by: 2, anchorFraction: 0.5)   // start 325, span 450

        let rebased = window.rebased(to: 100...1_300)

        XCTAssertEqual(rebased.start, 325, accuracy: 0.001)
        XCTAssertEqual(rebased.span, 450, accuracy: 0.001)
    }

    // MARK: - ChartZoomGestureMath

    func testAnchorFractionMapsPlotRectToUnitRange() {
        let plot = CGRect(x: 0, y: 0, width: 100, height: 50)

        XCTAssertEqual(ChartZoomGestureMath.anchorFraction(for: CGPoint(x: 0, y: 10), in: plot), 0)
        XCTAssertEqual(ChartZoomGestureMath.anchorFraction(for: CGPoint(x: 50, y: 10), in: plot), 0.5)
        XCTAssertEqual(ChartZoomGestureMath.anchorFraction(for: CGPoint(x: 100, y: 10), in: plot), 1)
    }

    func testAnchorFractionAccountsForPlotOrigin() {
        let plot = CGRect(x: 30, y: 0, width: 100, height: 50)

        XCTAssertEqual(ChartZoomGestureMath.anchorFraction(for: CGPoint(x: 30, y: 10), in: plot), 0)
        XCTAssertEqual(ChartZoomGestureMath.anchorFraction(for: CGPoint(x: 80, y: 10), in: plot), 0.5)
    }

    func testAnchorFractionClampsOutsidePlotAndDegenerateRect() {
        let plot = CGRect(x: 0, y: 0, width: 100, height: 50)

        XCTAssertEqual(ChartZoomGestureMath.anchorFraction(for: CGPoint(x: -40, y: 0), in: plot), 0)
        XCTAssertEqual(ChartZoomGestureMath.anchorFraction(for: CGPoint(x: 400, y: 0), in: plot), 1)
        XCTAssertEqual(
            ChartZoomGestureMath.anchorFraction(for: CGPoint(x: 5, y: 0), in: .zero),
            0.5
        )
    }

    func testPanDeltaIsNegativeForRightwardDrag() {
        // 向右拖动 → 查看更早数据 → 起点减小；位移按 span/plotWidth 换算成数据单位。
        XCTAssertEqual(
            ChartZoomGestureMath.panDelta(points: 10, plotWidth: 100, span: 1_000),
            -100,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChartZoomGestureMath.panDelta(points: -10, plotWidth: 100, span: 1_000),
            100,
            accuracy: 0.001
        )
    }

    func testPanDeltaIsZeroForDegenerateWidth() {
        XCTAssertEqual(ChartZoomGestureMath.panDelta(points: 10, plotWidth: 0, span: 1_000), 0)
    }
}
