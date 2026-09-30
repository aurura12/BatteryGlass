import Foundation

/// 图表视口取样：缩放后只渲染可见域内的样本，避免把整日抽样集硬套到窄窗口上。
enum ChartViewport {
    /// 取落在 `domain` 内的样本；超过 `maximum` 时等距抽样并保留首尾样本。
    static func visibleSamples(
        _ samples: [HistorySample],
        in domain: ClosedRange<Date>,
        maximum: Int = .max
    ) -> [HistorySample] {
        let visible = samples.filter { domain.contains($0.timestamp) }
        guard maximum > 1, visible.count > maximum else { return visible }

        let step = Double(visible.count - 1) / Double(maximum - 1)
        return (0..<maximum).map { index in
            visible[Int((Double(index) * step).rounded())]
        }
    }
}
