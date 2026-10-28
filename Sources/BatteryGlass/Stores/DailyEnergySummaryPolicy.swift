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
            // 这一天已用全精度样本重算，旧口径的「来源未知」不再成立；
            // 否则加载时种下的橙色提示会永久跟随该日，与「结论可随样本补齐消除」相悖。
            if updated.energyQuality?.hasUnknownHistoricalCoverage == true {
                updated.energyQuality?.hasUnknownHistoricalCoverage = false
            }
            return updated
        }
    }

    /// A summary built from one retained boundary sample is not a complete day's result.
    /// Clear it so the UI can show that the day is incomplete instead of displaying 0.000 kWh.
    static func markSparseLegacySummariesIncomplete(
        _ summaries: [DailySummary],
        todayKey: String,
        dayKeysWithSleepEnergy: Set<String> = []
    ) -> [DailySummary] {
        summaries.map { summary in
            // Sleep energy is independently measured and remains valid even when a day has
            // only one (or no) ordinary sample. Do not erase it as a sparse legacy sample day.
            guard summary.dayKey != todayKey,
                  summary.sampleCount <= 1,
                  !dayKeysWithSleepEnergy.contains(summary.dayKey) else {
                return summary
            }

            var updated = summary
            updated.energyKWh = nil
            return updated
        }
    }
}
