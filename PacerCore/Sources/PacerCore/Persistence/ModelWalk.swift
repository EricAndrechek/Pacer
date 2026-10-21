import Foundation
import SwiftData

/// Every model a descriptor matches, a page at a time, each page fetched
/// through a `ModelContext` of its own (#337).
///
/// **Not `ModelContext.enumerate(_:batchSize:)`.** Measured on a copy of a
/// real 746,732-row store, enumerating `TokenSample` with `batchSize: 5_000`
/// peaked at a 3.3 GB footprint — the same with an autorelease pool around
/// the body or around the whole call — while fetching the same rows 5,000 at
/// a time, each page from a fresh context, peaked at 45 MB in the same ~23 s
/// (one context reused for every page: 119 MB). `enumerate` bounds the
/// objects it hands the block, not what it holds underneath them, and the
/// gigabytes it freed afterwards stayed in the heap as fragmentation: a
/// rebuild ran three such walks.
///
/// **Read-only, saved rows only.** Each page's context is discarded, so a
/// write through a model the body is handed is lost, and a fresh context
/// sees what is saved, not what another context holds pending. Callers walk
/// to compute values.
///
/// **One writer.** Pages are `fetchOffset` windows over the descriptor's own
/// order — the store's natural order when it has none, as `enumerate`'s was —
/// so a row inserted or deleted mid-walk would shift a page boundary. Every
/// caller runs on the scan actor, the only place `TokenSample`s are inserted
/// or deleted.
enum ModelWalk {

    /// Large on purpose. `fetchOffset` makes SQLite step over every earlier
    /// row again for each page, so 5,000-row pages made a full rebuild's
    /// walks ~25% slower than `enumerate` (a 746k-row cycle: 39.7 s → 46.4 s).
    /// At 25,000 it took 39.0 s, and the cycle peaked at 317 MB against the
    /// 3.5 GB it reached enumerating.
    static let pageSize = 25_000

    /// `descriptor`'s own `fetchLimit` is ignored: the walk sets one per page.
    static func forEach<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in container: ModelContainer,
        pageSize: Int = pageSize,
        _ body: (T) throws -> Void
    ) throws {
        var page = descriptor
        page.fetchLimit = pageSize
        var offset = descriptor.fetchOffset ?? 0
        while true {
            page.fetchOffset = offset
            let fetched = try autoreleasepool { () throws -> Int in
                let rows = try ModelContext(container).fetch(page)
                for row in rows { try body(row) }
                return rows.count
            }
            offset += fetched
            if fetched < pageSize { return }
        }
    }
}
