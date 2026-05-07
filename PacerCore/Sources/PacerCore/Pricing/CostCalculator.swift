import Foundation

/// Cost calculation modes mirroring ccusage's `--mode`. The names match
/// ccusage exactly so users can swap between the two tools and get the
/// same output for a given config.
public enum CostMode: String, Sendable, CaseIterable {
    /// Default. Use Claude Code's stored `costUSD` if present, compute
    /// from tokens × pricing otherwise.
    case auto

    /// Always compute from tokens × pricing. Useful for consistent
    /// methodology across history when CC's cost calculation evolves.
    case calculate

    /// Always use stored `costUSD`. Defaults to 0 when missing. Cheapest
    /// — no pricing lookup at all.
    case display
}

/// Applies pricing to a parsed entry. Encapsulates the tiered-pricing
/// logic for 1M-context Claude models (above 200k token threshold) and
/// the cache-creation 5m/1h split.
public struct CostCalculator: Sendable {

    public let mode: CostMode
    private let table: PricingTable

    public init(mode: CostMode = .auto, table: PricingTable = .shared) {
        self.mode = mode
        self.table = table
    }

    /// Cost for a single parsed entry. Always returns a non-negative
    /// double; missing pricing yields 0 (matches ccusage behavior).
    public func cost(for entry: ParsedUsageEntry) async -> Double {
        switch mode {
        case .display:
            return entry.storedCostUSD ?? 0
        case .auto:
            if let stored = entry.storedCostUSD { return stored }
            return await computeCost(model: entry.model, breakdown: entry.breakdown)
        case .calculate:
            return await computeCost(model: entry.model, breakdown: entry.breakdown)
        }
    }

    /// Compute cost from tokens × pricing only. Exposed so callers
    /// running in `.both`-style debug modes can compare stored vs
    /// computed side by side.
    public func computeCost(model: String, breakdown: TokenBreakdown) async -> Double {
        try? await table.ensureLoaded()
        guard let pricing = await table.pricing(for: model) else { return 0 }
        return Self.cost(breakdown: breakdown, pricing: pricing)
    }

    /// Pure pricing-application function — no async, no IO. Public for
    /// unit testing. Applies tiered pricing at the 200k-token threshold
    /// when the pricing row defines it; falls through to flat rates
    /// otherwise.
    public static func cost(breakdown: TokenBreakdown, pricing: LiteLLMModelPricing) -> Double {
        // Each category is priced independently. Within each category,
        // we apply the 200k-tier split when the pricing row supports it.
        // Note: the 200k tier is per-category, not a combined-token
        // threshold — Anthropic prices the input/output/cache portions
        // separately. ccusage's `calculateTieredCost` does the same.
        let inputCost = tieredCost(
            tokens: breakdown.inputTokens,
            base: pricing.inputCostPerToken ?? 0,
            above200k: pricing.inputCostPerTokenAbove200kTokens
        )
        let outputCost = tieredCost(
            tokens: breakdown.outputTokens,
            base: pricing.outputCostPerToken ?? 0,
            above200k: pricing.outputCostPerTokenAbove200kTokens
        )
        let cacheReadCost = tieredCost(
            tokens: breakdown.cacheReadTokens,
            base: pricing.cacheReadInputTokenCost ?? 0,
            above200k: pricing.cacheReadInputTokenCostAbove200kTokens
        )
        let cacheCreate5mCost = tieredCost(
            tokens: breakdown.cacheCreation5mTokens,
            base: pricing.cacheCreationInputTokenCost ?? 0,
            above200k: pricing.cacheCreationInputTokenCostAbove200kTokens
        )
        // 1h cache creation has a separate base rate AND a separate
        // above-200k tier. Both are honored when present.
        let cacheCreate1hCost = tieredCost(
            tokens: breakdown.cacheCreation1hTokens,
            base: pricing.cacheCreationInputTokenCostAbove1hr
                ?? pricing.cacheCreationInputTokenCost ?? 0,
            above200k: pricing.cacheCreationInputTokenCostAbove1hrAbove200kTokens
                ?? pricing.cacheCreationInputTokenCostAbove200kTokens
        )

        return inputCost + outputCost + cacheReadCost + cacheCreate5mCost + cacheCreate1hCost
    }

    private static let tier1Threshold: Int64 = 200_000

    private static func tieredCost(tokens: Int64, base: Double, above200k: Double?) -> Double {
        guard tokens > 0 else { return 0 }
        guard let above200k, above200k > 0, tokens > tier1Threshold else {
            return Double(tokens) * base
        }
        let underTier = Double(tier1Threshold) * base
        let overTier = Double(tokens - tier1Threshold) * above200k
        return underTier + overTier
    }
}
