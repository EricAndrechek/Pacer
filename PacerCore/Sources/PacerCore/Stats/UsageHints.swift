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
        /// All five parts. The cache hint needs the writes: a hit rate
        /// without them is reads ÷ (reads + input), which sits near 100%
        /// for any Claude Code session and can never look low.
        public let tokens: TokenBreakdown

        public init(model: String, costUSD: Double, tokens: TokenBreakdown) {
            self.model = model
            self.costUSD = costUSD
            self.tokens = tokens
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
    /// Cache-hit ratio (`TokenBreakdown.cacheHitRatio`, reads over every
    /// prompt token) below this is "low". A Claude Code day runs about 97–99%:
    /// each turn re-reads the conversation and writes only what is new. It
    /// drops when the cache expires between turns (5 idle minutes, or an
    /// hour on the 1-hour tier) and the whole context is written again.
    /// 0.90 fired on 4 of the 67 five-hour blocks in the committed sample.
    public static let lowCacheHitThreshold: Double = 0.90
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
            $0.model.lowercased().contains("sonnet") && $0.tokens.all > 0
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

        let today = todayByModel.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
        if today.all >= cacheTokensFloor,
           let ratio = today.cacheHitRatio,
           ratio < lowCacheHitThreshold {
            hints.append(.lowCacheHitRate(ratio: ratio, tokensToday: today.all))
        }

        return hints
    }
}
