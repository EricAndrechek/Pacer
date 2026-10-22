import Foundation

/// One of the five priced parts of a cost (#225), in the order every
/// breakdown, bar and stacked chart draws them.
///
/// The order is fixed rather than by size so the same part sits in the same
/// place on every row and every day: a bar sorted by share would move cache
/// reads from one end to the other as a day's mix shifted, and two bars side
/// by side could not be compared.
///
/// It is the order a request's prompt is laid out in, then its reply: the
/// cached prefix the request read back (cache reads), what it is caching now
/// (1h writes before 5m ones, which is the order Anthropic requires their
/// breakpoints in), the uncached tail after the last breakpoint (uncached
/// input), and then the reply (output).
///
/// The case order is only a drawing order. Nothing persists a part by its
/// position, and the raw values are the stable names.
public enum CostComponent: String, CaseIterable, Sendable, Identifiable {
    case cacheRead
    case cacheWrite1h
    case cacheWrite5m
    case input
    case output

    public var id: String { rawValue }

    /// "Uncached input" rather than "Input": all four prompt parts are
    /// input, and this one is the part that missed the cache.
    public var label: String {
        switch self {
        case .input:        return "Uncached input"
        case .output:       return "Output"
        case .cacheRead:    return "Cache reads"
        case .cacheWrite5m: return "5m cache writes"
        case .cacheWrite1h: return "1h cache writes"
        }
    }
}

public extension CostComponents {
    /// The dollars one part contributed.
    subscript(_ part: CostComponent) -> Double {
        switch part {
        case .input:        return input
        case .output:       return output
        case .cacheRead:    return cacheRead
        case .cacheWrite5m: return cacheWrite5m
        case .cacheWrite1h: return cacheWrite1h
        }
    }
}

public extension TokenBreakdown {
    /// The tokens behind one priced part — the one place a `CostComponent`
    /// maps to its token column, as `CostComponents[_:]` is for its dollars.
    /// Every legend that prints a part's tokens reads them through this, so
    /// "cache reads" cannot show the 5m-write count on one screen.
    subscript(_ part: CostComponent) -> Int64 {
        switch part {
        case .input:        return inputTokens
        case .output:       return outputTokens
        case .cacheRead:    return cacheReadTokens
        case .cacheWrite5m: return cacheCreation5mTokens
        case .cacheWrite1h: return cacheCreation1hTokens
        }
    }

    /// Every token of the prompt side: fresh input, cache reads and both
    /// cache-write tiers. Output is the response, not the prompt.
    var promptTokens: Int64 {
        inputTokens + cacheReadTokens + cacheCreation5mTokens + cacheCreation1hTokens
    }

    /// The share of prompt tokens served from the cache:
    /// cache reads ÷ (cache reads + cache writes + input). `nil` when there
    /// was no prompt at all, so an empty day reads as "no answer" rather
    /// than as a 0% hit rate.
    ///
    /// The one definition every surface uses (#225). Two older ones had
    /// drifted apart: `reads ÷ (reads + input)`, which sits near 100% for
    /// any Claude Code session because fresh input is tiny, and
    /// `reads ÷ (reads + writes)`, which ignores input. Counting every prompt
    /// token is what "how much of the context came from the cache" means, and
    /// it is what makes a cache rebuilt every few minutes visible.
    var cacheHitRatio: Double? {
        let prompt = promptTokens
        guard prompt > 0 else { return nil }
        return Double(cacheReadTokens) / Double(prompt)
    }

}

/// What a cost was made of: its five priced parts and the tokens behind them.
///
/// The plain value the shared breakdown view and the stacked charts take, so
/// a day, a project and a model all reach the screen through one shape —
/// whichever rollup (global or per-account) they were summed from.
public struct CostBreakdown: Sendable, Equatable {
    public var cost: CostComponents
    public var tokens: TokenBreakdown

    public init(cost: CostComponents = .zero, tokens: TokenBreakdown = TokenBreakdown()) {
        self.cost = cost
        self.tokens = tokens
    }

    public static let zero = CostBreakdown()

    /// The parts' sum. Rollup totals are written as exactly this sum
    /// (`RollupCostColumns`), so the parts a breakdown shows add up to the
    /// total the rest of the page shows.
    public var total: Double { cost.total }

    public var cacheHitRatio: Double? { tokens.cacheHitRatio }

    /// One part with its dollars and its share of the total.
    public struct Part: Sendable, Equatable, Identifiable {
        public let component: CostComponent
        public let usd: Double
        /// Exact share of the total in 0...1; 0 when the total is 0.
        public let share: Double
        /// Whole-number percent, rounded so the five add up to 100
        /// (largest remainder). 0 for every part when the total is 0.
        public let percent: Int
        /// The tokens this part priced (`TokenBreakdown[_:]`). Shown beside
        /// the dollars because the two tell different stories: cache reads
        /// are ~98% of the tokens and well under that share of the cost.
        public let tokens: Int64
        public var id: CostComponent { component }

        /// "66%", "<1%" for a part too small to round to 1 but not
        /// nothing, "0%" for nothing.
        public var percentLabel: String {
            if percent == 0 && usd > 0 { return "<1%" }
            return "\(percent)%"
        }
    }

    /// All five parts, in `CostComponent` order, zero parts included: the
    /// question is which of the five contributed, and "1h writes: $0" is an
    /// answer to it.
    public var parts: [Part] {
        // A part is never drawn below zero. The only way one gets there is
        // float residue from apportioning a stored cost (`apportion` gives
        // its remainder to the 1h tier), which is -1e-17, not a refund.
        let values = CostComponent.allCases.map { max(0, cost[$0]) }
        let sum = values.reduce(0, +)
        let percents = Self.wholePercents(values, sum: sum)
        return CostComponent.allCases.enumerated().map { i, c in
            Part(component: c, usd: values[i],
                 share: sum > 0 ? values[i] / sum : 0,
                 percent: percents[i],
                 tokens: tokens[c])
        }
    }

    /// Largest-remainder rounding: floor every share, then hand the points
    /// left over to the largest remainders, so the labels sum to exactly 100
    /// instead of to 99 or 101.
    static func wholePercents(_ values: [Double], sum: Double) -> [Int] {
        guard sum > 0 else { return values.map { _ in 0 } }
        let exact = values.map { $0 / sum * 100 }
        var floors = exact.map { Int($0.rounded(.down)) }
        var left = 100 - floors.reduce(0, +)
        let byRemainder = exact.indices.sorted {
            let ra = exact[$0] - Double(floors[$0]), rb = exact[$1] - Double(floors[$1])
            return ra != rb ? ra > rb : $0 < $1
        }
        for i in byRemainder where left > 0 {
            floors[i] += 1
            left -= 1
        }
        return floors
    }

    public static func + (a: CostBreakdown, b: CostBreakdown) -> CostBreakdown {
        var tokens = a.tokens
        tokens.add(b.tokens)
        return CostBreakdown(cost: a.cost + b.cost, tokens: tokens)
    }

    public static func += (a: inout CostBreakdown, b: CostBreakdown) { a = a + b }

    /// The sum of any rows that carry a breakdown.
    public static func sum<S: Sequence>(_ rows: S, _ breakdown: (S.Element) -> CostBreakdown) -> CostBreakdown {
        rows.reduce(into: .zero) { $0 += breakdown($1) }
    }
}

public extension DailyRow {
    var costBreakdown: CostBreakdown { CostBreakdown(cost: cost, tokens: tokens) }
}

public extension HourlyRow {
    var costBreakdown: CostBreakdown { CostBreakdown(cost: cost, tokens: tokens) }
}

public extension ProjectDailyReadable {
    var costBreakdown: CostBreakdown { CostBreakdown(cost: costComponents, tokens: tokens) }
}
