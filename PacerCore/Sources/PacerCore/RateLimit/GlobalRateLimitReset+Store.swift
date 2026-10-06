import Foundation
import SwiftData

extension GlobalRateLimitReset {

    /// Reads one window's recent OAuth readings for `account` and runs
    /// `detect` over them.
    ///
    /// The newest reading is read on its own first, because `detect` can only
    /// fire when that reading is low, and on almost every poll it isn't. The
    /// whole lookback is read only when it can matter. For the 7-day window
    /// that lookback is a week of polls, ~16,000 rows on a busy account. The
    /// app used to read all of them on every poll of the active account, on
    /// the main thread, which made up about a third of a ~230 ms freeze
    /// every 30 s while the dashboard was open.
    ///
    /// Reads only, so it is safe on a context of the caller's own off the
    /// main actor.
    public static func detectRecent(
        in context: ModelContext,
        account: String?,
        window: String,
        lookback: TimeInterval,
        highWatermark: Double,
        minAnchorLead: TimeInterval,
        now: Date = Date()
    ) -> Detection? {
        let oauthSource = RateLimitSource.oauth
        let cutoff = now.addingTimeInterval(-lookback)
        // Scoped to one login: an unscoped series would interleave two
        // accounts' utilisation, and the collapse detector would read the gap
        // between them as a reset.
        let predicate = account == nil
            ? #Predicate<RateLimitSample> {
                $0.source == oauthSource && $0.window == window && $0.sampledAt >= cutoff
            }
            : #Predicate<RateLimitSample> {
                $0.source == oauthSource && $0.window == window
                    && $0.sampledAt >= cutoff && $0.accountId == account
            }

        var newest = FetchDescriptor<RateLimitSample>(
            predicate: predicate, sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        newest.fetchLimit = 1
        guard let latest = try? context.fetch(newest).first,
              latest.usedPercentage <= lowWatermark else { return nil }

        let descriptor = FetchDescriptor<RateLimitSample>(
            predicate: predicate, sortBy: [SortDescriptor(\.sampledAt, order: .forward)])
        guard let rows = try? context.fetch(descriptor) else { return nil }
        let observations = rows.map {
            Observation(sampledAt: $0.sampledAt, usedPercentage: $0.usedPercentage,
                        resetsAt: $0.resetsAt)
        }
        return detect(observations, highWatermark: highWatermark, minAnchorLead: minAnchorLead)
    }
}
