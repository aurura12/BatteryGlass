import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import BatteryGlass

final class PowerChartInteractionTests: XCTestCase {
    @MainActor
    func testDailyEnergyXAxisLabelsAreCenteredOnBars() {
        let summaries = [
            summary(at: "2026-08-26", energy: 0.1),
            summary(at: "2026-08-27", energy: 0.15),
            summary(at: "2026-08-28", energy: 0.2),
            summary(at: "2026-08-29", energy: 0.25),
            summary(at: "2026-08-30", energy: 0.3)
        ]
        let chart = DailyEnergyComparisonChart(
            summaries: summaries,
            range: .constant(.fourteen)
        )
        let hostingView = NSHostingView(
            rootView: chart
                .frame(width: 600, height: 340)
                .background(Color.white)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 340)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("每日耗电量图表未生成可测试的图像")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let barCenters = blueBarCenters(in: bitmap)
        guard let firstBarCenter = barCenters.first else {
            XCTFail("未找到柱状图数据柱")
            return
        }
        guard let barBottom = blueBarBottom(in: bitmap) else {
            XCTFail("未找到柱状图数据柱")
            return
        }
        let labelCenters = axisLabelCenters(in: bitmap, after: barBottom)
            .filter { $0 >= firstBarCenter }

        let interiorBarCenters = Array(barCenters.dropFirst().dropLast())
        XCTAssertEqual(interiorBarCenters.count, 3)
        XCTAssertEqual(labelCenters.count, interiorBarCenters.count)
        for (barCenter, labelCenter) in zip(interiorBarCenters, labelCenters) {
            XCTAssertEqual(labelCenter, barCenter, accuracy: 2)
        }
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

    func testNearestDailySummarySelectsEnergyForHoveredDate() {
        let first = Date(timeIntervalSince1970: 1_000)
        let summaries = [
            summary(at: first, dayKey: "2026-08-28", energy: 0.136),
            summary(at: first.addingTimeInterval(86_400), dayKey: "2026-08-29", energy: 0.174),
            summary(at: first.addingTimeInterval(172_800), dayKey: "2026-08-30", energy: 0.238)
        ]

        let nearest = PowerChartInteraction.nearestDailySummary(
            to: first.addingTimeInterval(86_400 + 1_800),
            from: summaries
        )

        XCTAssertEqual(nearest?.dayKey, "2026-08-29")
        XCTAssertEqual(nearest?.energyKWh, 0.174)
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

    private func blueBarCenters(in bitmap: NSBitmapImageRep) -> [Int] {
        groupedColumns(
            (0..<bitmap.pixelsWide).filter { x in
                let rows = blueRows(at: x, in: bitmap)
                guard let first = rows.first, let last = rows.last else { return false }
                return rows.count >= 24 && last - first >= 30
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

    private func axisLabelCenters(in bitmap: NSBitmapImageRep, after barBottom: Int) -> [Int] {
        let scanRange = (barBottom + 5)..<min(bitmap.pixelsHigh, barBottom + 42)
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
            if let last = runs.indices.last, row - runs[last].last! <= 1 {
                runs[last].append(row)
            } else {
                runs.append([row])
            }
        }
        return runs
    }

    private func groupedColumns(_ columns: [Int]) -> [Int] {
        var groups: [[Int]] = []
        for column in columns {
            if let last = groups.indices.last, column - groups[last].last! <= 6 {
                groups[last].append(column)
            } else {
                groups.append([column])
            }
        }
        return groups.map { ($0.first! + $0.last!) / 2 }
    }

    private func groupedColumns(
        in bitmap: NSBitmapImageRep,
        rows: Range<Int> = 0..<Int.max,
        where matches: (NSColor) -> Bool,
        minimumPixels: Int
    ) -> [Int] {
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
            if let last = groups.indices.last, column - groups[last].last! <= 6 {
                groups[last].append(column)
            } else {
                groups.append([column])
            }
        }
        return groups.map { ($0.first! + $0.last!) / 2 }
    }
}
