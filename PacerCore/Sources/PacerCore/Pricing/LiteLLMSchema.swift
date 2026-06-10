import Foundation

/// One row from LiteLLM's `model_prices_and_context_window.json`. We
/// decode only the fields Pacer actually uses for cost calculation;
/// every other field (provider flags, capability flags, audio/video
/// rates, batch rates, etc.) is ignored. Decoding is fully optional —
/// LiteLLM ships hundreds of model rows with wildly different field
/// sets, and a strict decoder would reject most of them.
public struct LiteLLMModelPricing: Decodable, Sendable, Equatable {
    /// Per-token costs in USD. LiteLLM stores everything as a per-token
    /// dollar amount (e.g. 5e-06 per token = $5.00 per 1M tokens).
    public let inputCostPerToken: Double?
    public let outputCostPerToken: Double?
    public let cacheCreationInputTokenCost: Double?
    public let cacheCreationInputTokenCostAbove1hr: Double?
    public let cacheReadInputTokenCost: Double?

    /// Tiered "above 200k" rates for 1M-context Claude models. When a
    /// single API call exceeds 200k input/output tokens, LiteLLM
    /// charges the higher rate on the over-threshold portion. These
    /// fields will only be populated for models that have tiered
    /// pricing configured — most models leave them nil and we use the
    /// flat rate everywhere.
    public let inputCostPerTokenAbove200kTokens: Double?
    public let outputCostPerTokenAbove200kTokens: Double?
    public let cacheCreationInputTokenCostAbove200kTokens: Double?
    public let cacheReadInputTokenCostAbove200kTokens: Double?

    /// Compound tier: 1h cache creation rate when in the 200k+ context
    /// tier. Applies on top of both `_above_1hr` and `_above_200k_tokens`.
    public let cacheCreationInputTokenCostAbove1hrAbove200kTokens: Double?

    public let maxInputTokens: Int?
    public let maxOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputCostPerToken = "input_cost_per_token"
        case outputCostPerToken = "output_cost_per_token"
        case cacheCreationInputTokenCost = "cache_creation_input_token_cost"
        case cacheCreationInputTokenCostAbove1hr = "cache_creation_input_token_cost_above_1hr"
        case cacheReadInputTokenCost = "cache_read_input_token_cost"

        case inputCostPerTokenAbove200kTokens = "input_cost_per_token_above_200k_tokens"
        case outputCostPerTokenAbove200kTokens = "output_cost_per_token_above_200k_tokens"
        case cacheCreationInputTokenCostAbove200kTokens = "cache_creation_input_token_cost_above_200k_tokens"
        case cacheReadInputTokenCostAbove200kTokens = "cache_read_input_token_cost_above_200k_tokens"

        case cacheCreationInputTokenCostAbove1hrAbove200kTokens = "cache_creation_input_token_cost_above_1hr_above_200k_tokens"

        case maxInputTokens = "max_input_tokens"
        case maxOutputTokens = "max_output_tokens"
    }

    /// True when this row has any pricing data we can use. LiteLLM
    /// includes documentation/template entries (e.g. "sample_spec")
    /// that have the field names but null values, AND placeholder
    /// entries where every cost is an explicit 0 (e.g.
    /// `anthropic.claude-mythos-preview` before real prices were
    /// published). Both kinds must be excluded from the lookup table:
    /// a zero-priced placeholder costs the same as a missing entry,
    /// but if kept it would shadow `AnthropicFallbackPricing` and
    /// silently price a real model at $0.
    public var hasUsablePricing: Bool {
        let costs = [
            inputCostPerToken, outputCostPerToken,
            cacheCreationInputTokenCost, cacheReadInputTokenCost,
        ]
        return costs.contains { ($0 ?? 0) > 0 }
    }
}
