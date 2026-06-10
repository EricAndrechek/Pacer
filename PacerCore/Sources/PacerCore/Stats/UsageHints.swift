import Foundation

/// Lightweight "what should I notice today?" advisor. Inputs are per-
/// model token + cost totals; outputs are a list of hint enums that
/// the view layer renders. Pure functions, no SwiftData, fully
/// testable.
///
/// Hints are intentionally few and conservative — three rules at most,
/// each silent unless the underlying condition is clearly true. The
/// goal is "informative when actually useful, invisible otherwise,"
/// not "data-driven coaching." A dashboard with too many advisory
/// chips reads as a slot machine instead of a tool.
public enum UsageHints {

    /// One hint surfaced by the advisor.
    public enum Hint: Equatable, Sendable {
        /// Today's premium-tier share (Opus, Fable, Mythos — anything
        /// priced well above Sonnet) is high enough that switching
        /// some work to Sonnet would noticeably reduce spend. Surfaced
        /// only when (a) the day's cost is large enough to matter, and
        /// (b) the user has shown they actually use Sonnet (this week,
        /// so we don't recommend a model they've never tried).
        case heavyPremiumShare(premiumPercentOfToday: Double, todayCost: Double)
        /// Cache hit rate is unusually low — suggests sessions are
        /// being torn down between prompts, or new sessions are
        /// starting from scratch. Surfaced only when token volume is
        /// large enough that the inefficiency is meaningful.
        case lowCacheHitRate(ratio: Double, tokensToday: Int64)
    }

    /// Per-model rollup the advisor reads.
    public struct ModelTotals: Sendable {
        public let model: String
        public let costUSD: Double
        public let inputTokens: Int64
        public let outputTokens: Int64
        public let cacheReadTokens: Int64

        public init(
            model: String,
            costUSD: Double,
            inputTokens: Int64,
            outputTokens: Int64,
            cacheReadTokens: Int64
        ) {
            self.model = model
            self.costUSD = costUSD
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
        }
    }

    /// Threshold for the "heavy premium" hint — premium-tier models
    /// must account for at least this fraction of today's total cost.
    public static let premiumShareThreshold: Double = 0.7
    /// Today must be at least this expensive before we'd surface the
    /// hint — below this, even high premium share isn't worth a card.
    public static let premiumMinTodayCost: Double = 5.0

    /// Model-name fragments that count as "premium tier" for the
    /// heavy-share hint. Opus is $5/$25 per MTok; Fable 5 and
    /// Mythos 5 are $10/$50 — all well above Sonnet's $3/$15, so a
    /// day dominated by any of them is worth the same "consider
    /// Sonnet for routine work" nudge.
    public static let premiumModelFragments: [String] = ["opus", "fable", "mythos"]

    /// True when the model name belongs to a premium-tier family.
    public static func isPremiumModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        return premiumModelFragments.contains { lower.contains($0) }
    }
    /// Cache-hit ratio below this is "low." 0.5 is generous (typical
    /// Claude Code workloads run 80–95%).
    public static let lowCacheHitThreshold: Double = 0.5
    /// Token floor for the cache-hit hint — fewer than this and the
    /// ratio is too noisy to surface.
    public static let cacheTokensFloor: Int64 = 100_000

    /// Produce hints from today's per-model totals and a separate
    /// "this week" set used to confirm the user actually uses Sonnet
    /// (we don't tell them to switch to a model they've never tried).
    public static func compute(
        todayByModel: [ModelTotals],
        thisWeekByModel: [ModelTotals]
    ) -> [Hint] {
        var hints: [Hint] = []

        let todayCost = todayByModel.reduce(0) { $0 + $1.costUSD }
        let premiumTodayCost = todayByModel
            .filter { isPremiumModel($0.model) }
            .reduce(0) { $0 + $1.costUSD }
        let usedSonnetThisWeek = thisWeekByModel.contains {
            $0.model.lowercased().contains("sonnet") && ($0.inputTokens + $0.outputTokens) > 0
        }

        if todayCost >= premiumMinTodayCost,
           premiumTodayCost / todayCost >= premiumShareThreshold,
           usedSonnetThisWeek {
            hints.append(
                .heavyPremiumShare(
                    premiumPercentOfToday: premiumTodayCost / todayCost,
                    todayCost: todayCost
                )
            )
        }

        let todayInput = todayByModel.reduce(0) { $0 + $1.inputTokens }
        let todayCacheRead = todayByModel.reduce(0) { $0 + $1.cacheReadTokens }
        let totalTokensToday = todayByModel.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens
        }
        let denom = Double(todayCacheRead + todayInput)
        if denom > 0,
           totalTokensToday >= cacheTokensFloor {
            let ratio = Double(todayCacheRead) / denom
            if ratio < lowCacheHitThreshold {
                hints.append(
                    .lowCacheHitRate(ratio: ratio, tokensToday: totalTokensToday)
                )
            }
        }

        return hints
    }
}
