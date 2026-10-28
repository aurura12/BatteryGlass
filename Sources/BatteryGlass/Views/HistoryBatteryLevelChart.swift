import Charts
import SwiftUI

/// 电量曲线：支持缩放 / 拖动平移与悬停查看时间与电量。
struct TodayBatteryLevelChart: View {
    let chartData: BatteryLevelChartData
    @Environment(\.themeAccent) private var themeAccent
    /// 该图展示的日期（当天 00:00）；面板固定为今天，放大窗口可按天切换。
    let day: Date
    /// 绘图区高度；nil 表示撑满剩余空间（放大窗口内使用）。
    let plotHeight: CGFloat?
    /// 非 nil 时在标题栏提供「放大查看」入口。
    let onExpand: (() -> Void)?

    /// 用户设定的缩放窗口；nil 表示整段范围。
    @State private var window: ChartZoomWindow?
    @State private var hoveredSample: HistorySample?
    @State private var hoverLocation: CGPoint?
    /// 分段、填充、缺口连线与 Y 域的联合缓存：悬停不触发重算。
    @State private var segmentCache = BatteryLevelSegmentCache()
    /// 悬停位置与吸附样本超过该间隔视为"无数据"（待机缺口内不显示 tooltip）。
    private let hoverMaximumGap: TimeInterval = 180
    /// 放大下限：5 分钟。
    private static let minimumVisibleDuration: TimeInterval = 300

    private var samples: [HistorySample] { chartData.samples }

    init(
        chartData: BatteryLevelChartData,
        day: Date = Date(),
        plotHeight: CGFloat? = 138,
        onExpand: (() -> Void)? = nil
    ) {
        self.chartData = chartData
        self.day = day
        self.plotHeight = plotHeight
        self.onExpand = onExpand
    }

    /// 日期标签：今日 / 昨天 / M/d。
    private var dayLabel: String {
        BatteryFormatters.historyDayLabel(day)
    }

    /// 以最后一条样本时间收尾，避免父视图重绘时按 `Date()` 改变缩放范围。
    /// 往日展示整天并收在当天最后一条样本处。
    private var fullDomain: ClosedRange<Date> {
        BatteryLevelAxis.xDomain(
            day: day,
            now: samples.last?.timestamp ?? Date(),
            lastSample: samples.last?.timestamp
        )
    }

    /// 可缩放总范围，换算成参考纪元秒（与 ChartZoomWindow 的坐标单位一致）。
    private var bounds: ClosedRange<Double> {
        let lower = fullDomain.lowerBound.timeIntervalSinceReferenceDate
        let upper = fullDomain.upperBound.timeIntervalSinceReferenceDate
        return lower...upper
    }

    /// 当前生效窗口：未交互时是整日，交互后为用户的窗口。
    private func effectiveWindow(for stored: ChartZoomWindow?) -> ChartZoomWindow {
        let base = ChartZoomWindow.fullRange(
            bounds: bounds,
            minimumSpan: Self.minimumVisibleDuration
        )
        return (stored ?? base).rebased(to: bounds)
    }

    /// 可见的真实时间域。
    private func visibleDomain(for window: ChartZoomWindow) -> ClosedRange<Date> {
        let lower = Date(timeIntervalSinceReferenceDate: window.start)
        let upper = Date(timeIntervalSinceReferenceDate: max(window.start + 1, window.upper))
        return lower...max(lower, upper)
    }

    var body: some View {
        // 帧内只算一次：若把 `yDomain` 这类计算属性直接写进逐样本的 ForEach，
        // 每个样本都会重跑一遍 O(样本数) 的筛选，整体退化成 O(n²)（卡顿主因）。
        let activeWindow = effectiveWindow(for: window)
        let plotDomain = visibleDomain(for: activeWindow)
        // 分段 / 填充 / 缺口连线 / Y 域一起缓存：窗口与样本不变时直接复用。
        let cached = segmentCache.data(
            chartData: chartData,
            window: activeWindow,
            domain: plotDomain
        )
        let plotYDomain = cached.yDomain
        let segments = cached.segments
        // 填充区域用一整条连续序列，缺口两侧共用同一渐变，避免稀疏段（每次唤醒只有
        // 一两条样本）因区域窄到看不见而出现「有的有底色、有的没有」。
        let fillSamples = cached.fillSamples
        let bridges = cached.bridges
        let tickUnit = ChartTimeAxis.unit(
            forSpan: plotDomain.upperBound.timeIntervalSince(plotDomain.lowerBound)
        )
        let tickFormat: Date.FormatStyle = tickUnit.includesMinutes
            ? Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)
            : Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted))

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(dayLabel)电量曲线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if activeWindow.isZoomed {
                    Text("已放大")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                ChartZoomButton(kind: .zoomOut) {
                    $window.zoom(by: 1 / ChartZoomButton.step, effective: activeWindow)
                }
                ChartZoomButton(kind: .zoomIn) {
                    $window.zoom(by: ChartZoomButton.step, effective: activeWindow)
                }
                if window != nil {
                    ChartZoomResetButton { window = nil }
                }
                if let onExpand {
                    ChartExpandButton(action: onExpand)
                }
            }

            if samples.isEmpty {
                ChartEmptyPlaceholder("暂无\(dayLabel)数据，应用运行后每 5 秒记录一次")
                    .frame(height: 120)
            } else {
                Chart {
                    ForEach(fillSamples) { sample in
                        // 用 2 参 `AreaMark(x:y:)` 而不是 `x:yStart:yEnd:`：Swift Charts
                        // 对每个 mark 都给常量 yStart 的 3 参形式在密集样本下会按
                        // 独立竖条渲染，相邻竖条不被插值合并，导致画面呈"梳齿"。
                        // 不传 `series` 让整日样本连成一条填充区域（缺口也一起填上）。
                        // AreaMark 默认填充到 0%，由下方 chartPlotStyle 将其裁在绘图区内，
                        // 避免动态 Y 轴下界高于 0% 时填充溢出到横轴标签区。
                        AreaMark(
                            x: .value("时间", sample.timestamp),
                            y: .value("电量", sample.percent)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [themeAccent.opacity(0.22), themeAccent.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }

                    ForEach(Array(segments.enumerated()), id: \.offset) { segmentIndex, segment in
                        let segmentID = segment.first?.id.uuidString ?? "segment-\(segmentIndex)"
                        ForEach(segment) { sample in
                            LineMark(
                                x: .value("时间", sample.timestamp),
                                y: .value("电量", sample.percent),
                                series: .value("曲线段", segmentID)
                            )
                            .interpolationMethod(.linear)
                            .foregroundStyle(themeAccent)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        }
                    }

                    // 缺口（待机期间只有零星唤醒样本）用更细、更淡的实测连线跨过，
                    // 既不再画出断口，也不把推测值画成正式测量。
                    ForEach(Array(bridges.enumerated()), id: \.offset) { index, bridge in
                        let bridgeID = "bridge-\(index)"
                        ForEach([bridge.start, bridge.end]) { sample in
                            LineMark(
                                x: .value("时间", sample.timestamp),
                                y: .value("电量", sample.percent),
                                series: .value("曲线段", bridgeID)
                            )
                            .interpolationMethod(.linear)
                            .foregroundStyle(themeAccent.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round))
                        }
                    }

                    if let hoveredSample {
                        RuleMark(x: .value("悬停时间", hoveredSample.timestamp))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(themeAccent.opacity(0.7))

                        PointMark(
                            x: .value("时间", hoveredSample.timestamp),
                            y: .value("电量", hoveredSample.percent)
                        )
                        .foregroundStyle(themeAccent)
                        .symbolSize(36)
                    }
                }
                .chartXScale(domain: plotDomain)
                .chartYScale(domain: plotYDomain)
                .chartPlotStyle { plot in
                    plot.clipped()
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let percent = value.as(Double.self) {
                                Text("\(Int(percent.rounded()))%")
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: ChartTimeAxis.marks(in: plotDomain, unit: tickUnit)) { _ in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick()
                        AxisValueLabel(format: tickFormat)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        let plot = proxy.overlayPlotRect(in: geometry)
                        ZStack(alignment: .topTrailing) {
                            ChartPlotEventCatcher(
                                onZoom: { factor, location in
                                    window = activeWindow.zoomed(
                                        by: Double(factor),
                                        anchorFraction: ChartZoomGestureMath.anchorFraction(
                                            for: location,
                                            in: plot
                                        )
                                    )
                                    clearHover()
                                },
                                onPan: { deltaX, _ in
                                    window = activeWindow.panned(
                                        by: ChartZoomGestureMath.panDelta(
                                            points: deltaX,
                                            plotWidth: plot.width,
                                            span: activeWindow.span
                                        )
                                    )
                                    clearHover()
                                },
                                onHover: { location in
                                    updateHover(at: location, proxy: proxy, geometry: geometry)
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if let hoveredSample, let hoverLocation {
                                hoverTooltip(for: hoveredSample)
                                    .position(
                                        x: min(max(hoverLocation.x, 60), geometry.size.width - 60),
                                        y: min(max(hoverLocation.y - 26, 18), geometry.size.height - 18)
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .chartPlotHeight(plotHeight)
                // Y 轴顶端刻度（如 100%）以刻度线为中心绘制，贴着绘图区上沿会被 .clipped()
                // 裁掉上半个字并压到标题上；在图表外包一层顶部内边距给标签留出空间。
                .padding(.top, 14)
                .clipped()
                .accessibilityLabel("\(dayLabel)电量曲线")
                .accessibilityValue(levelAccessibilitySummary)
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
        .onChange(of: day) { _, _ in
            window = nil
            // 换日后旧样本不在时间轴上，残留的悬停标记会指向错误日期。
            clearHover()
        }
    }

    /// VoiceOver 概要：最新一条电量样本。
    private var levelAccessibilitySummary: String {
        guard let latest = samples.last else { return "暂无数据" }
        return "最新电量 \(BatteryFormatters.percent(latest.percent))"
    }

    /// 手势进行中清掉 tooltip，避免标记跟着手指停留。
    private func clearHover() {
        hoveredSample = nil
        hoverLocation = nil
    }

    private func updateHover(
        at location: CGPoint?,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let location, let plotFrame = proxy.plotFrame else {
            clearHover()
            return
        }

        let frame = geometry[plotFrame]
        guard frame.contains(location) else {
            clearHover()
            return
        }

        let xPosition = location.x - frame.minX
        guard let timestamp: Date = proxy.value(atX: xPosition) else {
            clearHover()
            return
        }

        guard let nearest = PowerChartInteraction.nearestSample(
            to: timestamp,
            from: samples
        ) else {
            hoveredSample = nil
            hoverLocation = nil
            return
        }
        // 缺口内悬停会吸附到缺口两端样本，与实际位置相差过大时不显示，
        // 避免把待机前的电量误当成待机期间的读数。
        guard abs(nearest.timestamp.timeIntervalSince(timestamp)) <= hoverMaximumGap else {
            hoveredSample = nil
            hoverLocation = nil
            return
        }
        // 同一吸附点内移动不刷新视图：标记与 tooltip 内容都不变。
        guard hoveredSample?.id != nearest.id else { return }
        hoveredSample = nearest
        hoverLocation = location
    }

    private func hoverTooltip(for sample: HistorySample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sample.timestamp, format: .dateTime
                .hour(.defaultDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(BatteryFormatters.percent(sample.percent))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(themeAccent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}
