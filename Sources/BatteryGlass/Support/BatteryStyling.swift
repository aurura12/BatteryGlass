import SwiftUI

enum BatteryStyling {
    static func tint(for snapshot: BatterySnapshot) -> Color {
        // 未检测到电池时保持中性灰，避免 0% 触发低电量红色。
        if snapshot.state == .unknown { return .secondary }
        if snapshot.state == .charging { return DesignTokens.statusGreen }
        if snapshot.percent <= 15 { return DesignTokens.statusRed }
        if snapshot.percent <= 25 { return DesignTokens.statusAmber }
        if snapshot.state == .discharging { return DesignTokens.dischargeBlue }
        return .secondary
    }

    static func gradient(for snapshot: BatterySnapshot) -> [Color] {
        let tint = tint(for: snapshot)
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
