import Foundation

/// In-memory snapshot of model pricing data, keyed by the model name
/// strings LiteLLM uses. Loaded once from either the embedded JSON
/// snapshot (offline default) or a fresh fetch from LiteLLM's GitHub
/// raw URL, gap-filled from models.dev for Anthropic models LiteLLM
/// hasn't priced yet (see `refresh()`).
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
    /// Internal (not private) so `Snapshot` below can reuse the same
    /// list without duplication.
    static let providerPrefixes: [String] = [
        "anthropic/",
        "claude-3-5-",
        "claude-3-",
        "claude-",
        "openrouter/openai/",
    ]

    private var pricingByModel: [String: LiteLLMModelPricing] = [:]
    private var loadedAt: Date?
    /// `true` when the active in-memory snapshot came from the refreshed
    /// cache file (or a direct refresh in this process); `false` when
    /// we fell back to the build-embedded JSON. Lets the refresh task
    /// decide whether the cache file is authoritative.
    private var loadedFromCache: Bool = false

    public init() {}

    /// Load if not already loaded. Prefers the refreshed cache file in
    /// the App Group container (written by `refresh()`); falls back to
    /// the build-embedded snapshot. Cheap to call repeatedly.
    ///
    /// `cacheURL` overrides the App Group path — used by tests, and
    /// available to any future surface that wants to load from an
    /// explicit location.
    public func ensureLoaded(cacheURL: URL? = nil) async throws {
        if !pricingByModel.isEmpty { return }
        try loadFromCacheOrEmbedded(cacheURL: cacheURL)
    }

    /// Force-reload from the embedded snapshot. Used by tests.
    public func reloadEmbedded() throws {
        try loadEmbedded(skipCache: true)
    }

    /// Fetch fresh pricing: LiteLLM's URL as the primary source, then
    /// models.dev as a best-effort secondary that fills only Anthropic
    /// models LiteLLM doesn't cover yet (new Claude models routinely
    /// appear in Claude Code logs days before LiteLLM merges pricing —
    /// Fable 5 priced at $0 for exactly that reason). On success,
    /// atomically replace the in-memory table AND write the merged
    /// JSON to `cacheURL` so a subsequent launch picks up the new
    /// prices without needing the network. On failure, keep the
    /// existing (possibly embedded) data — stale-but-real pricing
    /// beats broken pricing.
    ///
    /// Returns `true` only when the refresh produced a non-empty
    /// decoded table; callers can use this to decide whether to log /
    /// reload the per-process cost cache. A models.dev failure never
    /// fails the refresh — it just yields a LiteLLM-only table.
    @discardableResult
    public func refresh(
        urlSession: URLSession = .shared,
        cacheURL: URL? = nil
    ) async -> Bool {
        do {
            let (data, _) = try await urlSession.data(from: Self.liteLLMURL)
            guard let rawJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Log.write("PricingTable", "refresh: payload not a JSON object — keeping existing snapshot")
                return false
            }
            let liteDecoded = Self.decode(json: rawJSON)
            guard !liteDecoded.isEmpty else {
                Log.write("PricingTable", "refresh: decoded 0 models — keeping existing snapshot")
                return false
            }

            // Secondary source: splice in Anthropic models LiteLLM
            // lacks. Synthesized entries use the LiteLLM field shape,
            // so the cache file stays a plain LiteLLM-shaped document
            // and the decode path needs no source awareness.
            let mergedJSON = await Self.gapFillFromModelsDev(
                into: rawJSON,
                covered: liteDecoded,
                urlSession: urlSession
            )

            let mergedDecoded = Self.decode(json: mergedJSON)
            // Persist the merged payload (not the decoded dict) so the
            // next launch reads a real LiteLLM-shaped file and gets
            // the same decode-and-skip-bad-entries behavior the
            // embedded path uses.
            let destination = cacheURL ?? Self.cacheFileURL()
            if let destination,
               let mergedData = try? JSONSerialization.data(
                withJSONObject: mergedJSON, options: [.sortedKeys]
               ) {
                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try mergedData.write(to: destination, options: [.atomic])
                } catch {
                    Log.write("PricingTable", "cache write failed (\(error)) — keeping in-memory only")
                }
            }
            replace(with: mergedDecoded, fromCache: true)
            return true
        } catch {
            Log.write("PricingTable", "refresh failed (\(error)) — keeping existing snapshot")
            return false
        }
    }

    /// Fetch models.dev and add every Anthropic entry the LiteLLM
    /// table doesn't already cover (per the same fuzzy match lookups
    /// use, so a `anthropic.claude-x` LiteLLM key suppresses a
    /// models.dev `claude-x` insert). Best-effort: any failure returns
    /// the input unchanged.
    private static func gapFillFromModelsDev(
        into rawJSON: [String: Any],
        covered: [String: LiteLLMModelPricing],
        urlSession: URLSession
    ) async -> [String: Any] {
        let entries: [String: [String: Any]]
        do {
            let (data, _) = try await urlSession.data(from: ModelsDevCatalog.url)
            entries = ModelsDevCatalog.anthropicEntries(from: data)
        } catch {
            Log.write("PricingTable", "models.dev fetch failed (\(error)) — LiteLLM-only refresh")
            return rawJSON
        }
        var merged = rawJSON
        var added: [String] = []
        for (id, entry) in entries where liteLLMMatch(id, in: covered) == nil {
            merged[id] = entry
            added.append(id)
        }
        if !added.isEmpty {
            Log.write(
                "PricingTable",
                "models.dev gap-fill: +\(added.count) model(s) LiteLLM lacks: \(added.sorted().joined(separator: ", "))"
            )
        }
        return merged
    }

    /// Cache-file path in the App Group container. nil when the
    /// container isn't available (sandboxed test runners). The cache
    /// lives alongside `pacer.sqlite` so app + widget both see updates.
    public static func cacheFileURL() -> URL? {
        try? PacerStore.sharedContainerURL()
            .appendingPathComponent("litellm-pricing.cache.json")
    }

    /// File-system mtime of the cached pricing JSON, or nil when no
    /// cache file exists yet (fresh install or App Group unavailable).
    /// Callers compare against `Date()` to decide whether the cache is
    /// stale enough to warrant a refresh.
    public static func cacheAge(at url: URL? = nil) -> TimeInterval? {
        guard let cacheURL = url ?? cacheFileURL(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        return Date().timeIntervalSince(mtime)
    }

    /// The fuzzy lookup against a decoded table, WITHOUT the built-in
    /// Anthropic fallback layer: literal key, then provider prefixes,
    /// then bidirectional substring (ccusage tries this both ways:
    /// model contains key, or key contains model — useful when Claude
    /// Code emits a versioned name like `claude-haiku-4-5-20251001`
    /// that's ALSO a literal LiteLLM key, and when it emits a base
    /// name like `claude-opus-4-7` that matches several keys).
    ///
    /// Shared by the actor lookup, the `Snapshot` mirror, and the
    /// `refresh()` gap-fill (which must know what the fetched table
    /// covers BY ITSELF — including the fallback layer there would
    /// wrongly suppress gap-fill for any model the static table
    /// carries).
    static func liteLLMMatch(
        _ model: String,
        in table: [String: LiteLLMModelPricing]
    ) -> LiteLLMModelPricing? {
        if let direct = table[model] {
            return direct
        }
        for prefix in providerPrefixes {
            if let hit = table[prefix + model] {
                return hit
            }
        }
        let modelLower = model.lowercased()
        for (key, value) in table {
            let keyLower = key.lowercased()
            if keyLower.contains(modelLower) || modelLower.contains(keyLower) {
                return value
            }
        }
        return nil
    }

    /// Look up a model. Returns nil only if no candidate match exists
    /// even via substring fallback or the built-in Anthropic fallback
    /// table.
    public func pricing(for model: String) -> LiteLLMModelPricing? {
        // Built-in Anthropic rates last, so the fetched tables win as
        // soon as they ship a real entry.
        Self.liteLLMMatch(model, in: pricingByModel)
            ?? AnthropicFallbackPricing.pricing(for: model)
    }

    public func loadedTimestamp() -> Date? { loadedAt }
    public func modelCount() -> Int { pricingByModel.count }

    /// Sendable, sync-lookup snapshot of the current pricing dictionary.
    /// Used by recomputers and live views that walk thousands of
    /// samples and would otherwise need to `await` the actor for each
    /// per-row pricing lookup. Snapshot reproduces the actor's fuzzy-
    /// match algorithm exactly so callers can swap one for the other
    /// without behavior drift.
    public func snapshot() -> Snapshot {
        Snapshot(pricingByModel: pricingByModel)
    }

    public struct Snapshot: Sendable {
        public let pricingByModel: [String: LiteLLMModelPricing]

        public init(pricingByModel: [String: LiteLLMModelPricing]) {
            self.pricingByModel = pricingByModel
        }

        /// Mirror of `PricingTable.pricing(for:)`. Same fuzzy match,
        /// same built-in Anthropic fallback. Sync.
        public func pricing(for model: String) -> LiteLLMModelPricing? {
            PricingTable.liteLLMMatch(model, in: pricingByModel)
                ?? AnthropicFallbackPricing.pricing(for: model)
        }
    }

    // MARK: - Private

    /// Pick the freshest available snapshot: cache file first, embedded
    /// JSON as fallback. The cache file is only trusted if it decodes
    /// to a non-empty table — a truncated download or corruption falls
    /// through to embedded without surfacing as a user-visible failure.
    private func loadFromCacheOrEmbedded(cacheURL: URL? = nil) throws {
        let url = cacheURL ?? Self.cacheFileURL()
        if let url,
           let data = try? Data(contentsOf: url),
           let decoded = try? Self.decode(data: data),
           !decoded.isEmpty {
            replace(with: decoded, fromCache: true)
            return
        }
        try loadEmbedded(skipCache: true)
    }

    private func loadEmbedded(skipCache: Bool) throws {
        guard let url = Bundle.module.url(forResource: "litellm-pricing", withExtension: "json") else {
            throw PricingTableError.embeddedSnapshotMissing
        }
        let data = try Data(contentsOf: url)
        let decoded = try Self.decode(data: data)
        replace(with: decoded, fromCache: false)
    }

    private func replace(with decoded: [String: LiteLLMModelPricing], fromCache: Bool) {
        pricingByModel = decoded
        loadedAt = Date()
        loadedFromCache = fromCache
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
        return decode(json: json)
    }

    /// Per-entry decode of an already-parsed top-level dictionary —
    /// the shared tail of `decode(data:)` and the refresh merge path
    /// (which needs the parsed dictionary anyway for gap-filling).
    private static func decode(json: [String: Any]) -> [String: LiteLLMModelPricing] {
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
