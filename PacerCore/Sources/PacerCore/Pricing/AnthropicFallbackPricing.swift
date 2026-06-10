import Foundation

/// Last-resort pricing for Anthropic models that LiteLLM doesn't carry
/// (real) prices for yet. New Claude models routinely show up in
/// Claude Code logs days or weeks before LiteLLM merges a pricing
/// entry — Fable 5 / Mythos 5 launched 2026-06-09 with no LiteLLM
/// entry at all — and without this table their usage silently costs
/// $0 everywhere in the app.
///
/// Consulted ONLY after every LiteLLM lookup path (literal, provider
/// prefix, bidirectional substring) has missed, so LiteLLM stays
/// authoritative the moment it ships a real entry. Zero-priced
/// LiteLLM placeholders are dropped at decode (see
/// `LiteLLMModelPricing.hasUsablePricing`), so they can't shadow a
/// row here.
///
/// Rates from https://platform.claude.com/docs/en/about-claude/pricing
/// (fetched 2026-06-09). Fable 5 and Mythos 5 include the full 1M
/// context window at standard pricing, so no above-200k tier fields.
enum AnthropicFallbackPricing {

    /// Fable 5 / Mythos 5 share a price point: $10 input, $50 output,
    /// $12.50 5m cache write, $20 1h cache write, $1 cache read — per
    /// MTok, stored per-token.
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

    /// Keyed by canonical Claude API model ID. `claude-mythos-preview`
    /// is deliberately absent — Anthropic publishes no pricing for the
    /// invitation-only research preview, and inventing a number would
    /// be worse than reporting $0.
    static let table: [String: LiteLLMModelPricing] = [
        "claude-fable-5": fableTier,
        "claude-mythos-5": fableTier,
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
