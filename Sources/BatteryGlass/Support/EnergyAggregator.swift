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
    /// 该周期内「没有可用值」或「存在会让数值偏低/有偏差的记录」的天数。
    var incompleteDayCount: Int = 0

    var id: Date { periodStart }
}

/// 把每日能耗汇总按日/周/月聚合（纯函数，便于单元测试）。
enum EnergyAggregator {
    private struct PeriodValue {
        var energyKWh = 0.0
        var hasEnergy = false
        var incompleteDayCount = 0
    }

    static func aggregate(
        summaries: [DailySummary],
        grouping: EnergyGrouping,
        calendar: Calendar = .current
    ) -> [EnergyAggregate] {
        var merged: [Date: PeriodValue] = [:]
        for summary in summaries {
            let localDate = date(forDayKey: summary.dayKey, calendar: calendar) ?? summary.date
            let start = periodStart(for: localDate, grouping: grouping, calendar: calendar)
            var value = merged[start, default: PeriodValue()]
            if summary.hasValidEnergy, let energy = summary.energyKWh {
                value.energyKWh += energy
                value.hasEnergy = true
            }
            if summary.needsEnergyAttention {
                value.incompleteDayCount += 1
            }
            merged[start] = value
        }
        return merged.keys.sorted().compactMap { start in
            guard let value = merged[start], value.hasEnergy else { return nil }
            return EnergyAggregate(
                periodStart: start,
                title: title(for: start, grouping: grouping, calendar: calendar),
                energyKWh: value.energyKWh,
                incompleteDayCount: value.incompleteDayCount
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
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            return String(
                format: "%04d-%02d-%02d",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
        case .week:
            let components = calendar.dateComponents([.month, .day], from: date)
            return String(format: "%02d-%02d 周", components.month ?? 0, components.day ?? 0)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
        }
    }

    /// DailySummary.date is an absolute instant saved under the timezone active at the time.
    /// Rebuild the calendar date from the stable local day key under the current grouping calendar.
    private static func date(forDayKey key: String, calendar: Calendar) -> Date? {
        let values = key.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = values[0]
        components.month = values[1]
        components.day = values[2]
        components.hour = 12
        return calendar.date(from: components)
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

}
