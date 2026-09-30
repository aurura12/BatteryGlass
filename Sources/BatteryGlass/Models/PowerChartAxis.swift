import Foundation

/// 功率曲线 X 轴上的一个标记：时间刻度、日期标签，或断点（渲染为 `//`）。
struct PowerChartAxisMark: Identifiable {
    var position: Double
    var date: Date?
    /// 直接显示的文本（跨天视图的 `M/d` 日期标签）；优先于 `date`。
    var label: String?

    var id: Double { position }
}

/// 功率曲线 X 轴标记生成。纯函数，便于单元测试。
///
/// 两种模式：
/// - `showsDayLabels == false`（可见跨度在一日内）：按 `unit` 生成时间刻度，剔除塌缩进断点
///   的那些（它们会与断点标记重叠），再补上断点标记 `//`。
/// - `showsDayLabels == true`（跨天视图）：紧凑轴下整点刻度大多落在待机断点里会被剔掉，
///   改用「每天数据起点」的日期标签（`M/d`），让多天视图仍能分辨日期。
enum PowerChartAxis {
    /// 断点标记最多显示的数量（原实现的取值，保持不变）。
    private static let maximumBreakMarkers = 8
    /// 位置比较容差。
    private static let positionTolerance: Double = 0.001

    static func marks(
        timeline: PowerChartTimeline,
        samples: [HistorySample],
        dateDomain: ClosedRange<Date>,
        chartDomain: ClosedRange<Double>,
        unit: ChartTickUnit,
        showsDayLabels: Bool,
        calendar: Calendar = .current
    ) -> [PowerChartAxisMark] {
        var marks = showsDayLabels
            ? dayStartMarks(
                timeline: timeline,
                samples: samples,
                dateDomain: dateDomain,
                chartDomain: chartDomain,
                calendar: calendar
            )
            : timeMarks(timeline: timeline, dateDomain: dateDomain, unit: unit)
        marks.append(contentsOf: breakMarks(
            timeline: timeline,
            dateDomain: dateDomain,
            chartDomain: chartDomain
        ))
        return deduplicated(marks)
    }

    /// 时间刻度：映射到曲线坐标，并剔除落在断点内（会塌缩到跳变点、与断点标记重叠）的刻度。
    private static func timeMarks(
        timeline: PowerChartTimeline,
        dateDomain: ClosedRange<Date>,
        unit: ChartTickUnit
    ) -> [PowerChartAxisMark] {
        ChartTimeAxis.marks(in: dateDomain, unit: unit)
            .filter { !timeline.isInsideBreak($0) }
            .map { PowerChartAxisMark(position: timeline.position(for: $0), date: $0) }
    }

    /// 日期标签：可见区间内每个「有样本的本地日」一个标签，落在该天第一条样本的位置。
    private static func dayStartMarks(
        timeline: PowerChartTimeline,
        samples: [HistorySample],
        dateDomain: ClosedRange<Date>,
        chartDomain: ClosedRange<Double>,
        calendar: Calendar
    ) -> [PowerChartAxisMark] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return [] }

        var marks: [PowerChartAxisMark] = []
        var dayStart = calendar.startOfDay(for: dateDomain.lowerBound)

        while dayStart < dateDomain.upperBound, marks.count < 64 {
            guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                break
            }
            // 该天内第一条样本；整天没有样本就不出标签（紧凑轴下它会与相邻天挤在同一点）。
            if let first = sorted.first(where: { $0.timestamp >= dayStart && $0.timestamp < nextDayStart }) {
                let position = min(
                    max(timeline.position(for: first.timestamp), chartDomain.lowerBound),
                    chartDomain.upperBound
                )
                marks.append(
                    PowerChartAxisMark(
                        position: position,
                        date: dayStart,
                        label: BatteryFormatters.xAxisDayLabel(dayStart)
                    )
                )
            }
            dayStart = nextDayStart
        }
        return marks
    }

    /// 断点标记：断点不占宽度，直接画在跳变点上；起点在窗口左侧时钳到可见域左边缘。
    private static func breakMarks(
        timeline: PowerChartTimeline,
        dateDomain: ClosedRange<Date>,
        chartDomain: ClosedRange<Double>
    ) -> [PowerChartAxisMark] {
        let visibleBreaks = timeline.breaks.filter {
            $0.duration > 5
                && $0.end > dateDomain.lowerBound
                && $0.start < dateDomain.upperBound
        }
        let markerStride = max(1, Int(ceil(Double(visibleBreaks.count) / Double(maximumBreakMarkers))))
        return visibleBreaks.enumerated().compactMap { index, interval in
            guard index.isMultiple(of: markerStride) else { return nil }
            let position = min(
                max(timeline.position(for: interval.start), chartDomain.lowerBound),
                chartDomain.upperBound
            )
            return PowerChartAxisMark(position: position, date: nil)
        }
    }

    /// 同一位置只保留信息最多的一个（日期标签 > 时间刻度 > 断点标记），避免 id 冲突。
    private static func deduplicated(_ marks: [PowerChartAxisMark]) -> [PowerChartAxisMark] {
        var result: [PowerChartAxisMark] = []
        for mark in marks.sorted(by: { $0.position < $1.position }) {
            if let last = result.last, abs(last.position - mark.position) < positionTolerance {
                if rank(mark) > rank(last) {
                    result[result.count - 1] = mark
                }
                continue
            }
            result.append(mark)
        }
        return result
    }

    private static func rank(_ mark: PowerChartAxisMark) -> Int {
        if mark.label != nil { return 2 }
        if mark.date != nil { return 1 }
        return 0
    }
}
