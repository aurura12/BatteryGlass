import Foundation
import XCTest
@testable import BatteryGlass

final class PowerChartAxisTests: XCTestCase {
    func testDayLabelsProduceOneMarkPerDayWithLabel() {
        let fixture = makeFixture()

        let marks = PowerChartAxis.marks(
            timeline: fixture.timeline,
            samples: fixture.samples,
            dateDomain: fixture.dateDomain,
            chartDomain: fixture.chartDomain,
            unit: .day(step: 1),
            showsDayLabels: true,
            calendar: fixture.calendar
        )

        let labeled = marks.filter { $0.label != nil }
        XCTAssertEqual(labeled.count, 3)
        XCTAssertTrue(labeled.allSatisfy { $0.date != nil })
        XCTAssertTrue(labeled.allSatisfy { !($0.label ?? "").isEmpty })
    }

    func testMidDayBreakKeepsSeparatorMark() {
        let fixture = makeFixture()

        let marks = PowerChartAxis.marks(
            timeline: fixture.timeline,
            samples: fixture.samples,
            dateDomain: fixture.dateDomain,
            chartDomain: fixture.chartDomain,
            unit: .day(step: 1),
            showsDayLabels: true,
            calendar: fixture.calendar
        )

        // 断点标记：date 与 label 都是 nil。夹具里 3 个断点中只有午间那个不与日期标签重合。
        let breakMarks = marks.filter { $0.date == nil && $0.label == nil }
        XCTAssertEqual(fixture.timeline.breaks.count, 3)
        XCTAssertEqual(breakMarks.count, 1)
    }

    func testOvernightBreaksAreCoveredByDayLabels() {
        let fixture = makeFixture()

        let marks = PowerChartAxis.marks(
            timeline: fixture.timeline,
            samples: fixture.samples,
            dateDomain: fixture.dateDomain,
            chartDomain: fixture.chartDomain,
            unit: .day(step: 1),
            showsDayLabels: true,
            calendar: fixture.calendar
        )

        // 跨夜断点塌缩后与次日首条样本落在同一位置，日期标签信息更多，
        // 去重时保留日期标签、丢弃重复的 `//`。
        let labelPositions = Set(
            marks.filter { $0.label != nil }.map { ($0.position * 1_000).rounded() }
        )
        let breakMarks = marks.filter { $0.date == nil && $0.label == nil }
        XCTAssertTrue(breakMarks.allSatisfy {
            !labelPositions.contains(($0.position * 1_000).rounded())
        })
    }

    func testDayLabelSitsOnFirstSampleOfThatDay() {
        let fixture = makeFixture()

        let marks = PowerChartAxis.marks(
            timeline: fixture.timeline,
            samples: fixture.samples,
            dateDomain: fixture.dateDomain,
            chartDomain: fixture.chartDomain,
            unit: .day(step: 1),
            showsDayLabels: true,
            calendar: fixture.calendar
        )

        let firstDayMark = marks.first { $0.label != nil }
        let expected = fixture.timeline.position(for: fixture.samples[0].timestamp)
        XCTAssertEqual(firstDayMark?.position ?? .nan, expected, accuracy: 0.001)
    }

    func testClockModeFallsBackToTimeTicksAndBreaks() {
        let fixture = makeFixture()

        let marks = PowerChartAxis.marks(
            timeline: fixture.timeline,
            samples: fixture.samples,
            dateDomain: fixture.dateDomain,
            chartDomain: fixture.chartDomain,
            unit: .hour(step: 6),
            showsDayLabels: false,
            calendar: fixture.calendar
        )

        XCTAssertTrue(marks.contains { $0.date != nil })            // 时间刻度
        XCTAssertTrue(marks.contains { $0.date == nil })            // 断点标记
        XCTAssertTrue(marks.allSatisfy { $0.label == nil })         // 不出现日期标签
    }

    func testMarksAreSortedAndUniqueByPosition() {
        for showsDayLabels in [true, false] {
            let fixture = makeFixture()
            let marks = PowerChartAxis.marks(
                timeline: fixture.timeline,
                samples: fixture.samples,
                dateDomain: fixture.dateDomain,
                chartDomain: fixture.chartDomain,
                unit: showsDayLabels ? .day(step: 1) : .hour(step: 6),
                showsDayLabels: showsDayLabels,
                calendar: fixture.calendar
            )

            XCTAssertEqual(marks.map(\.position), marks.map(\.position).sorted())
            XCTAssertEqual(Set(marks.map(\.id)).count, marks.count)
        }
    }

    func testMarksAreClampedToChartDomain() {
        let fixture = makeFixture()
        // 只暴露中段：所有标记必须被钳进可见域。
        let width = fixture.chartDomain.upperBound - fixture.chartDomain.lowerBound
        let clippedLower = fixture.chartDomain.lowerBound + width * 0.3
        let clippedUpper = fixture.chartDomain.lowerBound + width * 0.6
        let clipped = clippedLower...clippedUpper

        let marks = PowerChartAxis.marks(
            timeline: fixture.timeline,
            samples: fixture.samples,
            dateDomain: fixture.dateDomain,
            chartDomain: clipped,
            unit: .day(step: 1),
            showsDayLabels: true,
            calendar: fixture.calendar
        )

        XCTAssertTrue(marks.allSatisfy { clipped.contains($0.position) })
    }

    func testEmptySamplesProduceOnlyBreakMarks() {
        let calendar = utcCalendar()
        let timeline = PowerChartTimeline(segments: [])

        let marks = PowerChartAxis.marks(
            timeline: timeline,
            samples: [],
            dateDomain: date("2026-08-25 00:00:00")...date("2026-08-27 00:00:00"),
            chartDomain: 0...1,
            unit: .day(step: 1),
            showsDayLabels: true,
            calendar: calendar
        )

        XCTAssertTrue(marks.allSatisfy { $0.label == nil })
    }

    // MARK: - Fixture

    private struct Fixture {
        let samples: [HistorySample]
        let timeline: PowerChartTimeline
        let dateDomain: ClosedRange<Date>
        let chartDomain: ClosedRange<Double>
        let calendar: Calendar
    }

    /// 三天各一段，另有同一日内的午间断点，共 3 个断点（2 个跨夜 + 1 个午间）。
    private func makeFixture() -> Fixture {
        let calendar = utcCalendar()
        let segments: [[HistorySample]] = [
            [
                historySample(at: date("2026-08-25 10:00:00")),
                historySample(at: date("2026-08-25 10:05:00"))
            ],
            [
                historySample(at: date("2026-08-25 14:00:00")),
                historySample(at: date("2026-08-25 14:05:00"))
            ],
            [
                historySample(at: date("2026-08-26 09:00:00")),
                historySample(at: date("2026-08-26 09:05:00"))
            ],
            [
                historySample(at: date("2026-08-27 08:00:00")),
                historySample(at: date("2026-08-27 08:05:00"))
            ]
        ]
        let samples = segments.flatMap { $0 }
        let timeline = PowerChartTimeline(segments: segments)
        let lower = timeline.position(for: samples[0].timestamp)
        let upper = timeline.position(for: samples[samples.count - 1].timestamp)
        return Fixture(
            samples: samples,
            timeline: timeline,
            dateDomain: date("2026-08-25 00:00:00")...date("2026-08-27 23:59:59"),
            chartDomain: lower...upper,
            calendar: calendar
        )
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

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
