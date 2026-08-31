import Foundation

/// 能耗汇总的分组粒度。
enum EnergyGrouping: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "按日"
        case .week: return "按周"
        case .month: return "按月"
        }
    }

    var chartTitle: String {
        switch self {
        case .day: return "每日耗电量"
        case .week: return "每周耗电量"
        case .month: return "每月耗电量"
        }
    }

    /// 横轴刻度步长。
    var xStride: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }
}

/// 一个能耗聚合周期（日/周/月）的合计。
struct EnergyAggregate: Identifiable, Equatable {
    var periodStart: Date
    var title: String
    var energyKWh: Double

    var id: Date { periodStart }
}

/// 把每日能耗汇总按日/周/月聚合（纯函数，便于单元测试）。
enum EnergyAggregator {
    static func aggregate(
        summaries: [DailySummary],
        grouping: EnergyGrouping,
        calendar: Calendar = .current
    ) -> [EnergyAggregate] {
        var merged: [Date: Double] = [:]
        for summary in summaries {
            guard let energy = summary.energyKWh else { continue }
            let start = periodStart(for: summary.date, grouping: grouping, calendar: calendar)
            merged[start, default: 0] += energy
        }
        return merged.keys.sorted().map { start in
            EnergyAggregate(
                periodStart: start,
                title: title(for: start, grouping: grouping, calendar: calendar),
                energyKWh: merged[start] ?? 0
            )
        }
    }

    static func periodStart(
        for date: Date,
        grouping: EnergyGrouping,
        calendar: Calendar = .current
    ) -> Date {
        switch grouping {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    static func title(
        for date: Date,
        grouping: EnergyGrouping,
        calendar: Calendar = .current
    ) -> String {
        switch grouping {
        case .day:
            return BatteryFormatters.dayKey(for: date)
        case .week:
            return "\(weekFormatter.string(from: date)) 周"
        case .month:
            return monthFormatter.string(from: date)
        }
    }

    /// 找到与给定日期最接近的聚合周期（用于 hover 命中）。
    static func nearestAggregate(
        to date: Date,
        from aggregates: [EnergyAggregate]
    ) -> EnergyAggregate? {
        aggregates.min {
            abs($0.periodStart.timeIntervalSince(date)) < abs($1.periodStart.timeIntervalSince(date))
        }
    }

    private static let weekFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}
