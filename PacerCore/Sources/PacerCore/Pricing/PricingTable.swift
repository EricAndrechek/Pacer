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

    /// Fetch fresh pricing from LiteLLM's URL. On success, atomically
    /// replace the in-memory table AND write the raw JSON to
    /// `cacheURL` so a subsequent launch picks up the new prices
    /// without needing the network. On failure, keep the existing
    /// (possibly embedded) data — stale-but-real pricing beats broken
    /// pricing.
    ///
    /// Returns `true` only when the refresh produced a non-empty
    /// decoded table; callers can use this to decide whether to log /
    /// reload the per-process cost cache.
    @discardableResult
    public func refresh(
        urlSession: URLSession = .shared,
        cacheURL: URL? = nil
    ) async -> Bool {
        do {
            let (data, _) = try await urlSession.data(from: Self.liteLLMURL)
            let decoded = try Self.decode(data: data)
            guard !decoded.isEmpty else {
                Log.write("PricingTable", "refresh: decoded 0 models — keeping existing snapshot")
                return false
            }
            // Persist the raw payload (not the decoded dict) so the
            // next launch reads from a real LiteLLM file shape and
            // gets the same decode-and-skip-bad-entries behavior the
            // embedded path uses.
            let destination = cacheURL ?? Self.cacheFileURL()
            if let destination {
                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: destination, options: [.atomic])
                } catch {
                    Log.write("PricingTable", "cache write failed (\(error)) — keeping in-memory only")
                }
            }
            replace(with: decoded, fromCache: true)
            return true
        } catch {
            Log.write("PricingTable", "refresh failed (\(error)) — keeping existing snapshot")
            return false
        }
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

        /// Mirror of `PricingTable.pricing(for:)`. Same provider-prefix
        /// fallback, same bidirectional substring fallback. Sync.
        public func pricing(for model: String) -> LiteLLMModelPricing? {
            if let direct = pricingByModel[model] {
                return direct
            }
            for prefix in PricingTable.providerPrefixes {
                if let hit = pricingByModel[prefix + model] {
                    return hit
                }
            }
            let modelLower = model.lowercased()
            for (key, value) in pricingByModel {
                let keyLower = key.lowercased()
                if keyLower.contains(modelLower) || modelLower.contains(keyLower) {
                    return value
                }
            }
            return nil
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
