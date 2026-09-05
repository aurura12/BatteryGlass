import Foundation

/// 「充满还需 / 剩余时间」显示值平滑器：对估算秒值做 EMA，抑制 0.5s 刷新
/// 引起的跳变，同时避免显示滞后可感知。
///
/// 规则：
/// - 首值直通，避免刚插电/开机后长时间空白；
/// - 状态（充电 ↔ 放电 ↔ 已接通 ↔ 未知）切换即复位，绝不把充电时间与放电
///   时间两种含义的估算做平滑渐变；
/// - raw 为 nil 立即清空，不挂上一状态的陈旧值；
/// - 输出钳制在 [60s, 48h]，与 TimeRemainingEstimator 的结果域一致（第二道防线）。
struct TimeRemainingSmoother {
    /// 每 0.5s tick 的 EMA 系数：τ ≈ 3s，约 20s 收敛，不拖慢显示。
    static let alphaPerTick = 0.15
    static let minimumSeconds: TimeInterval = 60
    static let maximumSeconds: TimeInterval = 172_800

    private(set) var value: TimeInterval?
    private var hasValue = false
    private var lastState: PowerState?

    mutating func update(raw: TimeInterval?, state: PowerState) -> TimeInterval? {
        if state != lastState {
            reset()
            lastState = state
        }
        guard let raw, raw.isFinite, raw > 0 else {
            value = nil
            hasValue = false
            return nil
        }

        let clamped = min(max(raw, Self.minimumSeconds), Self.maximumSeconds)
        if !hasValue {
            value = clamped
            hasValue = true
        } else {
            let current = value ?? clamped
            value = current + Self.alphaPerTick * (clamped - current)
        }
        return value
    }

    mutating func reset() {
        value = nil
        hasValue = false
    }
}
