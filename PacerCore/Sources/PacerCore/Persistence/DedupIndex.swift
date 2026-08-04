import CryptoKit
import Foundation

/// A compact, on-disk copy of "which turns have we already recorded, and how
/// complete was each one" — so a launch doesn't have to walk the whole sample
/// table to find out.
///
/// The walk it replaces costs 9-16 s on a real 190k-row store and grows
/// forever, because Pacer never deletes raw data. This file is 24 bytes per
/// turn (~4.5 MB there) and loads in milliseconds.
///
/// ## Why this is dangerous, and what makes it safe
///
/// The index is an optimisation of the dedup guard, and the dedup guard is
/// the single most load-bearing correctness rule in the app: without it,
/// resumed sessions replay old turns and costs inflate 2-3x. An index that
/// silently disagrees with the store is therefore worse than no index at all,
/// and it can be wrong in two directions:
///
/// - **Missing entries** ⇒ turns get counted twice. Prevented by refusing to
///   trust an index whose recorded row count doesn't match the store's exactly
///   (`isValid(against:)`). Any mismatch — a crash mid-write, a restore from
///   backup, an account-timeline swap — falls back to the full walk.
/// - **False hits** ⇒ a real turn is dropped. Prevented by keying on a
///   **128-bit** digest rather than a 64-bit one. At 2.78M turns (five years
///   at the maintainer's rate) a 64-bit key carries a ~1-in-5-million chance
///   of one collision; 128 bits makes it ~1-in-10^26. The 8 extra bytes per
///   entry buy the difference between "unlikely" and "never", and the failure
///   would be a silently under-counted turn — exactly the class of bug this
///   codebase just spent a release fixing.
///
/// The index is a cache. The store is the truth. Whenever they disagree, the
/// store wins and the index is rebuilt.
public struct DedupIndex: Sendable {

    /// 128 bits of SHA-256 over the dedup key. Deterministic across launches,
    /// which Swift's built-in `Hasher` is not — it reseeds per process, so it
    /// can never back a persisted index.
    public struct Key: Hashable, Sendable {
        public let hi: UInt64
        public let lo: UInt64

        public init(hi: UInt64, lo: UInt64) {
            self.hi = hi
            self.lo = lo
        }

        public init(_ dedupKey: String) {
            var digest = SHA256()
            digest.update(data: Data(dedupKey.utf8))
            var hi: UInt64 = 0, lo: UInt64 = 0
            for (i, byte) in digest.finalize().enumerated() where i < 16 {
                if i < 8 { hi = (hi << 8) | UInt64(byte) } else { lo = (lo << 8) | UInt64(byte) }
            }
            self.hi = hi
            self.lo = lo
        }
    }

    /// key → best `outputTokens` seen for it. The value is what lets a later,
    /// larger copy of a streamed message upgrade the row we stored; see
    /// `SamplePersister`.
    public var entries: [Key: Int64]
    /// How many rows carried a dedup key when this was written. The validity
    /// check — an index that doesn't account for every keyed row is discarded.
    public var rowCount: Int
    /// Newest `sampledAt` covered. Rows after it are re-walked, so an index
    /// that's merely *behind* is still usable.
    public var watermark: Date

    public init(entries: [Key: Int64], rowCount: Int, watermark: Date) {
        self.entries = entries
        self.rowCount = rowCount
        self.watermark = watermark
    }

    // MARK: - Encoding

    private static let magic: UInt32 = 0x50_44_58_31   // "PDX1"
    private static let formatVersion: UInt32 = 1

    public func encoded() -> Data {
        var out = Data()
        out.reserveCapacity(32 + entries.count * 24)
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { out.append(contentsOf: $0) } }
        put(Self.magic)
        put(Self.formatVersion)
        put(UInt64(rowCount))
        put(watermark.timeIntervalSince1970)
        put(UInt64(entries.count))
        for (key, output) in entries {
            put(key.hi); put(key.lo); put(output)
        }
        return out
    }

    /// Returns nil for anything unrecognised, truncated, or from another
    /// format version — all of which mean "walk the store instead".
    public static func decode(_ data: Data) -> DedupIndex? {
        var offset = 0
        func take<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
        guard let magic = take(UInt32.self), magic == Self.magic,
              let version = take(UInt32.self), version == Self.formatVersion,
              let rowCount = take(UInt64.self),
              let watermark = take(Double.self),
              let count = take(UInt64.self)
        else { return nil }
        // A truncated tail means a partial write; don't half-trust it.
        guard data.count - offset == Int(count) * 24 else { return nil }

        var entries: [Key: Int64] = [:]
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let hi = take(UInt64.self), let lo = take(UInt64.self),
                  let output = take(Int64.self) else { return nil }
            entries[Key(hi: hi, lo: lo)] = output
        }
        return DedupIndex(entries: entries, rowCount: Int(rowCount),
                          watermark: Date(timeIntervalSince1970: watermark))
    }

    /// Whether this index can be trusted for a store with `storeRowCount` rows
    /// carrying a dedup key.
    ///
    /// Deliberately strict: equality, not "close enough". A cheaper check that
    /// tolerated drift would trade a guaranteed-correct fallback for a chance
    /// of double-counting, and the fallback only costs seconds.
    public func isValid(againstKeyedRowCount storeRowCount: Int) -> Bool {
        rowCount == storeRowCount && entries.count <= storeRowCount
    }

    // MARK: - File I/O

    /// Written next to `pacer.sqlite`. Losing it costs a rebuild, nothing more,
    /// so it is deliberately not in the store: keeping it out means a corrupt
    /// index can never corrupt the data it describes.
    public static let fileName = "dedup-index.bin"

    public static func fileURL(inContainer container: URL) -> URL {
        container.appendingPathComponent(fileName)
    }

    public static func load(from url: URL) -> DedupIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// Atomic so a crash mid-write leaves the previous index intact rather
    /// than a truncated one. (`decode` would reject a truncated file anyway —
    /// belt and braces, because the cost of being wrong here is silent
    /// double-counting.)
    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}
