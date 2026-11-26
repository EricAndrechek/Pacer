import Foundation

/// Tertiary pricing source: https://github.com/charmbracelet/catwalk — the
/// model database behind Charm's Crush. Community-maintained, and its
/// Anthropic provider config carries per-model prices in a flat, unambiguous
/// shape.
///
/// **Why a third source when two already agree.** Checked on 2026-09-03,
/// LiteLLM, models.dev and catwalk gave byte-identical figures for every
/// Anthropic model Pacer had usage for — so this buys no correction today,
/// and that is the point worth writing down: the cost bug that prompted it
/// was never a disagreement between sources. It was a model **missing from
/// all of them locally**, because the embedded snapshot was two months old,
/// and a model with no price bills at $0.
///
/// What a third source does buy is coverage on the day a model ships. Each
/// catalog updates on its own schedule; the union is live sooner than any
/// one of them, and that window — between a model appearing in transcripts
/// and appearing in a price table — is precisely when usage silently costs
/// nothing.
///
/// Read only for the `anthropic` provider, and only to fill models the
/// earlier sources don't cover. LiteLLM remains primary; models.dev fills
/// next; this fills last. A source can therefore never *change* a price
/// another source already gave — it can only supply one nobody had.
enum CatwalkCatalog {

    /// The raw provider config. Pinned to `main` for the same reason
    /// LiteLLM is: pricing updates are what we want, and the embedded
    /// snapshot is always the fallback when a fetch fails.
    static let url = URL(
        string: "https://raw.githubusercontent.com/charmbracelet/catwalk/main/internal/providers/configs/anthropic.json"
    )!

    /// Parse catwalk's Anthropic models into LiteLLM-shaped raw JSON entries
    /// (per-token dollars), keyed by model id.
    ///
    /// catwalk publishes per-MTok dollars under flat keys. The two cache
    /// fields are easy to transpose, so they are named here explicitly:
    /// `cost_per_1m_in_cached` is what you pay to **write** an entry to the
    /// cache (Anthropic prices it above the input rate — 12.5 against an
    /// input of 10), and `cost_per_1m_out_cached` is the **read** rate (far
    /// below input). Mapping those the wrong way round would inflate cache
    /// reads by ~50x while looking entirely plausible.
    ///
    /// Catwalk has since moved the prices into a `pricing` object (`input`,
    /// `output`, `cache_create` for the write rate, `cache_hit` for the read
    /// rate). Until #469 noticed, this read only the flat keys and so took
    /// nothing from Catwalk at all; both shapes are read now, the flat key
    /// first. `bin/price-catalog-sync.py` reads them the same way.
    ///
    /// Like models.dev, the 1-hour cache-write tier isn't published, so
    /// synthesized entries leave it nil and `CostCalculator` bills 1h writes
    /// at the 5m rate — a small undercount that self-heals once a primary
    /// source ships the tiered figure.
    ///
    /// Entries whose costs are all missing or zero are skipped, matching
    /// `LiteLLMModelPricing.hasUsablePricing`.
    static func anthropicEntries(from data: Data) -> [String: [String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            return [:]
        }
        var result: [String: [String: Any]] = [:]
        result.reserveCapacity(models.count)
        for model in models {
            guard let id = model["id"] as? String, !id.isEmpty else { continue }
            let pricing = model["pricing"] as? [String: Any] ?? [:]
            func perToken(_ flat: String, _ nested: String) -> Double? {
                guard let mtok = ((model[flat] ?? pricing[nested]) as? NSNumber)?.doubleValue, mtok > 0 else {
                    return nil
                }
                return mtok / 1_000_000
            }
            var entry: [String: Any] = [:]
            if let v = perToken("cost_per_1m_in", "input") { entry["input_cost_per_token"] = v }
            if let v = perToken("cost_per_1m_out", "output") { entry["output_cost_per_token"] = v }
            if let v = perToken("cost_per_1m_in_cached", "cache_create") {
                entry["cache_creation_input_token_cost"] = v
            }
            if let v = perToken("cost_per_1m_out_cached", "cache_hit") {
                entry["cache_read_input_token_cost"] = v
            }
            guard !entry.isEmpty else { continue }
            if let ctx = (model["context_window"] as? NSNumber)?.intValue {
                entry["max_input_tokens"] = ctx
            }
            if let out = (model["default_max_tokens"] as? NSNumber)?.intValue {
                entry["max_output_tokens"] = out
            }
            result[id] = entry
        }
        return result
    }
}
