import Foundation

/// 按天查看历史曲线时的日期状态：可选日期集合 + 当前选中日 + 前后一天导航。
///
/// 纯值类型，便于单元测试。`days` 始终包含今天（即使今天还没有样本，
/// 也要能选中今天并看到空态），升序且各为当天 00:00。
struct HistoryDaySelection: Equatable {
    /// 有样本的日期（升序，当天 00:00），已并入今天。
    let days: [Date]
    /// 当前选中日（当天 00:00）。
    let selected: Date

    private let now: Date
    private let calendar: Calendar

    init(
        days: [Date],
        selected: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let today = calendar.startOfDay(for: now)
        var unique = Set(days.map { calendar.startOfDay(for: $0) })
        unique.insert(today)
        let ordered = unique.sorted()

        let requested = selected.map { calendar.startOfDay(for: $0) } ?? today
        self.days = ordered
        self.now = now
        self.calendar = calendar
        // 选中日若已被清理（超出保留窗口），退回不晚于它的最近一天；都没有则退回最新一天。
        self.selected = ordered.contains(requested)
            ? requested
            : (ordered.last(where: { $0 <= requested }) ?? ordered[ordered.count - 1])
    }

    /// 当前日期的标签：今日 / 昨天 / M/d。
    var label: String {
        label(for: selected)
    }

    var isToday: Bool {
        calendar.isDate(selected, inSameDayAs: now)
    }

    private var index: Int {
        days.firstIndex(of: selected) ?? 0
    }

    var canGoOlder: Bool { index > 0 }

    var canGoNewer: Bool { index < days.count - 1 }

    /// 前一天（无更早数据时为 nil）。
    var olderDay: Date? {
        canGoOlder ? days[index - 1] : nil
    }

    /// 后一天（已是最新时为 nil）。
    var newerDay: Date? {
        canGoNewer ? days[index + 1] : nil
    }

    func label(for day: Date) -> String {
        BatteryFormatters.historyDayLabel(day, now: now, calendar: calendar)
    }
}
