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
/// fetched from gh-pages next to the appcast and cached in the App Group.
/// Whichever has the later `asOf` wins. The request carries no parameters;
/// it's a static file.
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

    /// Published beside the appcast.
    public static let remoteURL = URL(string: "https://ericandrechek.github.io/Pacer/price-history.json")!

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

    /// Fetch the published copy and cache it if it is valid and no older
    /// than what we have. Best-effort: any failure keeps the current copy.
    @discardableResult
    public static func refresh(urlSession: URLSession = .shared, cacheURL: URL? = nil) async -> Bool {
        do {
            let (data, response) = try await urlSession.data(from: remoteURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return false }
            let fetched = try decode(data)
            guard fetched.asOf >= load(cacheURL: cacheURL).asOf,
                  let destination = cacheURL ?? cacheFileURL() else { return false }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic])
            return true
        } catch {
            Log.write("PricingTable", "price-history refresh failed (\(error)) — keeping the current copy")
            return false
        }
    }
}
