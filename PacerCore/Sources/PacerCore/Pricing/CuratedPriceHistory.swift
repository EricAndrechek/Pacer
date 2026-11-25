import Foundation

/// The curated, dated price file: reviewed history no catalog can hold (#296,
/// seeded by #298).
///
/// LiteLLM and models.dev publish only a current snapshot. Introductory
/// windows, cancelled rises and launch-day rates exist only in Anthropic's
/// announcements, so they live here, each row with a source and a note.
///
/// **Where it comes from.** A copy is bundled (`Resources/price-history.json`)
/// so a fresh offline install prices history correctly, and a newer copy is
/// fetched from the site next to the appcast (site/public/ on main, written by
/// each release) and cached in the App Group.
/// Whichever has the later `asOf` wins. The request carries no parameters
/// (it's a static file) but four headers that let the site count Macs and
/// versions (`FeedRequestHeaders`).
///
/// ## Format
///
/// ```json
/// { "schema": 1, "asOf": "2026-10-21",
///   "records": [
///     { "model": "claude-sonnet-5", "provider": "anthropic", "region": "global",
///       "speed": "standard", "tierAbovePromptTokens": 0,
///       "effectiveFrom": "2026-06-30", "effectiveTo": null,
///       "perMTok": { "input": 2, "output": 10, "cacheWrite5m": 2.5,
///                    "cacheWrite1h": 4, "cacheRead": 0.2 },
///       "fastMultiplier": null, "regionalMultiplier": 1.1,
///       "sourceURL": "https://…", "note": "…" } ] }
/// ```
///
/// Rates are USD per **million** tokens, because that is how Anthropic
/// publishes them and the file is reviewed by hand. Dates are `YYYY-MM-DD`
/// (UTC midnight) or full ISO 8601 timestamps; `effectiveTo` is exclusive.
/// `provider`, `region`, `speed` and `tierAbovePromptTokens` default to the
/// Claude API's global, standard, base tier.
public struct CuratedPriceHistory: Sendable, Equatable {

    public static let schemaVersion = 1

    /// Published beside the appcast (SUFeedURL) on the site. Releases up to
    /// 0.9.3 read the GitHub Pages copy, which the release workflow keeps
    /// identical while that mirror is on (bin/publish-feeds.sh).
    public static let remoteURL = URL(string: "https://pacer.andrechek.com/price-history.json")!

    public let asOf: Date
    public let records: [PriceRecordValue]

    public init(asOf: Date, records: [PriceRecordValue]) {
        self.asOf = asOf
        self.records = records
    }

    public static let empty = CuratedPriceHistory(asOf: .distantPast, records: [])

    // MARK: - Decoding

    struct File: Decodable {
        let schema: Int
        let asOf: String
        let records: [Row]

        struct Row: Decodable {
            let model: String
            let provider: String?
            let region: String?
            let speed: String?
            let tierAbovePromptTokens: Int64?
            let effectiveFrom: String
            let effectiveTo: String?
            let perMTok: Rates
            let fastMultiplier: Double?
            let regionalMultiplier: Double?
            let reviewedAt: String?
            let sourceURL: String?
            let note: String?
        }

        struct Rates: Decodable {
            let input: Double
            let output: Double
            let cacheRead: Double
            let cacheWrite5m: Double
            let cacheWrite1h: Double
        }
    }

    public enum DecodeError: Error, Equatable {
        case unsupportedSchema(Int)
        case badDate(String)
        case badField(String)
    }

    /// Strict on purpose: a curated row that can't be read exactly is
    /// rejected along with its file, and the previous copy stays in use. A
    /// silently half-read price file is the failure this whole design exists
    /// to avoid.
    public static func decode(_ data: Data) throws -> CuratedPriceHistory {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.schema == schemaVersion else { throw DecodeError.unsupportedSchema(file.schema) }
        let asOf = try date(file.asOf)
        var out: [PriceRecordValue] = []
        for row in file.records {
            guard let provider = CanonicalModelID.Provider(rawValue: row.provider ?? "anthropic"),
                  let region = CanonicalModelID.Region(rawValue: row.region ?? "global"),
                  let speed = PriceSpeed(rawValue: row.speed ?? "standard")
            else { throw DecodeError.badField(row.model) }
            let r = row.perMTok
            for v in [r.input, r.output, r.cacheRead, r.cacheWrite5m, r.cacheWrite1h] where v < 0 || !v.isFinite {
                throw DecodeError.badField(row.model)
            }
            let from = try date(row.effectiveFrom)
            let to = try row.effectiveTo.map(date)
            if let to, to <= from { throw DecodeError.badField(row.model) }
            out.append(PriceRecordValue(
                key: CanonicalModelID(model: row.model.lowercased(), provider: provider, region: region),
                speed: speed,
                tierAbovePromptTokens: row.tierAbovePromptTokens ?? 0,
                rates: PriceRates(
                    input: r.input / 1_000_000, output: r.output / 1_000_000,
                    cacheRead: r.cacheRead / 1_000_000,
                    cacheWrite5m: r.cacheWrite5m / 1_000_000,
                    cacheWrite1h: r.cacheWrite1h / 1_000_000),
                fastMultiplier: row.fastMultiplier,
                regionalMultiplier: row.regionalMultiplier,
                effectiveFrom: from,
                effectiveTo: to,
                source: .curated,
                reviewedAt: try row.reviewedAt.map(date) ?? asOf,
                note: row.note,
                sourceURL: row.sourceURL))
        }
        let ids = out.map(\.id)
        guard Set(ids).count == ids.count else {
            throw DecodeError.badField("duplicate record (same model, provider, region, speed, tier and start)")
        }
        return CuratedPriceHistory(asOf: asOf, records: out.sorted { $0.id < $1.id })
    }

    nonisolated(unsafe) private static let dayFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    nonisolated(unsafe) private static let instantFormatter = ISO8601DateFormatter()

    static func date(_ s: String) throws -> Date {
        if let d = dayFormatter.date(from: s), s.count == 10 { return d }
        if let d = instantFormatter.date(from: s) { return d }
        throw DecodeError.badDate(s)
    }

    // MARK: - Loading

    /// The bundled copy. Throws only if the app was built without it, which a
    /// test catches.
    public static func bundled() throws -> CuratedPriceHistory {
        guard let url = Bundle.module.url(forResource: "price-history", withExtension: "json") else {
            throw PricingTableError.embeddedSnapshotMissing
        }
        return try decode(Data(contentsOf: url))
    }

    /// Where a fetched copy is cached, beside the catalog cache.
    public static func cacheFileURL() -> URL? {
        try? PacerStore.sharedContainerURL().appendingPathComponent("price-history.cache.json")
    }

    /// The newest readable copy: the cached download if it decodes and is at
    /// least as recent as the bundled one, otherwise the bundled one.
    public static func load(cacheURL: URL? = nil) -> CuratedPriceHistory {
        let bundled = (try? bundled()) ?? .empty
        guard let url = cacheURL ?? cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let cached = try? decode(data)
        else { return bundled }
        return cached.asOf >= bundled.asOf ? cached : bundled
    }

    /// The fetch's request: `data(from:)`'s plain GET plus the feed headers.
    /// The previous fetch time is stamped as the request is built (an attempt
    /// counts, a failure included), and only in the user's own app. The
    /// fallback host gets neither: `X-Pacer-*` reach only our own site.
    static func request(url: URL = remoteURL, now: Date = Date(), store: UserDefaults = PacerPreferences.store,
                        headers: FeedRequestHeaderProvider = .priceHistory,
                        record: Bool = LaunchMode.isNormalLaunch) -> URLRequest {
        var request = URLRequest(url: url)
        guard FeedRequestHeaders.isPacerSite(url) else { return request }
        let key = PacerPreferenceKeys.priceHistoryLastFetch
        let last = store.object(forKey: key) as? Date
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        for (k, v) in headers.headers(lastFetch: last, now: now, version: version) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if record { store.set(now, forKey: key) }
        return request
    }

    /// One fetch that is only a success if it is a 200 that decodes.
    private static func fetch(_ request: URLRequest, urlSession: URLSession) async
        -> Result<(history: CuratedPriceHistory, data: Data), FeedFallback.Failure> {
        let data: Data, response: URLResponse
        do { (data, response) = try await urlSession.data(for: request) } catch {
            let ns = error as NSError
            return .failure(.init(domain: ns.domain, code: ns.code))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return .failure(.init(domain: "http", code: http.statusCode, httpStatus: http.statusCode))
        }
        guard let history = try? decode(data) else { return .failure(.init(domain: "decode", code: 0)) }
        return .success((history, data))
    }

    /// Fetch the published copy and cache it if it is valid and no older
    /// than what we have. Best-effort: any failure keeps the current copy.
    /// When the site's copy cannot be read (no answer, not a 200, does not
    /// decode; not merely "not newer"), the same file on `main` is tried once
    /// with the same checks (`FeedFallback`) and the failure is reported.
    @discardableResult
    public static func refresh(urlSession: URLSession = .shared, cacheURL: URL? = nil,
                               primary: URL = remoteURL, fallback: URL = FeedFallback.priceHistoryURL,
                               store: UserDefaults = PacerPreferences.store) async -> Bool {
        var fetched = await fetch(request(url: primary, store: store), urlSession: urlSession)
        if case .failure(let failure) = fetched {
            Log.write("PricingTable", "price-history refresh failed (\(failure.domain) \(failure.code)) — trying the fallback")
            fetched = await fetch(request(url: fallback, store: store), urlSession: urlSession)
            var fallbackOK = false
            if case .success = fetched { fallbackOK = true }
            FeedFallback.report(feed: .priceHistory, failure: failure, fallbackOK: fallbackOK, store: store)
        }
        guard case .success(let (history, data)) = fetched else { return false }
        do {
            guard history.asOf >= load(cacheURL: cacheURL).asOf,
                  let destination = cacheURL ?? cacheFileURL() else { return false }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic])
            return true
        } catch {
            Log.write("PricingTable", "price-history cache write failed (\(error)) — keeping the current copy")
            return false
        }
    }
}
