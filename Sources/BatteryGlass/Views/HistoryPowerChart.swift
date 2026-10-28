import Charts
import SwiftUI

struct TodayPowerChart: View {
    let chartData: PowerChartData
    let sleepIntervals: [SleepInterval]
    @Environment(\.themeAccent) private var themeAccent
    /// 该图展示的日期（当天 00:00）；面板固定为今天，放大窗口可按天切换。
    let day: Date
    /// 没有可绘制样本时的提示；记录关闭/暂停时由调用方改成对应原因。
    let emptyMessage: String
    /// 绘图区高度；nil 表示撑满剩余空间（放大窗口内使用）。
    let plotHeight: CGFloat?
    /// 非 nil 时在标题栏提供「放大查看」入口。
    let onExpand: (() -> Void)?

    /// 用户设定的缩放窗口；nil 表示跟随默认（贴最新一屏）。
    @State private var window: ChartZoomWindow?
    @State private var hoveredSample: HistorySample?
    @State private var hoverLocation: CGPoint?
    /// 可见段与降采样结果：窗口/样本不变时直接复用，悬停只注入高亮点。
    @State private var segmentCache = PowerChartSegmentCache()
    /// 悬停位置与吸附样本超过该间隔视为"无数据"（待机缺口内不显示 tooltip）。
    private let hoverMaximumGap: TimeInterval = 180
    /// 放大下限：1 分钟（5 秒一条时约 12 个点）。
    private static let minimumVisibleDuration: TimeInterval = 60

    private var energySamples: [HistorySample] { chartData.plotSamples }

    init(
        chartData: PowerChartData,
        sleepIntervals: [SleepInterval],
        day: Date = Date(),
        emptyMessage: String = "暂无有效功率曲线",
        plotHeight: CGFloat? = 138,
        onExpand: (() -> Void)? = nil
    ) {
        self.chartData = chartData
        self.sleepIntervals = sleepIntervals
        self.day = day
        self.emptyMessage = emptyMessage
        self.plotHeight = plotHeight
        self.onExpand = onExpand
    }

    /// 当前日期是否是今天（今日默认贴最新一屏，往日默认展示整天）。
    private var isToday: Bool {
        Calendar.current.isDate(day, inSameDayAs: Date())
    }

    /// 日期标签：今日 / 昨天 / M/d。
    private var dayLabel: String {
        BatteryFormatters.historyDayLabel(day)
    }

    var body: some View {
        // 帧内只算一次：这些计算属性含 O(样本数) 的筛选与 O(断点数) 的坐标换算，
        // 若直接写进逐样本的 ForEach，会被放大到 O(n²)（卡顿主因）。
        let activeWindow = effectiveWindow(for: window)
        let chartDomain = activeWindow.domain
        let dateDomain = visibleDateDomain(for: chartDomain)
        let tickUnit = ChartTimeAxis.unit(
            forSpan: dateDomain.upperBound.timeIntervalSince(dateDomain.lowerBound)
        )
        let tickFormat: Date.FormatStyle = tickUnit.includesMinutes
            ? Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)
            : Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted))
        let marks = axisMarks(in: dateDomain, unit: tickUnit, chartDomain: chartDomain)
        let marksByPosition = Dictionary(
            marks.map { ($0.position, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let segments = displaySegments(isZoomed: activeWindow.isZoomed, in: dateDomain)
        let connections = chartData.timeline.connections.filter { chartDomain.contains($0.position) }
        let sliderRange = panRange(for: activeWindow)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(dayLabel)功率曲线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if activeWindow.isZoomed {
                    Text("已放大")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if activeWindow.canPan {
                    Text("横向滚动查看")
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

            if chartData.plotSegments.isEmpty {
                ChartEmptyPlaceholder(emptyMessage)
                    .frame(height: 120)
            } else {
                VStack(spacing: 4) {
                    Chart {
                        ForEach(Array(segments.enumerated()), id: \.offset) { segmentIndex, segment in
                            let segmentID = segment.first?.id.uuidString ?? "segment-\(segmentIndex)"
                            ForEach(segment) { sample in
                                AreaMark(
                                    x: .value("时间", chartData.timeline.position(for: sample.timestamp)),
                                    y: .value("功率", sample.consumptionPowerW ?? 0),
                                    series: .value("曲线段", segmentID)
                                )
                                .interpolationMethod(.linear)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [themeAccent.opacity(0.22), themeAccent.opacity(0.02)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("时间", chartData.timeline.position(for: sample.timestamp)),
                                    y: .value("功率", sample.consumptionPowerW ?? 0),
                                    series: .value("曲线段", segmentID)
                                )
                                .interpolationMethod(.linear)
                                .foregroundStyle(themeAccent)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            }
                        }

                        ForEach(connections) { connection in
                            RuleMark(
                                x: .value("时间", connection.position),
                                yStart: .value("功率", connection.startPowerW),
                                yEnd: .value("功率", connection.endPowerW)
                            )
                            .foregroundStyle(themeAccent)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        }

                        if let hoveredSample,
                           let power = hoveredSample.consumptionPowerW {
                            RuleMark(
                                x: .value(
                                    "悬停时间",
                                    chartData.timeline.position(for: hoveredSample.timestamp)
                                )
                            )
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundStyle(themeAccent.opacity(0.7))

                            PointMark(
                                x: .value(
                                    "时间",
                                    chartData.timeline.position(for: hoveredSample.timestamp)
                                ),
                                y: .value("功率", power)
                            )
                            .foregroundStyle(themeAccent)
                            .symbolSize(36)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .chartXAxis {
                        AxisMarks(values: marks.map(\.position)) { value in
                            // 优先按位置精确命中（刻度值就是我们传入的 position），
                            // 只有浮点不一致时才回退到线性最近匹配。
                            if let position = value.as(Double.self),
                               let mark = marksByPosition[position] ?? marks.min(by: {
                                   abs($0.position - position) < abs($1.position - position)
                               }) {
                                AxisGridLine().foregroundStyle(.clear)
                                AxisTick()
                                AxisValueLabel {
                                    if let date = mark.date {
                                        Text(date, format: tickFormat)
                                    } else {
                                        Text("//")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                    }
                                }
                            }
                        }
                    }
                    .chartXScale(domain: chartDomain)
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
                    .accessibilityLabel("\(dayLabel)功率曲线")
                    .accessibilityValue(powerAccessibilitySummary)

                    if activeWindow.canPan {
                        Slider(
                            value: Binding(
                                get: { activeWindow.start },
                                set: { window = activeWindow.moved(toStart: $0) }
                            ),
                            in: sliderRange
                        )
                        .controlSize(.small)
                        .tint(themeAccent)
                        .accessibilityLabel("功率曲线时间范围")
                        .accessibilityHint("拖动查看更早或更新的功率数据")
                    }
                }
            }
        }
        .padding(DesignTokens.spacingM)
        .glassSurface(cornerRadius: DesignTokens.cornerRadiusCard)
        .onChange(of: day) { _, _ in
            window = nil
            // 换日后旧的吸附样本已不在时间轴上，必须先清掉，否则 tooltip 会显示上一天的数据。
            clearHover()
        }
        .onChange(of: bounds.upperBound) { _, _ in
            guard let current = window else { return }
            let rebased = current.rebased(to: bounds)
            if rebased != current {
                window = rebased
            }
        }
    }

    /// 曲线坐标下的可缩放总范围（今日全部有效样本）。
    private var bounds: ClosedRange<Double> {
        let first = chartData.plotSamples.first.map { chartData.timeline.position(for: $0.timestamp) }
        let last = chartData.plotSamples.last.map { chartData.timeline.position(for: $0.timestamp) }
        guard let first, let last, last > first else {
            let end = last ?? first ?? 0
            return end...(end + 1)
        }
        return first...last
    }

    /// 当前生效的窗口：今日贴最新的默认窗口（宽度 2 小时），往日默认展示整天。
    /// `stored` 为用户设定的窗口，nil 表示跟随默认。
    private func effectiveWindow(for stored: ChartZoomWindow?) -> ChartZoomWindow {
        let base: ChartZoomWindow = isToday
            ? ChartZoomWindow.latest(
                bounds: bounds,
                defaultSpan: PowerChartWindow.defaultVisibleDuration,
                minimumSpan: Self.minimumVisibleDuration
            )
            : ChartZoomWindow.fullRange(bounds: bounds, minimumSpan: Self.minimumVisibleDuration)
        return (stored ?? base).rebased(to: bounds)
    }

    /// 时间滑块的可用范围（可见窗口起点）。
    private func panRange(for window: ChartZoomWindow) -> ClosedRange<Double> {
        let lower = bounds.lowerBound
        return lower...max(lower, bounds.upperBound - window.span)
    }

    /// 可见窗口对应的真实时间范围，用于筛选要绘制的样本。
    private func visibleDateDomain(for chartDomain: ClosedRange<Double>) -> ClosedRange<Date> {
        let lower = chartData.timeline.date(for: chartDomain.lowerBound)
        return lower...max(lower, chartData.timeline.date(for: chartDomain.upperBound))
    }

    private func axisMarks(
        in dateDomain: ClosedRange<Date>,
        unit: ChartTickUnit,
        chartDomain: ClosedRange<Double>
    ) -> [PowerChartAxisMark] {
        var marks = ChartTimeAxis.marks(in: dateDomain, unit: unit).map { tick in
            PowerChartAxisMark(position: chartData.timeline.position(for: tick), date: tick)
        }
        // 断点内的整点刻度会塌缩到跳变点、与断点标记重叠，直接剔除。
        marks.removeAll { mark in
            guard let date = mark.date else { return false }
            return chartData.timeline.isInsideBreak(date)
        }

        let visibleBreaks = chartData.timeline.breaks.filter {
            $0.duration > 5
                && $0.end > dateDomain.lowerBound
                && $0.start < dateDomain.upperBound
        }
        let markerStride = max(1, Int(ceil(Double(visibleBreaks.count) / 8)))
        for (index, interval) in visibleBreaks.enumerated() where index.isMultiple(of: markerStride) {
            // 断点不占宽度，标记直接画在跳变点上；断点起点在窗口左侧时钳到可见域左边缘。
            let position = min(
                max(chartData.timeline.position(for: interval.start), chartDomain.lowerBound),
                chartDomain.upperBound
            )
            marks.append(PowerChartAxisMark(position: position, date: nil))
        }

        return marks.sorted { $0.position < $1.position }
    }

    /// 只画正功率样本；无读数点、长缺口和系统睡眠都会切成独立曲线段。
    /// 放大后改用未抽样的完整段，避免整日降采样影响局部细节。
    private func displaySegments(
        isZoomed: Bool,
        in dateDomain: ClosedRange<Date>
    ) -> [[HistorySample]] {
        let cached = segmentCache.segments(
            chartData: chartData,
            sleepIntervals: sleepIntervals,
            isZoomed: isZoomed,
            dateDomain: dateDomain
        )
        let visibleSegments = cached.visible
        // Select overview points from the visible window itself. Downsampling the whole
        // day first can leave only a handful of points in the latest two-hour viewport.
        var renderedSegments = cached.rendered

        // The tooltip and PointMark use the original sample. Keep that exact sample in
        // the rendered line too, so a hovered point cannot float away from the curve
        // just because overview downsampling omitted it.
        guard let hoveredSample,
              let sourceSegment = visibleSegments.first(where: { segment in
                  segment.contains { $0.id == hoveredSample.id }
              }) else {
            return renderedSegments
        }

        let renderedIndex: Int? = renderedSegments.firstIndex { segment in
            let sameStart = segment.first?.id == sourceSegment.first?.id
            let sameEnd = segment.last?.id == sourceSegment.last?.id
            return sameStart && sameEnd
        }
        if let renderedIndex {
            let alreadyContains = renderedSegments[renderedIndex].contains { $0.id == hoveredSample.id }
            guard !alreadyContains else { return renderedSegments }
            let insertionIndex: Int = renderedSegments[renderedIndex].firstIndex {
                $0.timestamp > hoveredSample.timestamp
            } ?? renderedSegments[renderedIndex].endIndex
            renderedSegments[renderedIndex].insert(hoveredSample, at: insertionIndex)
        } else if let sampleIndex = sourceSegment.firstIndex(where: { $0.id == hoveredSample.id }) {
            // If the run itself fell outside the segment budget, draw its immediate
            // neighbors as a short independent line so the hovered sample is still traced.
            let lowerIndex = max(0, sampleIndex - 1)
            let upperIndex = min(sourceSegment.count - 1, sampleIndex + 1)
            renderedSegments.append(Array(sourceSegment[lowerIndex...upperIndex]))
        }

        return renderedSegments
    }

    /// VoiceOver 概要：最新一条可见功率样本。
    private var powerAccessibilitySummary: String {
        guard let latest = energySamples.last,
              let power = latest.consumptionPowerW else { return "暂无数据" }
        return String(format: "最新 %.1f 瓦", power)
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
        guard let coordinate: Double = proxy.value(atX: xPosition) else {
            clearHover()
            return
        }
        let timestamp = chartData.timeline.date(for: coordinate)

        guard let nearest = PowerChartInteraction.nearestSample(
            to: timestamp,
            from: energySamples
        ) else {
            hoveredSample = nil
            hoverLocation = nil
            return
        }
        // 待机缺口内悬停会吸附到缺口两端样本，与实际位置相差过大时不显示，
        // 避免把待机前的功率误当成待机期间的测量值。
        guard abs(nearest.timestamp.timeIntervalSince(timestamp)) <= hoverMaximumGap else {
            hoveredSample = nil
            hoverLocation = nil
            return
        }
        // 指针在同一个吸附点内移动时，标记与 tooltip 内容都不变；写入 @State 只会让
        // 整张图（含逐样本 mark）重算，因此只在吸附样本切换时更新。
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

            Text(String(format: "%.1f W", sample.consumptionPowerW ?? 0))
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
