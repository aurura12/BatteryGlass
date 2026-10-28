import Foundation

/// 历史页「记录不可用」的提示模型：持久化故障优先于用户主动关闭。
/// 纯值类型 + 纯函数，文案与空态原因集中在一处，避免面板与放大窗口各写一套。
enum HistoryRecordingNotice: Equatable {
    case paused(issue: String)
    case disabled

    static func resolve(
        recordingEnabled: Bool,
        persistenceIssue: String?
    ) -> HistoryRecordingNotice? {
        if let persistenceIssue {
            return .paused(issue: persistenceIssue)
        }
        return recordingEnabled ? nil : .disabled
    }

    var icon: String {
        switch self {
        case .paused: return "exclamationmark.triangle.fill"
        case .disabled: return "pause.circle"
        }
    }

    /// 历史页顶部的提示文案。
    var title: String {
        switch self {
        case .paused(let issue):
            return "历史记录已暂停：\(issue)。可清除历史后重新开始记录。"
        case .disabled:
            return "历史记录已关闭，本次运行不会新增数据。可在设置中重新开启。"
        }
    }

    /// 曲线图空态文案；nil 表示使用图表自身默认文案。
    var emptyCurveMessage: String? {
        switch self {
        case .paused: return "历史记录已暂停，暂无曲线数据"
        case .disabled: return "历史记录已关闭，暂无曲线数据"
        }
    }

    /// 能耗图空态文案。
    var emptyEnergyMessage: String {
        switch self {
        case .paused: return "历史记录已暂停，暂无能耗数据"
        case .disabled: return "历史记录已关闭，暂无能耗数据"
        }
    }
}
