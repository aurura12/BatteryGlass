import Foundation

/// 充电速率滚动追踪器：在充电态 percent 爬升时记录离散点，用「首尾斜率」给出
/// 最近一段时间的实测充速（%/s），供估算器在系统估计缺失时外推「充满还需」。
///
/// 为什么不用最小二乘：percent 采样是离散阶跃（0.5s tick 下通常每次 +1%，
/// 间隔几十秒到几分钟），有效点数少，LSQ 对离群点/窗口滑入老点更敏感；
/// 首尾法对「最近实测平均充速」的语义最直接。
///
/// 防护设计：
/// - 只在充电态记录，状态一离开即清空；
/// - 相等百分比重复 tick 忽略，明显回退（>= 0.5）视为充电被打断而重置；
/// - 首尾跨距 < 90s 视为 1% 单步噪声，拒绝；
/// - 斜率 > 0.05%/s 视为唤醒补跳等假快充，拒绝；
/// - 停滞超过滑窗（10 分钟）后老点过期，斜率自然失效。
struct ChargeRateTracker {
    struct Sample: Equatable {
        let date: Date
        let percent: Double
    }

    private(set) var samples: [Sample] = []

    /// 滑窗长度（秒）：只保留最近 10 分钟的爬升点。
    static let maximumWindow: TimeInterval = 600
    /// 首尾最小时间跨距（秒）：过滤 0.5s 噪声与 1% 步进产生的瞬时假斜率。
    static let minimumSpan: TimeInterval = 90
    /// 斜率上限（%/s）：更高视为单步噪声/唤醒补跳。
    static let maximumSlopePercentPerSecond: Double = 0.05
    /// percent 明显回退阈值：>= 0.5 判定充电被打断 → 重置。
    static let dropThresholdPercent: Double = 0.5
    /// 记录点上界：接近满充后无外推意义。
    static let topPercent: Double = 99.5
    private static let equalTolerance = 0.001

    /// 记录一拍充电进度。仅 `isCharging == true` 且 percent 严格爬升时记录；
    /// 未充电 / 顶部涓流 / 明显回退都会清空窗口重新积累。
    mutating func record(percent: Double, at date: Date, isCharging: Bool) {
        guard isCharging, percent < Self.topPercent else {
            reset()
            return
        }
        guard let last = samples.last else {
            samples = [Sample(date: date, percent: percent)]
            return
        }

        let delta = percent - last.percent
        if abs(delta) < Self.equalTolerance { return }        // 同 % 重复 tick
        if delta <= -Self.dropThresholdPercent { reset(); return } // 回退打断
        guard delta > 0 else { return }                        // 微小回落视为噪声

        prune(upTo: date)
        samples.append(Sample(date: date, percent: percent))
    }

    /// 当前可用实测充速（%/s）。窗口内不足两个爬升点、首尾跨距不足、停滞过期、
    /// 或斜率越界（<= 0 或 > 上限）时返回 nil。
    func slopePercentPerSecond(now: Date) -> Double? {
        var copy = self
        copy.prune(upTo: now)
        guard copy.samples.count >= 2,
              let first = copy.samples.first,
              let last = copy.samples.last else { return nil }

        let span = last.date.timeIntervalSince(first.date)
        guard span >= Self.minimumSpan else { return nil }

        let rate = (last.percent - first.percent) / span
        guard rate > 0, rate <= Self.maximumSlopePercentPerSecond else { return nil }
        return rate
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: false)
    }

    /// 丢弃早于 `now - 滑窗` 的爬升点。
    private mutating func prune(upTo now: Date) {
        let cutoff = now.timeIntervalSinceReferenceDate - Self.maximumWindow
        samples.removeAll { $0.date.timeIntervalSinceReferenceDate < cutoff }
    }
}
