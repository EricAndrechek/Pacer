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
            // and the decode path needs no source awareness. The fetch
            // happens here (Sendable `Data` is all that crosses the
            // actor boundary; the parsed non-Sendable dictionaries
            // stay on this executor) and the merge is synchronous.
            // Best-effort: a models.dev failure yields a LiteLLM-only
            // table.
            var modelsDevData: Data?
            do {
                modelsDevData = try await urlSession.data(from: ModelsDevCatalog.url).0
            } catch {
                Log.write("PricingTable", "models.dev fetch failed (\(error)) — skipping that source")
            }
            var catwalkData: Data?
            do {
                catwalkData = try await urlSession.data(from: CatwalkCatalog.url).0
            } catch {
                Log.write("PricingTable", "catwalk fetch failed (\(error)) — skipping that source")
            }
            let mergedJSON = Self.reconcile(
                secondaries: [
                    ("models.dev", modelsDevData.map(ModelsDevCatalog.anthropicEntries(from:))),
                    ("catwalk", catwalkData.map(CatwalkCatalog.anthropicEntries(from:))),
                ],
                into: rawJSON,
                covered: liteDecoded
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

    /// Add every Anthropic entry from a fetched models.dev payload
    /// that the LiteLLM table doesn't already cover (per the same
    /// fuzzy match lookups use, so an `anthropic.claude-x` LiteLLM
    /// key suppresses a models.dev `claude-x` insert). Synchronous on
    /// purpose: an async signature would send the non-Sendable JSON
    /// dictionaries across an isolation boundary. Best-effort: nil or
    /// unparseable data returns the input unchanged.
    /// The four per-token cost fields consensus is taken over. Kept as one
    /// list so a source that publishes three of them and omits the fourth
    /// contributes to the three it has, rather than being discarded whole.
    static let costFields = [
        "input_cost_per_token",
        "output_cost_per_token",
        "cache_creation_input_token_cost",
        "cache_read_input_token_cost",
    ]

    /// Reconcile every pricing catalog into one table by **per-field
    /// consensus**, rather than letting whichever source is listed first win.
    ///
    /// Tiering — LiteLLM, then fill gaps from the others — can only ever add
    /// a price nobody had. It cannot correct one that is wrong, and a wrong
    /// price is indistinguishable from a right one downstream: it produces a
    /// legal-looking total that nothing revisits. With three independent
    /// catalogs there is enough information to do better, so a majority of
    /// sources outvotes any single one, including the primary.
    ///
    /// Per *field*, not per model, because coverage is ragged: a catalog may
    /// publish input and output but omit the cache tiers. Discarding its
    /// whole entry over the fields it lacks would throw away votes on the
    /// fields it has.
    ///
    /// Resolution, in order:
    ///   - one source has the field → use it (nothing to reconcile);
    ///   - a strict majority agrees → use the agreed value, even against
    ///     LiteLLM, and log it when it overrides the primary;
    ///   - no majority (every source differs) → keep the primary's value and
    ///     log the split, because an arbitrary tie-break dressed up as
    ///     consensus is worse than a known-provenance number.
    ///
    /// Values are compared at 1e-12 to keep JSON float noise from splitting
    /// a unanimous vote three ways.
    static func reconcile(
        secondaries: [(name: String, entries: [String: [String: Any]]?)],
        into rawJSON: [String: Any],
        covered: [String: LiteLLMModelPricing]
    ) -> [String: Any] {
        var merged = rawJSON
        var added: [String] = []
        var corrected: [String] = []
        var split: [String] = []

        // Every model id any secondary knows about.
        var ids = Set<String>()
        for source in secondaries { ids.formUnion(source.entries?.keys ?? [:].keys) }

        for id in ids.sorted() {
            // Which key in the primary table this id corresponds to, if any.
            // Lookups are fuzzy (`anthropic/claude-x`, `claude-x-20260416`),
            // so the vote has to be cast against the entry a lookup would
            // actually find, not the bare id.
            let primaryKey = liteLLMMatchKey(id, in: covered)
            let primaryEntry = primaryKey.flatMap { merged[$0] as? [String: Any] }

            var winner: [String: Any] = primaryEntry ?? [:]
            var changedField = false

            for field in costFields {
                var votes: [(source: String, value: Double)] = []
                if let v = (primaryEntry?[field] as? NSNumber)?.doubleValue, v > 0 {
                    votes.append(("litellm", v))
                }
                for source in secondaries {
                    if let v = (source.entries?[id]?[field] as? NSNumber)?.doubleValue, v > 0 {
                        votes.append((source.name, v))
                    }
                }
                guard !votes.isEmpty else { continue }

                // Tally by value, tolerating float noise.
                var tally: [(value: Double, count: Int)] = []
                for vote in votes {
                    if let i = tally.firstIndex(where: { abs($0.value - vote.value) < 1e-12 }) {
                        tally[i].count += 1
                    } else {
                        tally.append((vote.value, 1))
                    }
                }
                let best = tally.max { $0.count < $1.count }!
                let isMajority = best.count * 2 > votes.count
                let primaryValue = (primaryEntry?[field] as? NSNumber)?.doubleValue

                if tally.count == 1 || isMajority {
                    if let primaryValue, abs(primaryValue - best.value) >= 1e-12 {
                        corrected.append("\(id).\(field): \(primaryValue) → \(best.value) (\(best.count)/\(votes.count))")
                    }
                    if winner[field] == nil
                        || abs(((winner[field] as? NSNumber)?.doubleValue ?? .nan) - best.value) >= 1e-12 {
                        winner[field] = best.value
                        changedField = true
                    }
                } else if let primaryValue {
                    // Every source differs. Keep provenance over arithmetic.
                    split.append("\(id).\(field): \(votes.map { "\($0.source)=\($0.value)" }.joined(separator: " "))")
                    winner[field] = primaryValue
                } else {
                    // No primary to fall back on; take the first source's
                    // reading and say so.
                    split.append("\(id).\(field): \(votes.map { "\($0.source)=\($0.value)" }.joined(separator: " "))")
                    winner[field] = votes[0].value
                    changedField = true
                }
            }

            guard !winner.isEmpty else { continue }

            // Context limits are informational; take them from whoever has
            // one, preferring what is already there.
            for field in ["max_input_tokens", "max_output_tokens"] where winner[field] == nil {
                for source in secondaries {
                    if let v = source.entries?[id]?[field] {
                        winner[field] = v
                        break
                    }
                }
            }

            if let primaryKey {
                if changedField { merged[primaryKey] = winner }
            } else {
                merged[id] = winner
                added.append(id)
            }
        }

        if !added.isEmpty {
            Log.write("PricingTable",
                      "pricing: +\(added.count) model(s) no primary entry covered: "
                        + added.joined(separator: ", "))
        }
        if !corrected.isEmpty {
            Log.write("PricingTable",
                      "pricing: consensus overrode the primary on \(corrected.count) field(s): "
                        + corrected.joined(separator: "; "))
        }
        if !split.isEmpty {
            Log.write("PricingTable",
                      "pricing: no majority on \(split.count) field(s), kept primary: "
                        + split.joined(separator: "; "))
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
    /// The *key* a lookup for `model` would resolve to, using exactly the
    /// order `liteLLMMatch` uses. Consensus needs the key, not the value:
    /// a vote has to be written back to the entry a lookup will actually
    /// find, and the primary table keys entries under names Claude Code
    /// never emits (`anthropic/claude-x`, `claude-x-20260416`).
    static func liteLLMMatchKey(
        _ model: String,
        in table: [String: LiteLLMModelPricing]
    ) -> String? {
        if table[model] != nil { return model }
        for prefix in providerPrefixes where table[prefix + model] != nil {
            return prefix + model
        }
        let modelLower = model.lowercased()
        for key in table.keys {
            let keyLower = key.lowercased()
            if keyLower.contains(modelLower) || modelLower.contains(keyLower) {
                return key
            }
        }
        return nil
    }

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
    static func decode(json: [String: Any]) -> [String: LiteLLMModelPricing] {
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
