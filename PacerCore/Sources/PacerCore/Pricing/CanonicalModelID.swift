import Foundation

/// A model id reduced to what pricing depends on: the canonical model, the
/// provider that served it, and the region class of the endpoint.
///
/// **Why prices key on this and not on the raw string.** The same model
/// reaches Pacer under many spellings: `claude-haiku-4-5-20251001` from Claude
/// Code, `claude-opus-5-5[1m]` with a context suffix, `us.anthropic.claude-
/// sonnet-5` from Bedrock, `claude-sonnet-4-5@20250929` from Vertex, and the
/// catalogs add their own (`anthropic/claude-x`, `vertex_ai/claude-x`,
/// `bedrock/us-east-1/anthropic.claude-x-v1:0`). Matching those as strings is
/// what produced #216: a two-way substring search over a `Dictionary`, so
/// `claude-sonnet-5-5` found `claude-sonnet-5` and was priced at Sonnet 5's
/// rates for a week, and which key won could change between launches.
///
/// Parsing every id, raw and catalog alike, into this one shape lets lookup be
/// an exact dictionary hit. The provider and region are kept rather than
/// stripped because they change the price: `us.anthropic.claude-sonnet-5` is
/// $2.20 per million input tokens, not $2.00 (#297).
public struct CanonicalModelID: Hashable, Sendable, Codable, CustomStringConvertible {

    /// Who served the request. A transcript's plain `claude-*` id is the
    /// Claude API itself, `anthropic`. `other` is any prefix this parser does
    /// not recognise (`openrouter/…`, `databricks/…`): those are kept as-is so
    /// an exact catalog entry can still price them, but they never take part
    /// in cross-provider matching.
    public enum Provider: String, Sendable, Codable, CaseIterable, Comparable {
        case anthropic, bedrock, vertex, foundry, other

        public static func < (a: Provider, b: Provider) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// The endpoint's region class. `global` is the default everywhere.
    /// Bedrock geo profiles (`us.`, `eu.`, `apac.`/`jp.`/`au.`) and US
    /// GovCloud are priced separately by the catalogs, so they stay distinct.
    public enum Region: String, Sendable, Codable, CaseIterable, Comparable {
        case global, us, usGov = "us-gov", eu, apac

        public static func < (a: Region, b: Region) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// Lowercased, with provider prefixes, region prefixes, Bedrock `-v1:0`
    /// version suffixes, Vertex `@…` suffixes, `[1m]`-style context suffixes
    /// and trailing `-YYYYMMDD` date pins removed: `claude-haiku-4-5`.
    public let model: String
    public let provider: Provider
    public let region: Region

    public init(model: String, provider: Provider = .anthropic, region: Region = .global) {
        self.model = model
        self.provider = provider
        self.region = region
    }

    public var description: String {
        provider == .anthropic && region == .global
            ? model : "\(model) [\(provider.rawValue)/\(region.rawValue)]"
    }

    /// The same model on the Claude API's global endpoint — what a plain
    /// transcript id means.
    public var firstParty: CanonicalModelID {
        CanonicalModelID(model: model, provider: .anthropic, region: .global)
    }

    /// Whether `other` is this model with a longer, *version-complete* name:
    /// `claude-opus-4-7-thinking` extends `claude-opus-4-7`, but
    /// `claude-sonnet-5-5` does NOT extend `claude-sonnet-5` — the next token
    /// is a digit, so it is a different version, and pricing it as its
    /// sibling is exactly the bug this type exists to prevent.
    public func isVersionCompletePrefix(of other: String) -> Bool {
        guard other.count > model.count, other.hasPrefix(model) else { return false }
        let rest = other.dropFirst(model.count)
        guard rest.first == "-" else { return false }
        guard let next = rest.dropFirst().first else { return false }
        return !next.isNumber
    }

    // MARK: - Parsing

    /// Parse any spelling of a model id. Pure and total: an id it cannot make
    /// sense of comes back lowercased under `.other`, never nil, so a caller
    /// can always try an exact match.
    ///
    /// Memoized: the recomputers resolve a price per sample, hundreds of
    /// thousands of times per rebuild, over a dozen distinct strings.
    public static func parse(_ raw: String) -> CanonicalModelID {
        cacheLock.lock()
        if let hit = cache[raw] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        let parsed = uncachedParse(raw)
        cacheLock.lock()
        // Bounded: catalogs carry a few thousand keys and transcripts a few
        // dozen models, so this only clears if something feeds it garbage.
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
        cache[raw] = parsed
        cacheLock.unlock()
        return parsed
    }

    nonisolated(unsafe) private static var cache: [String: CanonicalModelID] = [:]
    private static let cacheLock = NSLock()

    /// Bedrock cross-region profile prefixes, longest first so `us-gov.` is
    /// not read as `us.`.
    private static let bedrockGeoPrefixes: [(String, Region)] = [
        ("us-gov.", .usGov), ("global.", .global), ("apac.", .apac),
        ("us.", .us), ("eu.", .eu), ("jp.", .apac), ("au.", .apac),
    ]

    static func uncachedParse(_ raw: String) -> CanonicalModelID {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // `claude-opus-5-5[1m]`: the context-window beta suffix. Pricing is the
        // model's own (long-context tiers are a property of the request's
        // size, not of the suffix — see `PriceLedger`).
        if let bracket = s.firstIndex(of: "[") { s = String(s[..<bracket]) }

        var provider: Provider = .anthropic
        var region: Region = .global

        if s.hasPrefix("anthropic/") {
            // LiteLLM's spelling of the Claude API itself.
            s.removeFirst("anthropic/".count)
        } else if s.hasPrefix("vertex_ai/") {
            provider = .vertex
            s.removeFirst("vertex_ai/".count)
        } else if s.hasPrefix("azure_ai/") {
            provider = .foundry
            s.removeFirst("azure_ai/".count)
        } else if s.hasPrefix("bedrock/") {
            provider = .bedrock
            s.removeFirst("bedrock/".count)
            // `bedrock/us-gov-west-1/anthropic.claude-…`: an AWS region path.
            if let slash = s.firstIndex(of: "/") {
                let awsRegion = String(s[..<slash])
                s = String(s[s.index(after: slash)...])
                region = awsRegion.hasPrefix("us-gov") ? .usGov
                    : awsRegion.hasPrefix("us-") ? .us
                    : awsRegion.hasPrefix("eu-") ? .eu
                    : awsRegion.hasPrefix("ap-") ? .apac
                    : .global
            }
        }
        // Anything else with a slash is a gateway or reseller we don't model.
        if s.contains("/") {
            return CanonicalModelID(model: s, provider: .other, region: .global)
        }

        // Bedrock dotted forms: `us.anthropic.claude-…`, `anthropic.claude-…`.
        for (prefix, geo) in bedrockGeoPrefixes where s.hasPrefix(prefix + "anthropic.") {
            provider = .bedrock
            region = geo
            s.removeFirst(prefix.count + "anthropic.".count)
            break
        }
        if s.hasPrefix("anthropic.") {
            // A bare in-region Bedrock id. The catalogs price it like the
            // global profile, so that is the class it gets.
            provider = .bedrock
            s.removeFirst("anthropic.".count)
        }

        // Vertex pins a version with `@`: `claude-sonnet-4-5@20250929`,
        // `claude-opus-4@default`.
        if let at = s.firstIndex(of: "@") {
            if provider == .anthropic { provider = .vertex }
            s = String(s[..<at])
        }

        // Bedrock's model-version suffix: `-v1:0`, `-v2`, `-v1`.
        if let range = s.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) {
            if provider == .anthropic { provider = .bedrock }
            s.removeSubrange(range)
        }

        // A trailing date pin: `-20251001`. Exactly eight digits, so a model
        // version (`-4-5`) is never mistaken for one.
        if let range = s.range(of: #"-\d{8}$"#, options: .regularExpression) {
            s.removeSubrange(range)
        }

        return CanonicalModelID(model: s, provider: provider, region: region)
    }
}
