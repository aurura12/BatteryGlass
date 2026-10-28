import Foundation
import SwiftUI

/// Keep full-resolution history for statistics and hover lookup while bounding Chart marks.
enum HistoryChartRendering {
    static let maximumDisplayedSamples = 800

    /// Select local minima and maxima so narrow peaks survive chart-only downsampling.
    static func downsamplePreservingExtrema(
        _ samples: [HistorySample],
        limit: Int,
        value: (HistorySample) -> Double?
    ) -> [HistorySample] {
        guard limit > 0 else { return [] }
        guard samples.count > limit else { return samples }
        guard limit > 1 else { return [samples[samples.count / 2]] }
        guard limit > 2 else { return [samples[0], samples[samples.count - 1]] }

        let interiorCount = samples.count - 2
        let interiorBudget = limit - 2
        let pairedBucketCount = interiorBudget / 2
        var selectedIndices: Set<Int> = [0, samples.count - 1]

        for bucket in 0..<pairedBucketCount {
            let lower = 1 + bucket * interiorCount / pairedBucketCount
            let upper = 1 + (bucket + 1) * interiorCount / pairedBucketCount
            guard lower < upper else { continue }

            var minimumIndex: Int?
            var maximumIndex: Int?
            var minimumValue = Double.infinity
            var maximumValue = -Double.infinity
            for index in lower..<upper {
                guard let sampleValue = value(samples[index]), sampleValue.isFinite else { continue }
                if sampleValue < minimumValue {
                    minimumIndex = index
                    minimumValue = sampleValue
                }
                if sampleValue > maximumValue {
                    maximumIndex = index
                    maximumValue = sampleValue
                }
            }
            if let minimumIndex { selectedIndices.insert(minimumIndex) }
            if let maximumIndex { selectedIndices.insert(maximumIndex) }
        }

        // An odd interior budget gets one global peak in addition to the local min/max pairs.
        if !interiorBudget.isMultiple(of: 2), interiorCount > 0 {
            let peakIndex = (1..<(samples.count - 1)).compactMap { index -> (Int, Double)? in
                guard let sampleValue = value(samples[index]), sampleValue.isFinite else { return nil }
                return (index, sampleValue)
            }.max { $0.1 < $1.1 }?.0
            if let peakIndex { selectedIndices.insert(peakIndex) }
        }

        // Fill slots left by constant-value buckets, distributed across the remainder.
        let candidates = (1..<(samples.count - 1)).filter { !selectedIndices.contains($0) }
        let needed = min(limit - selectedIndices.count, candidates.count)
        if needed == 1 {
            selectedIndices.insert(candidates[candidates.count / 2])
        } else if needed > 1 {
            for slot in 0..<needed {
                let offset = Int(
                    (Double(slot) * Double(candidates.count - 1) / Double(needed - 1)).rounded()
                )
                selectedIndices.insert(candidates[offset])
            }
        }

        return selectedIndices.sorted().map { samples[$0] }
    }

    /// Downsample each continuous run independently so the spacing between chosen points
    /// is never mistaken for a real data gap by the chart renderer.
    static func downsampleSegmentsPreservingExtrema(
        _ segments: [[HistorySample]],
        limit: Int,
        value: (HistorySample) -> Double?
    ) -> [[HistorySample]] {
        let nonempty = segments.filter { !$0.isEmpty }
        guard limit > 0 else { return [] }
        let totalCount = nonempty.reduce(0) { $0 + $1.count }
        guard totalCount > limit else { return nonempty }

        // A one-point run cannot form a line. Keep its original sample when the whole
        // input fits, but spend the limited rendering budget on drawable runs otherwise.
        let drawable = nonempty.filter { $0.count > 1 }
        guard limit > 1, !drawable.isEmpty else { return [] }
        if drawable.count * 2 >= limit {
            let runBudget = limit / 2
            guard runBudget > 0 else { return [] }
            return (0..<runBudget).map { index in
                let sourceIndex = runBudget == 1
                    ? 0
                    : Int((Double(index) * Double(drawable.count - 1) / Double(runBudget - 1)).rounded())
                let segment = drawable[sourceIndex]
                return [segment[0], segment[segment.count - 1]]
            }
        }

        let extraBudget = limit - drawable.count * 2
        let totalExtraCapacity = drawable.reduce(0) { $0 + $1.count - 2 }
        guard extraBudget > 0, totalExtraCapacity > 0 else {
            return drawable.map { [$0[0], $0[$0.count - 1]] }
        }

        var targets = Array(repeating: 2, count: drawable.count)
        var remainders: [(index: Int, value: Double)] = []
        for (index, segment) in drawable.enumerated() {
            let capacity = segment.count - 2
            let share = Double(extraBudget) * Double(capacity) / Double(totalExtraCapacity)
            let whole = min(capacity, Int(share.rounded(.down)))
            targets[index] += whole
            remainders.append((index, share - Double(whole)))
        }

        var unallocated = limit - targets.reduce(0, +)
        for remainder in remainders.sorted(by: { $0.value > $1.value }) where unallocated > 0 {
            guard targets[remainder.index] < drawable[remainder.index].count else { continue }
            targets[remainder.index] += 1
            unallocated -= 1
        }

        return drawable.enumerated().map { index, segment in
            downsamplePreservingExtrema(segment, limit: targets[index], value: value)
        }
    }

    /// 一条跨缺口的连接线：首尾是缺口两侧的实测样本，中间不补任何数据点。
    struct GapBridge: Equatable {
        var start: HistorySample
        var end: HistorySample
    }

    /// 相邻连续段之间的连接对，供曲线以细线跨越采样缺口。
    static func gapBridges(_ segments: [[HistorySample]]) -> [GapBridge] {
        var bridges: [GapBridge] = []
        for (previous, next) in zip(segments, segments.dropFirst()) {
            guard let start = previous.last,
                  let end = next.first,
                  end.timestamp > start.timestamp else { continue }
            bridges.append(GapBridge(start: start, end: end))
        }
        return bridges
    }
}


struct ChartEmptyPlaceholder: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
