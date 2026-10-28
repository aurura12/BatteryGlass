import SwiftUI

enum BatteryStyling {
    /// 电池状态色：充电、低电量这类语义色固定不变，其余（供电中 / 插拔过渡）
    /// 使用用户自定义的主题色 `accent`，让面板整体色调跟随设置。
    static func tint(for snapshot: BatterySnapshot, accent: Color = DesignTokens.dataBlue) -> Color {
        // 未检测到电池时保持中性灰，避免 0% 触发低电量红色。
        if snapshot.displayState == .unknown { return .secondary }
        if snapshot.powerDisplayStatus != .ready, snapshot.adapterConnected { return accent }
        if snapshot.displayState == .charging { return DesignTokens.statusGreen }
        if snapshot.percent <= 15 { return DesignTokens.statusRed }
        if snapshot.percent <= 25 { return DesignTokens.statusAmber }
        if snapshot.displayState == .discharging { return accent }
        return .secondary
    }

    static func gradient(for snapshot: BatterySnapshot, accent: Color = DesignTokens.dataBlue) -> [Color] {
        let tint = tint(for: snapshot, accent: accent)
        return [tint, tint.opacity(0.45)]
    }

    /// 健康度语义色：低健康度告警，而非恒为绿色。
    static func healthTint(for health: Double?) -> Color {
        guard let health else { return DesignTokens.mint }
        if health < 60 { return DesignTokens.statusRed }
        if health < 80 { return DesignTokens.statusAmber }
        return DesignTokens.mint
    }
}
