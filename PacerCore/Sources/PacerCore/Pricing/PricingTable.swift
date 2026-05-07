import Foundation

/// In-memory snapshot of model pricing data, keyed by the model name
/// strings LiteLLM uses. Loaded once from either the embedded JSON
/// snapshot (offline default) or a fresh fetch from LiteLLM's GitHub
/// raw URL.
///
/// Lookup is fuzzy because Claude Code emits names like
/// `claude-opus-4-7` while LiteLLM also keys entries under
/// `anthropic.claude-opus-4-7`, `vertex_ai/claude-opus-4-7`,
/// `claude-opus-4-7-20260416`, etc. We try the literal name first,
/// then a list of provider prefixes, then bidirectional substring as a
/// last resort. ccusage uses the same algorithm.
public actor PricingTable {

    public static let shared = PricingTable()

    /// LiteLLM's main JSON. Pacer pins to `main` because LiteLLM ships
    /// pricing updates frequently and we want them. The runtime
    /// refresh path will swap in newer data atomically; the embedded
    /// snapshot is always the fallback when fetch fails.
    public static let liteLLMURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    /// Provider-prefix candidates we try when the literal model name
    /// isn't found. Order matters — most-likely first. Sourced from
    /// ccusage's `CLAUDE_PROVIDER_PREFIXES` (apps/ccusage/src/_pricing-fetcher.ts:6-12).
    private static let providerPrefixes: [String] = [
        "anthropic/",
        "claude-3-5-",
        "claude-3-",
        "claude-",
        "openrouter/openai/",
    ]

    private var pricingByModel: [String: LiteLLMModelPricing] = [:]
    private var loadedAt: Date?

    public init() {}

    /// Load from the embedded snapshot if not already loaded. Cheap to
    /// call repeatedly. The runtime refresh path is `refresh()`.
    public func ensureLoaded() async throws {
        if !pricingByModel.isEmpty { return }
        try loadEmbedded()
    }

    /// Force-reload from the embedded snapshot. Used by tests.
    public func reloadEmbedded() throws {
        try loadEmbedded()
    }

    /// Fetch fresh pricing from LiteLLM's URL. On success, atomically
    /// replace the in-memory table; on failure, keep the existing
    /// (possibly embedded) data. Fail-soft is the right default —
    /// stale-but-real pricing beats broken pricing.
    public func refresh(urlSession: URLSession = .shared) async {
        do {
            let (data, _) = try await urlSession.data(from: Self.liteLLMURL)
            let decoded = try Self.decode(data: data)
            replace(with: decoded)
        } catch {
            Log.write("PricingTable", "refresh failed (\(error)) — keeping existing snapshot")
        }
    }

    /// Look up a model. Returns nil only if no candidate match exists
    /// even via substring fallback.
    public func pricing(for model: String) -> LiteLLMModelPricing? {
        if let direct = pricingByModel[model] {
            return direct
        }
        for prefix in Self.providerPrefixes {
            if let hit = pricingByModel[prefix + model] {
                return hit
            }
        }
        // Bidirectional substring fallback. ccusage tries this both
        // ways: model contains key, or key contains model. Useful when
        // Claude Code emits a versioned name like
        // `claude-haiku-4-5-20251001` that's ALSO a literal LiteLLM
        // key, and when it emits a base name like `claude-opus-4-7`
        // that matches several keys.
        let modelLower = model.lowercased()
        for (key, value) in pricingByModel {
            let keyLower = key.lowercased()
            if keyLower.contains(modelLower) || modelLower.contains(keyLower) {
                return value
            }
        }
        return nil
    }

    public func loadedTimestamp() -> Date? { loadedAt }
    public func modelCount() -> Int { pricingByModel.count }

    // MARK: - Private

    private func loadEmbedded() throws {
        guard let url = Bundle.module.url(forResource: "litellm-pricing", withExtension: "json") else {
            throw PricingTableError.embeddedSnapshotMissing
        }
        let data = try Data(contentsOf: url)
        let decoded = try Self.decode(data: data)
        replace(with: decoded)
    }

    private func replace(with decoded: [String: LiteLLMModelPricing]) {
        pricingByModel = decoded
        loadedAt = Date()
    }

    /// Top-level decode of LiteLLM's JSON. The file is a flat
    /// `{model_name: pricing_object}` dictionary, but the
    /// `sample_spec` documentation entry has STRINGS where numbers
    /// belong (e.g. `"max_tokens": "LEGACY parameter..."`), which
    /// would fail a strict whole-dictionary decode. We decode entries
    /// individually with try/catch — every entry that doesn't decode
    /// or has no usable pricing is silently dropped. ccusage does the
    /// same.
    private static func decode(data: Data) throws -> [String: LiteLLMModelPricing] {
        // First pass: parse to a generic JSON dictionary so we can
        // re-encode each entry independently. JSONSerialization is
        // noticeably faster than JSONDecoder for top-level structure.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: LiteLLMModelPricing] = [:]
        result.reserveCapacity(json.count)
        let decoder = JSONDecoder()
        for (key, value) in json {
            if key == "sample_spec" { continue }
            guard let entryData = try? JSONSerialization.data(withJSONObject: value) else {
                continue
            }
            guard let entry = try? decoder.decode(LiteLLMModelPricing.self, from: entryData) else {
                continue
            }
            guard entry.hasUsablePricing else { continue }
            result[key] = entry
        }
        return result
    }
}

public enum PricingTableError: Error, Sendable {
    case embeddedSnapshotMissing
}
