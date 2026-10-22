import Foundation

/// One model's five per-token rates, in USD per token.
///
/// Every rate is explicit. When a catalog doesn't publish one and Pacer
/// derives it instead, the matching bit in `derived` says so, so a derived
/// number is never mistaken for a published one.
public struct PriceRates: Sendable, Hashable, Codable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var derived: Derived

    public struct Derived: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// The 1h cache-write rate was not published.
        public static let cacheWrite1h = Derived(rawValue: 1 << 0)
        /// The 5m cache-write rate was not published.
        public static let cacheWrite5m = Derived(rawValue: 1 << 1)
        /// A regional premium was applied to a global rate.
        public static let region = Derived(rawValue: 1 << 2)
        /// A fast-mode multiplier was applied to a standard rate.
        public static let fast = Derived(rawValue: 1 << 3)
    }

    public init(
        input: Double, output: Double, cacheRead: Double,
        cacheWrite5m: Double, cacheWrite1h: Double, derived: Derived = []
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.derived = derived
    }

    /// Every rate times `factor`. Anthropic documents its premiums (fast
    /// mode, data residency, regional endpoints) as multipliers that stack
    /// with the cache multipliers, so all five categories scale together.
    public func scaled(by factor: Double, marking flag: Derived) -> PriceRates {
        PriceRates(
            input: input * factor, output: output * factor, cacheRead: cacheRead * factor,
            cacheWrite5m: cacheWrite5m * factor, cacheWrite1h: cacheWrite1h * factor,
            derived: derived.union(flag))
    }

    /// Rates compared without the `derived` flags — two sources that agree
    /// on every number agree on the price.
    public func sameNumbers(as other: PriceRates) -> Bool {
        abs(input - other.input) < 1e-15 && abs(output - other.output) < 1e-15
            && abs(cacheRead - other.cacheRead) < 1e-15
            && abs(cacheWrite5m - other.cacheWrite5m) < 1e-15
            && abs(cacheWrite1h - other.cacheWrite1h) < 1e-15
    }

    /// `$x/$y` per million tokens, for logs.
    public var perMTokSummary: String {
        func m(_ v: Double) -> String {
            let x = v * 1_000_000
            return x == x.rounded() ? String(format: "%.0f", x) : String(format: "%g", x)
        }
        return "in $\(m(input)) out $\(m(output)) read $\(m(cacheRead)) "
            + "w5m $\(m(cacheWrite5m)) w1h $\(m(cacheWrite1h)) /MTok"
    }
}

/// A cost split by the category that produced it.
///
/// The rollups store these five next to `totalCostUSD` (#296), and the total
/// is always *computed from* them, in this order, so the invariant "the
/// components sum to the total" holds on every row by construction rather
/// than by two running sums happening to agree.
public struct CostComponents: Sendable, Hashable, Codable {
    public var input: Double = 0
    public var output: Double = 0
    public var cacheRead: Double = 0
    public var cacheWrite5m: Double = 0
    public var cacheWrite1h: Double = 0

    public init(
        input: Double = 0, output: Double = 0, cacheRead: Double = 0,
        cacheWrite5m: Double = 0, cacheWrite1h: Double = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    public static let zero = CostComponents()

    public var total: Double { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    /// Tokens times rates, category by category.
    public init(breakdown b: TokenBreakdown, rates r: PriceRates) {
        self.init(
            input: Double(b.inputTokens) * r.input,
            output: Double(b.outputTokens) * r.output,
            cacheRead: Double(b.cacheReadTokens) * r.cacheRead,
            cacheWrite5m: Double(b.cacheCreation5mTokens) * r.cacheWrite5m,
            cacheWrite1h: Double(b.cacheCreation1hTokens) * r.cacheWrite1h)
    }

    public static func + (a: CostComponents, b: CostComponents) -> CostComponents {
        CostComponents(
            input: a.input + b.input, output: a.output + b.output,
            cacheRead: a.cacheRead + b.cacheRead,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
    }

    public static func - (a: CostComponents, b: CostComponents) -> CostComponents {
        CostComponents(
            input: a.input - b.input, output: a.output - b.output,
            cacheRead: a.cacheRead - b.cacheRead,
            cacheWrite5m: a.cacheWrite5m - b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h - b.cacheWrite1h)
    }

    public static func += (a: inout CostComponents, b: CostComponents) { a = a + b }
    public static func -= (a: inout CostComponents, b: CostComponents) { a = a - b }

    /// Split a cost known only as a total (Claude Code's stored `costUSD`)
    /// across the categories, so the components still sum to it.
    ///
    /// Proportional to `weights` (the cost the ledger would have computed)
    /// when those are non-zero. Otherwise (a model with no price) proportional
    /// to the tokens at Anthropic's list-price ratios: input 1, output 5,
    /// cache read 0.1, 5-minute write 1.25, 1-hour write 2. Raw token counts
    /// would put nearly all of it on cache reads, the cheapest tokens. A
    /// stored cost on a line with no tokens at all lands on output, so it is
    /// never lost.
    public static func apportion(
        _ total: Double, like weights: CostComponents, tokens b: TokenBreakdown
    ) -> CostComponents {
        var basis = weights
        if basis.total <= 0 {
            basis = CostComponents(
                input: Double(b.inputTokens), output: Double(b.outputTokens) * 5,
                cacheRead: Double(b.cacheReadTokens) * 0.1,
                cacheWrite5m: Double(b.cacheCreation5mTokens) * 1.25,
                cacheWrite1h: Double(b.cacheCreation1hTokens) * 2)
        }
        let sum = basis.total
        guard sum > 0 else { return CostComponents(output: total) }
        var out = CostComponents(
            input: total * basis.input / sum, output: total * basis.output / sum,
            cacheRead: total * basis.cacheRead / sum,
            cacheWrite5m: total * basis.cacheWrite5m / sum,
            cacheWrite1h: 0)
        // The last category takes the remainder, so the parts sum to exactly
        // `total` rather than to it within rounding.
        out.cacheWrite1h = total - (out.input + out.output + out.cacheRead + out.cacheWrite5m)
        return out
    }
}

/// What one sample costs, and which price record decided it.
public struct SampleCost: Sendable, Hashable {
    public var components: CostComponents
    /// The ledger tokens this cost depends on (`PriceLedger.Resolution.tokens`),
    /// empty when no price was consulted (a stored cost, or display mode).
    /// Rollups keep the union so a later price change rebuilds exactly the
    /// buckets it affects (#217).
    public var pricedBy: [String]
    public var flags: PricingFlags

    public init(components: CostComponents, pricedBy: [String] = [], flags: PricingFlags = []) {
        self.components = components
        self.pricedBy = pricedBy
        self.flags = flags
    }

    public var total: Double { components.total }
    public static let zero = SampleCost(components: .zero)
}

/// Why a price is less than certain. Kept on the resolution so a caller can
/// show it (a warning chip) rather than presenting a guess as a fact.
public struct PricingFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// No price record exists for the model: the cost is zero and unknown.
    public static let unpriced = PricingFlags(rawValue: 1 << 0)
    /// The sample predates (or falls outside) every record's window, so the
    /// nearest record priced it.
    public static let outsideWindow = PricingFlags(rawValue: 1 << 1)
    /// A premium variant (fast mode) with no known rate: priced at zero
    /// rather than guessed at the standard rate.
    public static let unpricedPremium = PricingFlags(rawValue: 1 << 2)
    /// Some rate in use was derived rather than published.
    public static let derivedRate = PricingFlags(rawValue: 1 << 3)
}

/// The set of ledger tokens a bucket was priced by, accumulated sample by
/// sample and stored as `pricedByRecordIds` (#217).
///
/// Consecutive samples in a bucket nearly always carry the very same token
/// array (one model, one price segment), so `add` skips a repeat without
/// hashing — a full rebuild adds several million of these.
public struct PricedBy: Sendable, Equatable {
    public private(set) var tokens: Set<String> = []
    private var last: [String] = []

    public init() {}

    public init(stored: String) {
        if !stored.isEmpty { tokens = Set(stored.split(separator: "\n").map(String.init)) }
    }

    public mutating func add(_ more: [String]) {
        if more == last { return }
        tokens.formUnion(more)
        last = more
    }

    public mutating func add(_ other: PricedBy) { tokens.formUnion(other.tokens) }

    /// Sorted and newline-joined: deterministic, so an unchanged set writes
    /// an unchanged string.
    public var stored: String { tokens.sorted().joined(separator: "\n") }

    public static func == (a: PricedBy, b: PricedBy) -> Bool { a.tokens == b.tokens }
}
