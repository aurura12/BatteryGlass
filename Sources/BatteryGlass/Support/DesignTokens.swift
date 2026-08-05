import SwiftUI

/// 基于 ui-ux-pro-max 设计系统（Executive Dashboard）的语义化设计令牌。
enum DesignTokens {
    // 间距：严格 8pt 栅格
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24

    // 圆角与描边
    static let cornerRadiusSmall: CGFloat = 10
    static let cornerRadiusCard: CGFloat = 14
    static let cornerRadiusPanel: CGFloat = 24

    // 交通灯状态色（Executive Dashboard 语义：绿=正常/充电，黄=注意，红=告警）
    static let statusGreen = Color(red: 0.13, green: 0.77, blue: 0.36) // #22C55E
    static let statusAmber = Color(red: 0.96, green: 0.62, blue: 0.04) // #F59E0B
    static let statusRed = Color(red: 0.94, green: 0.27, blue: 0.27)   // #EF4444

    // 数据色（仅用于数据可视化与中性强调）
    static let dataBlue = Color(red: 0.07, green: 0.48, blue: 0.96)     // #127AF5
    static let dischargeBlue = Color(red: 0.20, green: 0.53, blue: 0.95)
    static let mint = Color(red: 0.15, green: 0.73, blue: 0.60)

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.62)
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }
}
