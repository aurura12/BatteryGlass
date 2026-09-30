import Foundation

/// 图表横向视口：坐标无关的纯值类型，同时服务三张今日曲线。
///
/// 三张图的 X 轴单位不同——功率曲线用「曲线秒」（`PowerChartTimeline` 把待机断点
/// 塌缩为 0 宽度后的坐标），电量 / 温压曲线用 `Date`。把 `Date` 经
/// `timeIntervalSinceReferenceDate` 转成秒即可复用同一套缩放数学，断点塌缩语义
/// 也因此不会被破坏（缩放始终发生在图表自身坐标系内）。
///
/// 所有操作都做钳制，非法输入一律 no-op，绝不产生 NaN、负跨度或反向区间。
struct ChartZoomWindow: Equatable {
    /// 可见域下界（图表坐标单位）。
    var start: Double
    /// 可见域宽度。
    var span: Double
    /// 可缩放的总范围（随 `now` 推进而增长）。
    var bounds: ClosedRange<Double>
    /// 重置宽度：`.infinity` 表示「整段」（日图），功率图为固定 2 小时。
    var defaultSpan: Double
    /// 最小可见宽度（功率图 60s，日图 300s）。
    var minimumSpan: Double

    /// 判定「未缩放」的容差。取值远小于任何一次真实缩放增量，
    /// 保证 `reset()` 后 `isZoomed == false`，从而走预计算的整日 Y 域。
    static let epsilon: Double = 1
    /// 贴边容差，与 `PowerChartWindow.shouldFollowLatest` 的默认容差一致。
    static let edgeTolerance: Double = 10

    // MARK: - 工厂

    /// 默认展示整段（日图：00:00 → now）。
    static func fullRange(bounds: ClosedRange<Double>, minimumSpan: Double) -> Self {
        Self(start: 0, span: 0, bounds: bounds, defaultSpan: .infinity, minimumSpan: minimumSpan)
            .reset()
    }

    /// 默认展示最新一段（功率图：贴最新一屏）。
    static func latest(
        bounds: ClosedRange<Double>,
        defaultSpan: Double,
        minimumSpan: Double
    ) -> Self {
        Self(start: 0, span: 0, bounds: bounds, defaultSpan: defaultSpan, minimumSpan: minimumSpan)
            .reset()
    }

    // MARK: - 派生属性

    /// 总范围宽度（下限 0，`bounds` 退化时为 0）。
    var fullWidth: Double { max(0, bounds.upperBound - bounds.lowerBound) }

    /// 可见域上界。
    var upper: Double { start + span }

    /// 生效的默认宽度：`defaultSpan` 非有限则取整段，且不超过总范围。
    var effectiveDefaultSpan: Double {
        defaultSpan.isFinite ? min(max(defaultSpan, 0), fullWidth) : fullWidth
    }

    /// 生效的最小宽度：总范围不足一屏时退化为整段，此时不可缩放。
    var effectiveMinimumSpan: Double { min(max(minimumSpan, 0), fullWidth) }

    /// 可见域（图表坐标）。宽度至少 1，避免退化区间让 Swift Charts 抖动。
    var domain: ClosedRange<Double> { start...max(start + 1, upper) }

    /// 是否处于放大状态（相对默认宽度更窄）。
    var isZoomed: Bool { span < effectiveDefaultSpan - Self.epsilon }

    /// 可见域右端是否贴着最新数据（用于判断是否跟随 `now` 推进）。
    var isAtLatestEdge: Bool { upper >= bounds.upperBound - Self.edgeTolerance }

    /// 是否可横向平移（总范围比可见域宽）。
    var canPan: Bool { span < fullWidth - Self.epsilon }

    // MARK: - 操作

    /// 捏合缩放。`magnification` 是相对手势起点的累计倍数（>1 放大、<1 缩小），
    /// 因此调用方必须把 `self` 取成手势起始时的窗口副本。
    /// `anchorFraction` 是锚点在该窗口内的相对位置（0 = 左端，1 = 右端）。
    func zoomed(by magnification: Double, anchorFraction: Double) -> Self {
        guard magnification.isFinite, magnification > 0, fullWidth > 0 else { return self }

        let anchor = anchorFraction.isFinite ? min(max(anchorFraction, 0), 1) : 0.5
        let anchorValue = start + anchor * span
        let newSpan = clampedSpan(span / magnification)

        var copy = self
        copy.span = newSpan
        copy.start = anchorValue - anchor * newSpan
        return copy.clamped()
    }

    /// 横向平移。`delta` 为正表示窗口右移（显示更晚的数据）。
    func panned(by delta: Double) -> Self {
        guard delta.isFinite, canPan else { return self }
        var copy = self
        copy.start += delta
        return copy.clamped()
    }

    /// 直接移动到指定起点（供时间滑块使用）。
    func moved(toStart newStart: Double) -> Self {
        guard newStart.isFinite else { return self }
        var copy = self
        copy.start = newStart
        return copy.clamped()
    }

    /// 回到默认宽度：日图回到整段，功率图回到贴最新的默认窗口。
    func reset() -> Self {
        var copy = self
        copy.span = clampedSpan(effectiveDefaultSpan)
        copy.start = bounds.upperBound - copy.span
        return copy.clamped()
    }

    /// 总范围增长/变化后重新基准化。
    ///
    /// - 整段模式的曲线（`defaultSpan` 非有限）：未缩放时按新范围重建整段窗口，
    ///   始终从当天 00:00 起并跟随 `now` 推进；
    /// - 固定窗口的曲线（功率图）：可见域贴着最新数据时整体平移跟随，
    ///   已被用户平移到历史区间的窗口留在原处。
    func rebased(to newBounds: ClosedRange<Double>) -> Self {
        let normalized = Self.normalized(newBounds)
        let wasAtLatestEdge = isAtLatestEdge
        let growth = normalized.upperBound - bounds.upperBound

        var copy = self
        copy.bounds = normalized
        if !defaultSpan.isFinite, !isZoomed {
            return copy.reset()
        }
        if wasAtLatestEdge, growth.isFinite, growth != 0 {
            copy.start += growth
        }
        return copy.clamped()
    }

    // MARK: - 内部

    private func clampedSpan(_ target: Double) -> Double {
        guard target.isFinite else { return effectiveMinimumSpan }
        return min(max(target, effectiveMinimumSpan), fullWidth)
    }

    private func clamped() -> Self {
        var copy = self
        copy.bounds = Self.normalized(bounds)
        copy.span = clampedSpan(span)
        let lowest = copy.bounds.lowerBound
        let highest = max(lowest, copy.bounds.upperBound - copy.span)
        copy.start = start.isFinite ? min(max(start, lowest), highest) : lowest
        return copy
    }

    private static func normalized(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        let lower = range.lowerBound
        let upper = range.upperBound
        guard lower.isFinite, upper.isFinite, lower <= upper else {
            return 0...0
        }
        return range
    }
}

/// 把输入事件的像素增量换算成视口变化。纯函数，便于单元测试。
enum ChartZoomGestureMath {
    /// 事件位置 → 可见域内的相对锚点（0 = 左端，1 = 右端）。
    static func anchorFraction(for location: CGPoint, in plotRect: CGRect) -> Double {
        guard plotRect.width > 0, location.x.isFinite else { return 0.5 }
        let fraction = (location.x - plotRect.minX) / plotRect.width
        return Double(min(max(fraction, 0), 1))
    }

    /// 水平位移（点）→ 可见域起点增量（图表坐标单位）。
    /// 向右拖动表示查看更早的数据，因此起点减小。
    static func panDelta(points deltaX: CGFloat, plotWidth: CGFloat, span: Double) -> Double {
        guard plotWidth > 0, deltaX.isFinite, span.isFinite else { return 0 }
        return -Double(deltaX) * (span / Double(plotWidth))
    }
}
