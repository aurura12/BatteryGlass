import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import BatteryGlass

final class PowerChartInteractionTests: XCTestCase {
    @MainActor
    func testDailyEnergyXAxisKeepsFiveReadableLabelsAtDashboardWidth() {
        let summaries = (0..<14).map { offset in
            summary(
                at: BatteryFormatters.dayKey(
                    for: Calendar.current.date(
                        byAdding: .day,
                        value: offset,
                        to: BatteryFormatters.dayKeyDate("2026-08-24")!
                    )!
                ),
                energy: 0.2 + Double(offset) * 0.01
            )
        }
        let chart = DailyEnergyComparisonChart(
            summaries: summaries,
            range: .constant(.fourteen)
        )
        let hostingView = NSHostingView(
            rootView: chart
                .frame(width: 344, height: 340)
                .background(Color.white)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 344, height: 340)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        // 固定浅色外观：状态色与图表配色是随明暗外观切换的动态颜色，
        // 深色模式下同一份视图会渲染出不同的像素，判定结果不可复现。
        window.appearance = NSAppearance(named: .aqua)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("每日耗电量图表未生成可测试的图像")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let barBottom = blueBarBottom(in: bitmap) else {
            XCTFail("未找到柱状图数据柱")
            return
        }
        // 只统计「蓝柱一直延伸到基线」的列：图表上方的指标数值同样用主题色渲染，
        // 按颜色统一判定会把它当成额外的柱子。
        let barCenters = blueBarCenters(in: bitmap, baseline: barBottom)
        XCTAssertEqual(barCenters.count, 14)
        guard let firstBar = barCenters.first, let lastBar = barCenters.last,
              barCenters.count > 13 else {
            XCTFail("柱状图数据柱数量异常：\(barCenters.count)")
            return
        }
        let labelColumnRanges = axisLabelColumnRanges(in: bitmap, after: barBottom)
            .filter {
                let center = ($0.lowerBound + $0.upperBound) / 2
                return (firstBar - 30)...(lastBar + 30) ~= center
            }
        let labelCenters = labelColumnRanges.map { ($0.lowerBound + $0.upperBound) / 2 }
        let labeledBarCenters = [0, 3, 7, 10, 13].map { barCenters[$0] }
        let pixelScale = CGFloat(bitmap.pixelsWide) / hostingView.bounds.width
        XCTAssertEqual(labelCenters.count, 5)
        // 后面的断言按索引取值：像素判定偶发失败时先返回，否则会把整个测试进程打断，
        // 后续用例（以及其它测试类）都跑不到。
        guard labelCenters.count == 5, labelCenters.count == labeledBarCenters.count else {
            XCTFail("日期标签数量异常：\(labelCenters.count)")
            return
        }
        for (labelCenter, barCenter) in zip(labelCenters, labeledBarCenters) {
            XCTAssertEqual(labelCenter, barCenter, accuracy: Int(ceil(1.5 * pixelScale)))
        }
        XCTAssertGreaterThanOrEqual(
            CGFloat(labelColumnRanges[0].count) / pixelScale,
            20,
            "首个日期标签被截断"
        )
    }

    func testDailyDetailsStartsCollapsedAndToggles() {
        var state = DailyDetailsDisclosureState()

        XCTAssertFalse(state.isExpanded)

        state.toggle()
        XCTAssertTrue(state.isExpanded)

        state.toggle()
        XCTAssertFalse(state.isExpanded)
    }

    func testEnergyGroupingUsesMatchingChartTitle() {
        XCTAssertEqual(EnergyGrouping.day.chartTitle, "每日耗电量")
        XCTAssertEqual(EnergyGrouping.week.chartTitle, "每周耗电量")
        XCTAssertEqual(EnergyGrouping.month.chartTitle, "每月耗电量")
    }

    func testNearestSampleIsSelectedForHoverTime() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = [
            sample(at: first, power: 10),
            sample(at: first.addingTimeInterval(5), power: 20),
            sample(at: first.addingTimeInterval(10), power: 30)
        ]

        let nearest = PowerChartInteraction.nearestSample(
            to: first.addingTimeInterval(7),
            from: samples
        )

        XCTAssertEqual(nearest?.consumptionPowerW, 20)
    }

    func testNearestSampleHandlesHoverOutsideSampleRange() {
        let first = Date(timeIntervalSince1970: 1_000)
        let samples = [
            sample(at: first, power: 10),
            sample(at: first.addingTimeInterval(5), power: 20)
        ]

        XCTAssertEqual(
            PowerChartInteraction.nearestSample(
                to: first.addingTimeInterval(-10),
                from: samples
            )?.consumptionPowerW,
            10
        )
        XCTAssertEqual(
            PowerChartInteraction.nearestSample(
                to: first.addingTimeInterval(20),
                from: samples
            )?.consumptionPowerW,
            20
        )
    }

    func testDailyTooltipAnchorUsesTheHoveredBarsPlotCoordinates() {
        let plotFrame = CGRect(x: 24, y: 12, width: 300, height: 138)

        let anchor = PowerChartInteraction.dailyTooltipAnchor(
            plotFrame: plotFrame,
            xPosition: 180,
            yPosition: 42
        )

        XCTAssertEqual(anchor.x, 204)
        XCTAssertEqual(anchor.y, 54)
    }

    func testDailyTooltipAnchorClampsXInsidePlotFrame() {
        let plotFrame = CGRect(x: 24, y: 12, width: 300, height: 138)

        let leftEdge = PowerChartInteraction.dailyTooltipAnchor(
            plotFrame: plotFrame,
            xPosition: 0,
            yPosition: 20
        )
        let rightEdge = PowerChartInteraction.dailyTooltipAnchor(
            plotFrame: plotFrame,
            xPosition: 300,
            yPosition: 20
        )

        XCTAssertEqual(leftEdge.x, plotFrame.minX + 70)
        XCTAssertEqual(rightEdge.x, plotFrame.maxX - 70)
    }

    func testDailyEnergyMetricOrderPlacesAverageBeforeTotal() {
        XCTAssertEqual(
            DailyEnergyMetricOrder.titles,
            ["今日", "日均", "总计"]
        )
    }

    func testTotalDailyEnergySumsOnlyCompleteSummaries() {
        let first = Date(timeIntervalSince1970: 1_000)
        let summaries = [
            summary(at: first, dayKey: "2026-08-28", energy: 0.136),
            summary(at: first.addingTimeInterval(86_400), dayKey: "2026-08-29", energy: nil),
            summary(at: first.addingTimeInterval(172_800), dayKey: "2026-08-30", energy: 0.238)
        ]

        XCTAssertEqual(PowerChartInteraction.totalDailyEnergy(from: summaries), 0.374)
    }

    private func sample(at timestamp: Date, power: Double) -> HistorySample {
        HistorySample(
            timestamp: timestamp,
            power: power,
            consumptionPowerW: power,
            percent: 50,
            cycleCount: 1,
            healthPercent: 100
        )
    }

    private func summary(at date: Date, dayKey: String, energy: Double?) -> DailySummary {
        DailySummary(
            dayKey: dayKey,
            date: date,
            sampleCount: 1,
            maxCycleCount: 1,
            minHealthPercent: 100,
            energyKWh: energy,
            averagePower: 10,
            maxPower: 10,
            minPower: 10
        )
    }

    private func summary(at dayKey: String, energy: Double) -> DailySummary {
        summary(
            at: BatteryFormatters.dayKeyDate(dayKey)!,
            dayKey: dayKey,
            energy: energy
        )
    }

    /// 数据柱的列中心。只看基线以上、且蓝色一直延伸到基线的列：
    /// 图表上方的指标数值用的是同一主题色，坐标轴标签的字形边缘又会被次像素抗锯齿染出蓝色，
    /// 两者都会混进按颜色统计的结果里，必须按「是否落到基线」区分。
    private func blueBarCenters(in bitmap: NSBitmapImageRep, baseline: Int) -> [Int] {
        groupedColumns(
            (0..<bitmap.pixelsWide).filter { x in
                let rows = blueRows(at: x, in: bitmap).filter { $0 <= baseline }
                guard let first = rows.first, let last = rows.last else { return false }
                return rows.count >= 24 && last - first >= 30 && last >= baseline - 6
            }
        )
    }

    private func blueBarBottom(in bitmap: NSBitmapImageRep) -> Int? {
        let barColumns = (0..<bitmap.pixelsWide).filter { x in
            let rows = blueRows(at: x, in: bitmap)
            guard let first = rows.first, let last = rows.last else { return false }
            return rows.count >= 24 && last - first >= 30
        }
        return barColumns.compactMap { x in
            let runs = contiguousRuns(blueRows(at: x, in: bitmap))
            return runs.max { $0.count < $1.count }?.last
        }.max()
    }

    private func axisLabelColumnRanges(
        in bitmap: NSBitmapImageRep,
        after barBottom: Int
    ) -> [ClosedRange<Int>] {
        let scanRange = (barBottom + 12)..<min(bitmap.pixelsHigh, barBottom + 42)
        return groupedColumns(in: bitmap, rows: scanRange, where: { color in
            guard let color = color.usingColorSpace(.deviceRGB) else { return false }
            let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
            let saturation = max(color.redComponent, color.greenComponent, color.blueComponent) -
                min(color.redComponent, color.greenComponent, color.blueComponent)
            return brightness < 0.85 && saturation < 0.2
        }, minimumPixels: 1)
    }

    private func blueRows(at x: Int, in bitmap: NSBitmapImageRep) -> [Int] {
        (0..<bitmap.pixelsHigh).filter { y in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                return false
            }
            return color.blueComponent > 0.55 &&
                color.blueComponent > color.redComponent * 1.4 &&
                color.greenComponent > color.redComponent * 1.4
        }
    }

    private func contiguousRuns(_ rows: [Int]) -> [[Int]] {
        var runs: [[Int]] = []
        for row in rows {
            if let lastValue = runs.last?.last, row - lastValue <= 1 {
                runs[runs.count - 1].append(row)
            } else {
                runs.append([row])
            }
        }
        return runs
    }

    private func groupedColumns(_ columns: [Int]) -> [Int] {
        var groups: [[Int]] = []
        for column in columns {
            if let lastValue = groups.last?.last, column - lastValue <= 6 {
                groups[groups.count - 1].append(column)
            } else {
                groups.append([column])
            }
        }
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            return (first + last) / 2
        }
    }

    private func groupedColumns(
        in bitmap: NSBitmapImageRep,
        rows: Range<Int> = 0..<Int.max,
        where matches: (NSColor) -> Bool,
        minimumPixels: Int
    ) -> [ClosedRange<Int>] {
        let validRows = rows.lowerBound..<min(rows.upperBound, bitmap.pixelsHigh)
        let columns = (0..<bitmap.pixelsWide).filter { x in
            validRows.reduce(into: 0) { count, y in
                if let color = bitmap.colorAt(x: x, y: y), matches(color) {
                    count += 1
                }
            } >= minimumPixels
        }

        var groups: [[Int]] = []
        for column in columns {
            if let lastValue = groups.last?.last, column - lastValue <= 6 {
                groups[groups.count - 1].append(column)
            } else {
                groups.append([column])
            }
        }
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            return first...last
        }
    }
}
