import Foundation
import SwiftData

/// Records how each forecast model did over newly-*completed* rate-limit
/// cycles, closing the feedback loop: the scoreboard reads these back to bias
/// future model selection toward whatever has actually been winning (and
/// converging early) on this user's data.
///
/// Runs on the scan tick. Idempotent — each (window, cycle, model) is keyed
/// and scored exactly once, so re-running only picks up cycles that finished
/// since last time.
public enum ForecastOutcomeRecorder {

    /// A not-yet-persisted outcome. Pure output of `newOutcomes`, so the
    /// scoring logic tests without SwiftData.
    public struct NewOutcome: Sendable, Equatable {
        public let window: String
        public let modelId: String
        public let resetsAt: Date
        public let trueFinalPct: Double
        public let meanAbsError: Double
        public let convergenceFraction: Double
    }

    /// Pure: from a window's samples, find the *complete* cycles not already
    /// in `existingKeys`, score each model over them, and return the new
    /// outcomes to persist.
    public static func newOutcomes(
        samples: [(at: Date, usedPercentage: Double, resetsAt: Date)],
        window: String,
        duration: TimeInterval,
        now: Date,
        existingKeys: Set<String>,
        models: [any BurnTrajectory.Model] = BurnTrajectory.defaultModels
    ) -> [NewOutcome] {
        // segment() groups by reset; its `history` is every complete cycle.
        let (_, history) = BurnTrajectory.segment(samples: samples, duration: duration, now: now)
        var out: [NewOutcome] = []
        for cycle in history where cycle.resetsAt <= now {
            let trueFinal = cycle.samples.map { $0.usedPercentage }.max() ?? 0
            guard trueFinal > 0 else { continue }
            for score in BurnTrajectory.scoreCompletedCycle(cycle, models: models) {
                let key = ForecastModelOutcome.makeKey(
                    window: window, resetsAt: cycle.resetsAt, modelId: score.modelId)
                guard !existingKeys.contains(key) else { continue }
                out.append(NewOutcome(
                    window: window, modelId: score.modelId, resetsAt: cycle.resetsAt,
                    trueFinalPct: trueFinal, meanAbsError: score.meanAbsError,
                    convergenceFraction: score.convergenceFraction))
            }
        }
        return out
    }

    /// Fetch recent OAuth samples per window, score the cycles that have
    /// completed since last run, and persist the new outcomes.
    public static func record(in context: ModelContext, now: Date = Date(), lookbackDays: Int = 30) {
        let oauth = RateLimitSource.oauth
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        let windows: [(String, TimeInterval)] = [
            (RateLimitWindowName.fiveHour, 5 * 3_600),
            (RateLimitWindowName.sevenDay, 7 * 86_400),
        ]
        for (window, duration) in windows {
            let sampleDescriptor = FetchDescriptor<RateLimitSample>(
                predicate: #Predicate {
                    $0.window == window && $0.source == oauth && $0.sampledAt >= cutoff
                },
                sortBy: [SortDescriptor(\.sampledAt, order: .forward)])
            guard let rows = try? context.fetch(sampleDescriptor), !rows.isEmpty else { continue }
            let samples = rows.compactMap { row -> (at: Date, usedPercentage: Double, resetsAt: Date)? in
                guard let resets = row.resetsAt else { return nil }
                return (row.sampledAt, row.usedPercentage, resets)
            }

            let outcomeDescriptor = FetchDescriptor<ForecastModelOutcome>(
                predicate: #Predicate { $0.window == window })
            let existingKeys = Set((try? context.fetch(outcomeDescriptor))?.map { $0.key } ?? [])

            let news = newOutcomes(samples: samples, window: window, duration: duration,
                                   now: now, existingKeys: existingKeys)
            guard !news.isEmpty else { continue }
            for n in news {
                context.insert(ForecastModelOutcome(
                    window: n.window, modelId: n.modelId, resetsAt: n.resetsAt,
                    trueFinalPct: n.trueFinalPct, meanAbsError: n.meanAbsError,
                    convergenceFraction: n.convergenceFraction, recordedAt: now))
            }
            try? context.save()
        }
    }
}
