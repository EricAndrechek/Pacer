import Foundation
import SwiftData

/// What the price catalogs said, dated, kept only when it changed (#352).
///
/// `PriceRecord` keeps each rate vector's timeline, but not the catalog as a
/// whole: a catalog that stops listing a model writes nothing there, curated
/// rows are rewritten and removed with the curated file, and nothing says
/// which prices Pacer was holding at a given moment. Research on past data
/// needs exactly that ("the price Pacer knew at time t"), and it cannot be
/// reconstructed afterwards. So every ledger sync compares what it was given
/// with the newest snapshot and writes a new one only when that differs.
///
/// **What is kept.** The inputs the ledger is built from: the merged
/// catalog's rate vectors for the models the ledger tracks
/// (`PriceLedger.catalogTemplates`, a few hundred, not the 3,500-entry raw
/// catalog) and the curated file's records. That is enough to rebuild the
/// ledger as it stood after any sync. Compressed JSON, a few KB per change,
/// and changes land a few times a week, so the table stays small forever.
@Model
public final class Z003PriceCatalogSnapshot {
    #Index<Z003PriceCatalogSnapshot>([\.capturedAt])

    /// When the sync that saw this content ran.
    public var capturedAt: Date
    /// FNV-1a of the uncompressed payload, hex. Equal content, equal
    /// fingerprint, in every process. Not unique: a catalog that changes
    /// and then changes back is two changes, and both are kept.
    public var fingerprint: String
    /// Rate vectors from the catalogs (`PriceSource` other than curated).
    public var catalogPriceCount: Int
    /// Records from the curated file.
    public var curatedPriceCount: Int
    /// `Contents` as JSON (sorted keys, dates in seconds since 1970),
    /// LZFSE-compressed. Read it back with `contents()`.
    public var payload: Data
    /// Bumped if `Contents` ever changes shape.
    public var format: Int

    public static let currentFormat = 1

    /// The decoded payload.
    public struct Contents: Sendable, Codable, Equatable {
        /// Windowless templates: `effectiveFrom` is a placeholder, the ledger
        /// dates them (`PriceLedgerStore`).
        public var catalog: [PriceRecordValue]
        public var curatedAsOf: Date
        public var curated: [PriceRecordValue]

        public init(catalog: [PriceRecordValue], curated: CuratedPriceHistory) {
            self.catalog = catalog.sorted { $0.id < $1.id }
            self.curatedAsOf = curated.asOf
            self.curated = curated.records.sorted { $0.id < $1.id }
        }

        /// Canonical bytes: the same content encodes the same in every
        /// process, which is what makes the fingerprint comparable.
        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            return try encoder.encode(self)
        }

        static func decode(_ data: Data) throws -> Contents {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(Contents.self, from: data)
        }
    }

    public init(capturedAt: Date, contents: Contents) throws {
        let raw = try contents.encoded()
        self.capturedAt = capturedAt
        fingerprint = Self.fingerprint(of: raw)
        catalogPriceCount = contents.catalog.count
        curatedPriceCount = contents.curated.count
        payload = try (raw as NSData).compressed(using: .lzfse) as Data
        format = Self.currentFormat
    }

    public func contents() throws -> Contents {
        try Contents.decode((payload as NSData).decompressed(using: .lzfse) as Data)
    }

    static func fingerprint(of raw: Data) -> String {
        String(format: "%016llx", StableHash.fnv1a64(raw))
    }

    /// The fingerprint `contents` would be stored under.
    static func fingerprint(of contents: Contents) throws -> String {
        fingerprint(of: try contents.encoded())
    }

    /// The newest snapshot, or nil when there is none. One indexed row.
    static func latest(in context: ModelContext) throws -> PriceCatalogSnapshot? {
        var d = FetchDescriptor<PriceCatalogSnapshot>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)])
        d.fetchLimit = 1
        return try context.fetch(d).first
    }
}

// Entity numbering: a new model is named Z<NNN><Name> so it sorts after every shipped
// entity (AGENTS.md, "A new @Model sorts after every shipped one"); call sites keep the plain name.
public typealias PriceCatalogSnapshot = Z003PriceCatalogSnapshot
