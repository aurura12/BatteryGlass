import Foundation

/// 「充满还需 / 剩余时间」估算器（纯函数，便于单元测试）。
///
/// 输入刻意**不使用** `BatterySnapshot.currentCapacityMAh / maxCapacityMAh`：
/// 在 Apple Silicon 上 IOPS 上报的 Current/Max Capacity 是 0-100 归一化值，
/// 合并进快照容量字段后会污染任何 mAh 语义的计算。这里要求调用方直接传入
/// SmartBattery 侧真 mAh（`RemainingCapacity` / `FccComp2`·`AppleRawMaxCapacity`），
/// 并把系统估计（IOPS timeToFull/timeToEmpty、IOPSGetTimeRemainingEstimate）作为
/// 参数传入——纯函数内不接触 IOKit。
///
/// 分支优先级（满足即收敛）：
/// - 充电：接近满/已满直接无估算 → 系统 timeToFull → 短窗实测充电速率外推
///   `(100-percent)/rate` → 真 mAh 缺口 ÷ 充电电流。
/// - 放电：系统 timeToEmpty → IOPSGetTimeRemainingEstimate → 真 mAh ÷ 放电电流。
enum TimeRemainingEstimator {
    /// 结果允许的合理区间（秒）：越界视为不可信 → nil。
    /// 下界用于拦截归一化污染等荒谬小值；上界避免接近零耗时的长期虚假估计。
    static let minimumSeconds: TimeInterval = 60
    static let maximumSeconds: TimeInterval = 172_800 // 48 小时

    struct Input {
        var state: PowerState = .unknown
        /// 0-100，语义独立可靠（ps.percent 优先），与容量字段解耦。
        var percent = 0.0
        var isCharged = false
        /// 真 mAh（SmartBattery：RemainingCapacity）。
        var currentCapacityMAh = 0.0
        /// 真 mAh（SmartBattery：FccComp2 / AppleRawMaxCapacity 解析结果）。
        var fullChargeCapacityMAh = 0.0
        /// 电流（A，带符号：充电正 / 放电负，已做电量计→遥测→IOPS 回退）。
        var currentA = 0.0
        /// 系统估计（秒），由调用方解析传入。IOPS 字段已做分钟→秒换算。
        var systemTimeToEmpty: TimeInterval? = nil
        var systemTimeToFull: TimeInterval? = nil
        /// IOPSGetTimeRemainingEstimate() 返回值（秒），仅放电语义有意义。
        var systemEstimateSeconds: TimeInterval? = nil
        /// 短窗实测充电速率（%/s）；仅充电且斜率可用时非 nil。
        var chargePercentPerSecond: Double? = nil
    }

    static func estimateSeconds(_ input: Input) -> TimeInterval? {
        switch input.state {
        case .charging:
            // 收尾涓流/已充满没有「充满还需」；即便系统估计在手也不外推。
            guard input.percent < 99.5, !input.isCharged else { return nil }
            if let seconds = validated(input.systemTimeToFull) { return seconds }
            if let rate = input.chargePercentPerSecond, rate.isFinite, rate > 0 {
                return validated((100 - input.percent) / rate)
            }
            if input.currentA > 0.01, input.fullChargeCapacityMAh > 0 {
                let missing = input.fullChargeCapacityMAh - input.currentCapacityMAh
                if missing > 0 {
                    return validated(missing / 1000 / input.currentA * 3600)
                }
            }
            return nil

        case .discharging:
            if let seconds = validated(input.systemTimeToEmpty) { return seconds }
            if let seconds = validated(input.systemEstimateSeconds) { return seconds }
            if input.currentA < -0.01, input.currentCapacityMAh > 0 {
                return validated(input.currentCapacityMAh / 1000 / abs(input.currentA) * 3600)
            }
            return nil

        case .pluggedIn, .unknown:
            return nil
        }
    }

    /// 有效性校验：非有限、非正值、越出合理区间一律视为不可信返回 nil。
    private static func validated(_ seconds: TimeInterval?) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        guard seconds >= minimumSeconds, seconds <= maximumSeconds else { return nil }
        return seconds
    }
}
