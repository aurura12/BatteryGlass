import Foundation

enum DailyEnergySummaryPolicy {
    static func retainedSummaries(_ summaries: [DailySummary]) -> [DailySummary] {
        // Daily summaries are compact aggregates, so keep them for the lifetime of the app.
        summaries
    }

    static func reconcile(
        summaries: [DailySummary],
        recalculatedEnergy: [String: Double],
        allowedDayKeys: Set<String>
    ) -> [DailySummary] {
        summaries.map { summary in
            guard allowedDayKeys.contains(summary.dayKey),
                  let energy = recalculatedEnergy[summary.dayKey],
                  energy.isFinite,
                  energy >= 0 else {
                return summary
            }

            var updated = summary
            updated.energyKWh = energy
            return updated
        }
    }

    /// A summary built from one retained boundary sample is not a complete day's result.
    /// Clear it so the UI can show that the day is incomplete instead of displaying 0.000 kWh.
    static func markSparseLegacySummariesIncomplete(
        _ summaries: [DailySummary],
        todayKey: String
    ) -> [DailySummary] {
        summaries.map { summary in
            guard summary.dayKey != todayKey, summary.sampleCount <= 1 else {
                return summary
            }

            var updated = summary
            updated.energyKWh = nil
            return updated
        }
    }
}
