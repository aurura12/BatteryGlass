import Foundation

/// 待机（系统睡眠）场景分类。
enum SleepSegmentMode: String, Codable, Sendable {
    /// 不插电，电池放电
    case discharging
    /// 插电且正在充电
    case charging
    /// 插电，未充电（充满停充/浮充）
    case pluggedIdle
}

/// 一次待机区间的能量统计。
///
/// `energyKWh` 为电脑从电源（插座或电池）消耗的总能量，恒为正：
/// - 不插电待机：电池放电能量（电量差 × 电压）；
/// - 插电待机：充入电池能量（电量差 × 电压）+ 系统维持功耗（唤醒后采样估算）。
struct SleepSegment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var start: Date
    var end: Date
    /// 从电源消耗的能量（kWh），恒正
    var energyKWh: Double
    /// 待机期间平均功率（W）= energyKWh 换算后 / 时长
    var averagePowerW: Double?
    var mode: SleepSegmentMode
}
