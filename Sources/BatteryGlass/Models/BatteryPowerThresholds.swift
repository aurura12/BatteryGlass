import Foundation

/// 电池功率判定的共享阈值。
///
/// 「读取放电功率」和「确认插电同时放电」是两件事：前者只要求读数明显为负，
/// 后者要求读数足够负且持续够久。两处各自维护常数会让阈值悄悄漂移
/// （例如确认用 0.1 W、读取用 0.01 W，确认成功后读数回到 0.05 W 就会被误判成非放电），
/// 因此统一放在这里。
enum BatteryPowerThresholds {
    /// 噪声下限：功率低于 `-minimumDischargeW` 才算真实放电。
    static let minimumDischargeW = 0.01

    /// 进入「插电同时放电」判定所需的最小放电功率，比噪声下限更严，
    /// 用来滤掉电量计零点漂移。
    static let confirmedDischargeW = 0.1
}
