import Foundation

/// 历史曲线的显示范围。天数同时用于取样本与计算 X 轴域。
enum HistoryRange: Int, CaseIterable, Identifiable, Sendable {
    case today = 1
    case threeDays = 3
    case sevenDays = 7

    var id: Int { rawValue }

    /// 覆盖的天数（含今天）。
    var days: Int { rawValue }

    var title: String {
        switch self {
        case .today: "今日"
        case .threeDays: "近 3 天"
        case .sevenDays: "近 7 天"
        }
    }
}
