import Foundation

/// X 轴刻度单位：缩放后可见跨度变窄，固定 6 小时步长会让刻度消失。
enum ChartTickUnit: Equatable {
    case minute(step: Int)
    case hour(step: Int)

    var component: Calendar.Component {
        switch self {
        case .minute: .minute
        case .hour: .hour
        }
    }

    var step: Int {
        switch self {
        case .minute(let step), .hour(let step): step
        }
    }

    /// 标签是否需要显示分钟（窄窗口下只显示整点会全是同一个数字）。
    var includesMinutes: Bool {
        if case .minute = self { return true }
        return false
    }
}

/// 曲线 X 轴的动态时间刻度：按可见跨度挑选步长并生成刻度时刻。
/// 纯函数，便于单元测试。
enum ChartTimeAxis {
    /// 可见跨度（秒）→ 刻度单位。整日保持既有的 6 小时步长。
    static func unit(forSpan seconds: TimeInterval) -> ChartTickUnit {
        guard seconds.isFinite, seconds > 0 else { return .hour(step: 6) }
        switch seconds {
        case ..<3_600: return .minute(step: 10)
        case ..<7_200: return .minute(step: 30)
        case ..<21_600: return .hour(step: 1)
        case ..<43_200: return .hour(step: 3)
        default: return .hour(step: 6)
        }
    }

    /// 生成落在 `domain` 内的刻度时刻，升序且对齐到当天 00:00 的整步长网格。
    static func marks(
        in domain: ClosedRange<Date>,
        unit: ChartTickUnit,
        calendar: Calendar = .current
    ) -> [Date] {
        let lower = domain.lowerBound
        let upper = domain.upperBound
        guard unit.step > 0 else { return [] }

        guard let dayStart = calendar.dateInterval(of: .day, for: lower)?.start,
              var cursor = alignedStart(from: dayStart, to: lower, unit: unit) else {
            return []
        }

        var marks: [Date] = []
        // 上限防御：极端参数下避免死循环。
        while cursor <= upper, marks.count < 128 {
            if cursor >= lower {
                marks.append(cursor)
            }
            guard let next = calendar.date(byAdding: unit.component, value: unit.step, to: cursor) else {
                break
            }
            cursor = next
        }
        return marks
    }

    /// 把 `date` 向下取整到当天 `step × component` 网格上。
    private static func alignedStart(
        from dayStart: Date,
        to date: Date,
        unit: ChartTickUnit
    ) -> Date? {
        let unitSeconds: Double
        switch unit {
        case .minute: unitSeconds = 60
        case .hour: unitSeconds = 3_600
        }
        let grid = unitSeconds * Double(unit.step)
        guard grid > 0 else { return nil }
        let offset = date.timeIntervalSince(dayStart)
        guard offset.isFinite, offset >= 0 else { return dayStart }
        return dayStart.addingTimeInterval((offset / grid).rounded(.down) * grid)
    }
}
