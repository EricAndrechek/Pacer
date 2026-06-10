import Foundation

/// Last-resort pricing for Anthropic models neither dynamic source
/// carries. With `PricingTable.refresh()` merging LiteLLM (primary)
/// and models.dev (secondary, usually live on launch day), this table
/// is load-bearing only for:
///
/// - **Limited-availability models** public catalogs never list: the
///   Project Glasswing family (`claude-mythos-5`,
///   `claude-mythos-preview`) is invite-only and absent from both
///   LiteLLM and models.dev, but Anthropic publishes (or press has
///   reported) real rates for them.
/// - **Offline cold starts** on the day a brand-new model ships,
///   before the first successful refresh, if the embedded snapshot
///   predates the model.
///
/// Consulted ONLY after every fetched-table lookup path (literal,
/// provider prefix, bidirectional substring) has missed, so the
/// dynamic sources win the moment they ship a real entry. Zero-priced
/// placeholder rows are dropped at decode (see
/// `LiteLLMModelPricing.hasUsablePricing`), so they can't shadow a
/// row here.
enum AnthropicFallbackPricing {

    /// Fable 5 / Mythos 5 share a price point: $10 input, $50 output,
    /// $12.50 5m cache write, $20 1h cache write, $1 cache read — per
    /// MTok, stored per-token. Both include the full 1M context window
    /// at standard pricing (no above-200k tier). Source:
    /// https://platform.claude.com/docs/en/about-claude/pricing
    /// (fetched 2026-06-09).
    private static let fableTier = LiteLLMModelPricing(
        inputCostPerToken: 1.0e-05,
        outputCostPerToken: 5.0e-05,
        cacheCreationInputTokenCost: 1.25e-05,
        cacheCreationInputTokenCostAbove1hr: 2.0e-05,
        cacheReadInputTokenCost: 1.0e-06,
        inputCostPerTokenAbove200kTokens: nil,
        outputCostPerTokenAbove200kTokens: nil,
        cacheCreationInputTokenCostAbove200kTokens: nil,
        cacheReadInputTokenCostAbove200kTokens: nil,
        cacheCreationInputTokenCostAbove1hrAbove200kTokens: nil,
        maxInputTokens: 1_000_000,
        maxOutputTokens: 128_000
    )

    /// Mythos Preview partner pricing: $25 input / $125 output per
    /// MTok ("five times the cost of Opus 4.7"), as reported at the
    /// Fable 5 / Mythos 5 launch — Anthropic's own docs price the
    /// successor at "under half" of Preview, consistent with $10 vs
    /// $25. Anthropic's pricing table doesn't list Preview itself, so
    /// cache rates are derived from the standard multipliers that
    /// apply uniformly across the published table (5m write 1.25x,
    /// 1h write 2x, read 0.1x). The long-context docs note Preview
    /// includes the 1M window at standard pricing.
    private static let mythosPreviewTier = LiteLLMModelPricing(
        inputCostPerToken: 2.5e-05,
        outputCostPerToken: 1.25e-04,
        cacheCreationInputTokenCost: 3.125e-05,
        cacheCreationInputTokenCostAbove1hr: 5.0e-05,
        cacheReadInputTokenCost: 2.5e-06,
        inputCostPerTokenAbove200kTokens: nil,
        outputCostPerTokenAbove200kTokens: nil,
        cacheCreationInputTokenCostAbove200kTokens: nil,
        cacheReadInputTokenCostAbove200kTokens: nil,
        cacheCreationInputTokenCostAbove1hrAbove200kTokens: nil,
        maxInputTokens: 1_000_000,
        maxOutputTokens: 128_000
    )

    /// Keyed by canonical Claude API model ID.
    static let table: [String: LiteLLMModelPricing] = [
        "claude-fable-5": fableTier,
        "claude-mythos-5": fableTier,
        "claude-mythos-preview": mythosPreviewTier,
    ]

    /// Exact match first, then "model contains key" — which covers the
    /// variants Claude Code and cloud providers emit: the 1M-context
    /// beta suffix (`claude-fable-5[1m]`), provider prefixes
    /// (`anthropic.claude-fable-5`), and any future date-pinned form
    /// (`claude-fable-5-20260609`). Keys are mutually exclusive
    /// substrings, so dictionary iteration order can't change the
    /// result.
    static func pricing(for model: String) -> LiteLLMModelPricing? {
        if let direct = table[model] { return direct }
        let lower = model.lowercased()
        for (key, value) in table where lower.contains(key) {
            return value
        }
        return nil
    }
}
