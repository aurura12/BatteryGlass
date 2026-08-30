import Foundation

enum BatteryFormatters {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func power(_ value: Double) -> String {
        String(format: "%+.1f W", value)
    }

    static func energyKWh(_ value: Double) -> String {
        String(format: "%.3f kWh", value)
    }

    static func temperature(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f °C", value)
    }

    static func voltage(_ value: Double) -> String {
        value > 0 ? String(format: "%.2f V", value) : "--"
    }

    static func timeRemaining(_ interval: TimeInterval?) -> String {
        guard let interval, interval.isFinite, interval > 0 else { return "--" }
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "\(total) 秒"
    }

    /// 菜单栏紧凑时间格式：满小时显示 "2h15m"，不足一小时显示 "45m"。
    static func menuBarTimeRemaining(_ interval: TimeInterval?) -> String {
        guard let interval, interval.isFinite, interval > 0 else { return "--" }
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }

    static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func dayKeyDate(_ key: String) -> Date? {
        dayFormatter.date(from: key)
    }

    /// 柱状图横轴日期标签："8/30"。
    static func xAxisDayLabel(_ date: Date) -> String {
        xAxisDayFormatter.string(from: date)
    }

    /// 柱状图横轴月份标签："2026-08"。
    static func xAxisMonthLabel(_ date: Date) -> String {
        xAxisMonthFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let xAxisDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let xAxisMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}
