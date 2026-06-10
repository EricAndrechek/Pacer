import Foundation

/// Secondary pricing source: https://models.dev — an open-source model
/// catalog that typically lists new Anthropic models on launch day,
/// days before LiteLLM merges pricing. (claude-fable-5 was live on
/// models.dev within hours of its 2026-06-09 release while LiteLLM
/// carried nothing, which is exactly the gap that priced Fable usage
/// at $0 before v0.2.0.)
///
/// Pacer reads only the `anthropic` provider section, and only to fill
/// models LiteLLM doesn't cover — see `PricingTable.refresh()`. LiteLLM
/// remains the primary source and wins every lookup it can serve.
enum ModelsDevCatalog {

    static let url = URL(string: "https://models.dev/api.json")!

    /// Parse the `anthropic` provider's models into LiteLLM-shaped raw
    /// JSON entries (per-token dollars), keyed by model ID. models.dev
    /// publishes per-MTok dollars under `cost` with `cache_read` /
    /// `cache_write` fields; `cache_write` is the 5-minute rate. The
    /// 1-hour write rate isn't published, so synthesized entries leave
    /// it nil and `CostCalculator` bills 1h writes at the 5m rate — a
    /// small undercount that self-heals once LiteLLM ships the tiered
    /// figure and takes over.
    ///
    /// Entries whose costs are all missing or zero are skipped — same
    /// placeholder rule as `LiteLLMModelPricing.hasUsablePricing`.
    static func anthropicEntries(from data: Data) -> [String: [String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = root["anthropic"] as? [String: Any],
              let models = provider["models"] as? [String: Any] else {
            return [:]
        }
        var result: [String: [String: Any]] = [:]
        result.reserveCapacity(models.count)
        for (id, value) in models {
            guard let model = value as? [String: Any],
                  let cost = model["cost"] as? [String: Any] else { continue }
            func perToken(_ key: String) -> Double? {
                guard let mtok = (cost[key] as? NSNumber)?.doubleValue, mtok > 0 else {
                    return nil
                }
                return mtok / 1_000_000
            }
            var entry: [String: Any] = [:]
            if let v = perToken("input") { entry["input_cost_per_token"] = v }
            if let v = perToken("output") { entry["output_cost_per_token"] = v }
            if let v = perToken("cache_read") { entry["cache_read_input_token_cost"] = v }
            if let v = perToken("cache_write") { entry["cache_creation_input_token_cost"] = v }
            guard !entry.isEmpty else { continue }
            if let limit = model["limit"] as? [String: Any] {
                if let ctx = (limit["context"] as? NSNumber)?.intValue {
                    entry["max_input_tokens"] = ctx
                }
                if let out = (limit["output"] as? NSNumber)?.intValue {
                    entry["max_output_tokens"] = out
                }
            }
            result[id] = entry
        }
        return result
    }
}
