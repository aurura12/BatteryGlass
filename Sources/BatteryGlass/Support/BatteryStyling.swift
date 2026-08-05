import SwiftUI

enum BatteryStyling {
    static func tint(for snapshot: BatterySnapshot) -> Color {
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
}
