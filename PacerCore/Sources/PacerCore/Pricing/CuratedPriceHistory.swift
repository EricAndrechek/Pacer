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
/// Each part comes from whichever copy has it newer (`merged`: the curated
/// records by `asOf`, the price list by its own clock). The request carries no parameters
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
///
/// ## The price list (#469)
///
/// The same file also carries the **catalog** prices, merged and dated once
/// on our side by `bin/price-catalog-sync.py` (a scheduled workflow that
/// commits to `site/public/price-history.json` on `main`), so a Mac no longer
/// fetches LiteLLM, models.dev and Catwalk and dates each change from its own
/// first sighting:
///
/// ```json
///   "catalog": { "changedAt": "2026-11-25T18:00:00Z", "checkedAt": "…",
///     "records": [ { "model": "claude-sonnet-4-5", "provider": "bedrock",
///       "region": "us", "effectiveFrom": "…", "effectiveTo": null,
///       "perMTok": { … }, "derived": ["cacheWrite1h"],
///       "regionalMultiplier": 1.1, "source": "litellm" } ] }
/// ```
///
/// A top-level key the decoder of 0.8.0 through 0.9.4 ignores, so those
/// versions read exactly the curated records they always did
/// (`PriceListTests` checks it against a frozen copy of that decoder, `LegacyPriceHistoryDecoder`).
/// The section has a clock of its own: `asOf` stays the curated review date
/// (every curated row's `reviewedAt` defaults to it, and the precedence rule
/// in `PriceLedger` depends on that), while `changedAt` moves when a record is
/// added or closed and `checkedAt` when the job last confirmed the section
/// (at least weekly, so a quiet week and a broken job look different).
public struct CuratedPriceHistory: Sendable, Equatable {

    public static let schemaVersion = 1

    /// Published beside the appcast (SUFeedURL) on the site. Releases up to
    /// 0.9.3 read the GitHub Pages copy, which the release workflow keeps
    /// identical while that mirror is on (bin/publish-feeds.sh).
    public static let remoteURL = URL(string: "https://pacer.andrechek.com/price-history.json")!

    public let asOf: Date
    public let records: [PriceRecordValue]
    /// The price list's catalog records (`PriceRecordValue.fromPriceList`),
    /// empty when the copy has no `catalog` section (the bundled copy, or a
    /// site copy from before #469).
    public let catalog: [PriceRecordValue]
    public let catalogChangedAt: Date?
    public let catalogCheckedAt: Date?

    public init(asOf: Date, records: [PriceRecordValue], catalog: [PriceRecordValue] = [],
                catalogChangedAt: Date? = nil, catalogCheckedAt: Date? = nil) {
        self.asOf = asOf
        self.records = records
        self.catalog = catalog
        self.catalogChangedAt = catalogChangedAt
        self.catalogCheckedAt = catalogCheckedAt
    }

    /// How fresh the catalog section is, for comparing two copies of it.
    var catalogStamp: Date { catalogCheckedAt ?? catalogChangedAt ?? .distantPast }

    /// Each part from whichever copy has it newer: the curated records by
    /// `asOf`, the catalog section by its own clock. A release bundles a newer
    /// curated part than the cached download may have, while the download has
    /// the newer catalog part (a bundled copy carries none), and neither may
    /// cost the other its part.
    static func merged(_ a: CuratedPriceHistory, _ b: CuratedPriceHistory) -> CuratedPriceHistory {
        let curated = b.asOf >= a.asOf ? b : a
        let catalog = b.catalogStamp >= a.catalogStamp ? b : a
        return CuratedPriceHistory(asOf: curated.asOf, records: curated.records, catalog: catalog.catalog,
                                   catalogChangedAt: catalog.catalogChangedAt,
                                   catalogCheckedAt: catalog.catalogCheckedAt)
    }

    /// Whether this copy is at least as new as `other` in both parts.
    func isAtLeastAsNew(as other: CuratedPriceHistory) -> Bool {
        asOf >= other.asOf && catalogStamp >= other.catalogStamp
    }

    /// Whether the price list has gone unconfirmed for longer than
    /// `PriceSources.listStaleAfter` at `now` (the job stopped, or this Mac
    /// cannot reach the site).
    public func listIsStale(at now: Date) -> Bool {
        guard !catalog.isEmpty, let checked = catalogCheckedAt else { return false }
        return now.timeIntervalSince(checked) > PriceSources.listStaleAfter
    }

    /// The copy as the ledger should take it at `now`. While the list is
    /// fresh, unchanged. Once it is stale, no list record covers a moment
    /// after `checkedAt`: an open one (and any reaching past it) ends there.
    /// The list wins over this Mac's own catalog records wherever both cover a
    /// moment (`PriceLedger.precedence`), and its last records never close
    /// while the job is down; without the cut, the catalogs this Mac fetches
    /// directly in that state (`PriceSources.DirectReason.stale`) could never
    /// price anything the list carries. Moments up to `checkedAt` keep the
    /// list's prices. When the list is confirmed again, its records cover the
    /// gap again, and every Mac prices it alike.
    public func forLedger(at now: Date) -> CuratedPriceHistory {
        guard listIsStale(at: now), let checked = catalogCheckedAt else { return self }
        let cut = catalog.map { r -> PriceRecordValue in
            guard r.effectiveTo.map({ $0 > checked }) ?? true else { return r }
            var c = r
            // A record opened by the last run itself keeps a one-second window:
            // a window must end after it starts.
            c.effectiveTo = max(checked, r.effectiveFrom.addingTimeInterval(1))
            return c
        }
        return CuratedPriceHistory(asOf: asOf, records: records, catalog: cut,
                                   catalogChangedAt: catalogChangedAt, catalogCheckedAt: catalogCheckedAt)
    }

    public static let empty = CuratedPriceHistory(asOf: .distantPast, records: [])

    // MARK: - Decoding

    struct File: Decodable {
        let schema: Int
        let asOf: String
        let records: [Row]
        let catalog: Catalog?

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

        /// The price list's section (#469).
        struct Catalog: Decodable {
            let changedAt: String
            let checkedAt: String
            let records: [CatalogRow]
        }

        struct CatalogRow: Decodable {
            let model: String
            let provider: String?
            let region: String?
            let speed: String?
            let tierAbovePromptTokens: Int64?
            let effectiveFrom: String
            let effectiveTo: String?
            let perMTok: Rates
            /// Rates the catalog did not publish and the job derived
            /// (`cacheWrite5m`, `cacheWrite1h`), as `PriceRates.Derived`.
            let derived: [String]?
            let fastMultiplier: Double?
            let regionalMultiplier: Double?
            /// `PriceSource` raw value: which catalog the price came from.
            let source: String?
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
        guard let section = file.catalog else {
            return CuratedPriceHistory(asOf: asOf, records: out.sorted { $0.id < $1.id })
        }
        let catalog = try decodeCatalog(section.records)
        return CuratedPriceHistory(
            asOf: asOf, records: out.sorted { $0.id < $1.id }, catalog: catalog,
            catalogChangedAt: try date(section.changedAt), catalogCheckedAt: try date(section.checkedAt))
    }

    /// The price list's rows. As strict as the curated rows on what decides a
    /// price (a bad rate or date rejects the file, and the copy in use stays),
    /// but a row for a provider, region or speed this version does not know is
    /// skipped: a later job may list one, and this version could not price it
    /// either way. An unknown `source` is provenance only and reads as LiteLLM.
    static func decodeCatalog(_ rows: [File.CatalogRow]) throws -> [PriceRecordValue] {
        var out: [PriceRecordValue] = []
        for row in rows {
            guard let provider = CanonicalModelID.Provider(rawValue: row.provider ?? "anthropic"),
                  let region = CanonicalModelID.Region(rawValue: row.region ?? "global"),
                  let speed = PriceSpeed(rawValue: row.speed ?? "standard")
            else { continue }
            let r = row.perMTok
            for v in [r.input, r.output, r.cacheRead, r.cacheWrite5m, r.cacheWrite1h] where v < 0 || !v.isFinite {
                throw DecodeError.badField(row.model)
            }
            for m in [row.fastMultiplier, row.regionalMultiplier].compactMap({ $0 }) where m < 0 || !m.isFinite {
                throw DecodeError.badField(row.model)
            }
            let from = try date(row.effectiveFrom)
            let to = try row.effectiveTo.map(date)
            if let to, to <= from { throw DecodeError.badField(row.model) }
            var derived: PriceRates.Derived = []
            for name in row.derived ?? [] {
                if name == "cacheWrite5m" { derived.insert(.cacheWrite5m) }
                if name == "cacheWrite1h" { derived.insert(.cacheWrite1h) }
            }
            let key = CanonicalModelID(model: row.model.lowercased(), provider: provider, region: region)
            let tier = row.tierAbovePromptTokens ?? 0
            out.append(PriceRecordValue(
                id: PriceRecordValue.makeId(origin: .list, key: key, speed: speed, tier: tier, from: from),
                key: key, speed: speed, tierAbovePromptTokens: tier,
                rates: PriceRates(
                    input: r.input / 1_000_000, output: r.output / 1_000_000,
                    cacheRead: r.cacheRead / 1_000_000,
                    cacheWrite5m: r.cacheWrite5m / 1_000_000,
                    cacheWrite1h: r.cacheWrite1h / 1_000_000,
                    derived: derived),
                fastMultiplier: row.fastMultiplier,
                regionalMultiplier: row.regionalMultiplier,
                effectiveFrom: from,
                effectiveTo: to,
                source: row.source.flatMap(PriceSource.init(rawValue:)).flatMap { $0 == .curated ? nil : $0 }
                    ?? .litellm))
        }
        let ids = out.map(\.id)
        guard Set(ids).count == ids.count else {
            throw DecodeError.badField("duplicate catalog record (same model, provider, region, speed, tier and start)")
        }
        return out.sorted { $0.id < $1.id }
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

    /// The newest readable copy, part by part (`merged`): the cached download
    /// and the bundled copy, each part from whichever has it newer.
    public static func load(cacheURL: URL? = nil) -> CuratedPriceHistory {
        let bundled = (try? bundled()) ?? .empty
        guard let cached = cached(cacheURL: cacheURL) else { return bundled }
        return merged(bundled, cached)
    }

    /// The cached download alone, when there is one that decodes.
    static func cached(cacheURL: URL? = nil) -> CuratedPriceHistory? {
        guard let url = cacheURL ?? cacheFileURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    /// How long ago the cached download was last written (a refresh that got
    /// a copy at least as new rewrites it), or nil when there is none. The
    /// refresh loop's clock (`PriceSources`).
    public static func cacheAge(at url: URL? = nil, now: Date = Date()) -> TimeInterval? {
        guard let url = url ?? cacheFileURL(),
              let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        return now.timeIntervalSince(mtime)
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

    /// Fetch the published copy and cache it if it is valid, no older in
    /// either part than the cached copy (which it replaces), and brings
    /// something: a curated part at least as new as the one in use, or a newer
    /// price list. A download whose curated part is older than a new
    /// release's bundled one is still cached for its newer list, since `load`
    /// takes each part from the newer copy. Best-effort: any failure keeps
    /// the current copy.
    /// When the site's copy cannot be read (no answer, not a 200, does not
    /// decode; not merely "not newer"), the same file on `main` is tried once
    /// with the same checks (`FeedFallback`) and the failure is reported.
    @discardableResult
    public static func refresh(urlSession: URLSession = .shared, cacheURL: URL? = nil,
                               primary: URL = remoteURL, fallback: URL = FeedFallback.priceHistoryURL,
                               store: UserDefaults = PacerPreferences.store) async -> Bool {
        await refreshResult(urlSession: urlSession, cacheURL: cacheURL, primary: primary,
                            fallback: fallback, store: store) == .updated
    }

    /// What a refresh found.
    public enum RefreshResult: Sendable, Equatable {
        /// A newer copy, now cached.
        case updated
        /// A copy that decodes but brings nothing newer: a successful check.
        /// (A dev build whose bundled curated part is newer than the site's
        /// gets this every time, and must not be re-asked hourly for it.)
        case current
        /// No usable answer from either host, or the cache could not be written.
        case failed
    }

    /// When a check last got a usable answer (`updated` or `current`): the
    /// refresh loop's clock for the list (`PriceSources`).
    static let lastGoodCheckKey = "pacer.priceList.lastGoodCheck"

    public static func lastGoodCheck(store: UserDefaults = PacerPreferences.store) -> Date? {
        store.object(forKey: lastGoodCheckKey) as? Date
    }

    /// `refresh`, telling a check that brought nothing new from one that failed.
    public static func refreshResult(urlSession: URLSession = .shared, cacheURL: URL? = nil,
                                     primary: URL = remoteURL, fallback: URL = FeedFallback.priceHistoryURL,
                                     store: UserDefaults = PacerPreferences.store,
                                     now: Date = Date()) async -> RefreshResult {
        var fetched = await fetch(request(url: primary, store: store), urlSession: urlSession)
        if case .failure(let failure) = fetched {
            Log.write("PricingTable", "price-history refresh failed (\(failure.domain) \(failure.code)) — trying the fallback")
            fetched = await fetch(request(url: fallback, store: store), urlSession: urlSession)
            var fallbackOK = false
            if case .success = fetched { fallbackOK = true }
            FeedFallback.report(feed: .priceHistory, failure: failure, fallbackOK: fallbackOK, store: store)
        }
        guard case .success(let (history, data)) = fetched else { return .failed }
        do {
            let cachedCopy = cached(cacheURL: cacheURL) ?? .empty
            let inUse = merged((try? bundled()) ?? .empty, cachedCopy)
            guard history.isAtLeastAsNew(as: cachedCopy),
                  history.asOf >= inUse.asOf || history.catalogStamp > inUse.catalogStamp else {
                store.set(now, forKey: lastGoodCheckKey)
                return .current
            }
            guard let destination = cacheURL ?? cacheFileURL() else { return .failed }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic])
            store.set(now, forKey: lastGoodCheckKey)
            return .updated
        } catch {
            Log.write("PricingTable", "price-history cache write failed (\(error)) — keeping the current copy")
            return .failed
        }
    }
}
