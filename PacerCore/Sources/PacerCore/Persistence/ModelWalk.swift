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
/// to compute values; a walk that writes goes through `update` (#338).
///
/// **One writer.** Pages are `fetchOffset` windows over the descriptor's own
/// order — the store's natural order when it has none, as `enumerate`'s was —
/// so a row inserted or deleted mid-walk would shift a page boundary; a
/// sorted walk tiles because SQLite breaks ties in an index (`sampledAt` has
/// one) by row id. Every caller walks synchronously on the scan actor, the
/// only place `TokenSample`s are inserted or deleted, so nothing moves under
/// a walk.
public enum ModelWalk {

    /// Large on purpose. `fetchOffset` makes SQLite step over every earlier
    /// row again for each page, so 5,000-row pages made a full rebuild's
    /// walks ~25% slower than `enumerate` (a 746k-row cycle: 39.7 s → 46.4 s).
    /// At 25,000 it took 39.0 s, and the cycle peaked at 317 MB against the
    /// 3.5 GB it reached enumerating.
    public static let pageSize = 25_000

    /// `descriptor`'s own `fetchLimit` is ignored: the walk sets one per page.
    public static func forEach<T: PersistentModel>(
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

    /// How `update` moves from one page to the next.
    public enum Paging: Sendable {
        /// `fetchOffset` windows over the descriptor's order, as `forEach`.
        /// Only for a body that leaves every row in the result set and in its
        /// place: it falsifies no predicate, changes no sort key and deletes
        /// nothing. An unsorted walk is in row-id order, which an update never
        /// moves.
        case offset
        /// Every page from the top, until one comes back short. For a body
        /// that takes every row it is handed OUT of the result set — stamping
        /// the rows a predicate picks because they are unstamped. Offset
        /// paging would skip rows there: the page just saved no longer
        /// matches, so the next offset steps over rows that were never
        /// handed out. A row handed out a second time means the body left it
        /// in, and the walk throws rather than loop.
        case drain
    }

    public enum WalkError: Error, Equatable {
        /// `update` was called with unsaved changes in `owner`.
        case ownerHasPendingChanges
        /// A `.drain` page handed back a row the previous page was given.
        case drainMadeNoProgress
    }

    /// `forEach` for a body that writes: each page is fetched through a fresh
    /// `ModelContext`, mutated, saved there and dropped (#338).
    ///
    /// **Why not `enumerate` in the caller's long-lived context.** It held the
    /// whole walk in memory, as the read walks did (#337), and there every row
    /// the body changes stays pending — retained — until that context next
    /// saves, which for a re-canonicalisation is every row. On a copy of a
    /// real 757,909-row store that peaked at 7.6 GB; paged here, 241 MB, in
    /// 85 s against 98 s. A page's changes are saved before the next page is
    /// fetched, so at most one page exists at a time.
    ///
    /// **`owner` is the context the rest of the cycle reads and writes.** Two
    /// rules keep its view true while other contexts write underneath it:
    ///
    /// - It must have nothing pending (the walk throws otherwise): a fresh
    ///   context sees only what is saved, so a pending insert would be missed
    ///   and a pending change would be read stale. Save it first.
    /// - A row `owner` still holds a live instance of is handed to the body
    ///   as THAT instance, and saved through `owner`. Measured: once another
    ///   context has saved a row, an instance `owner` already held keeps the
    ///   old values, and when `owner` next saves a change to it, those old
    ///   values overwrite the other context's write. Writing it through
    ///   `owner` is also what `enumerate` in `owner` did: it returned
    ///   `owner`'s instance for a row `owner` held. A row `owner` doesn't hold
    ///   is a fault there, so a later read fetches what this walk saved.
    ///   This trusts `owner`'s instances to be current, which the one-writer
    ///   rule above makes true: `owner` and walks like this one are the only
    ///   writers.
    ///
    /// Not for a write that must stay in `owner` until the cycle's own save, or
    /// that later code reads back through object identity — the duplicate
    /// repair's deletes and the streamed-copy upgrades. Those find their rows
    /// with `forEach` and write them through `owner`; they touch a handful of
    /// rows, not the table.
    ///
    /// When it returns, every write has been saved. Returns the rows handed
    /// to the body. `descriptor`'s own `fetchLimit` is ignored, and so is its
    /// `fetchOffset` under `.drain`.
    @discardableResult
    public static func update<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in container: ModelContainer,
        owner: ModelContext,
        paging: Paging,
        pageSize: Int = pageSize,
        _ body: (T) throws -> Void
    ) throws -> Int {
        guard !owner.hasChanges else { throw WalkError.ownerHasPendingChanges }
        var page = descriptor
        page.fetchLimit = pageSize
        var offset = paging == .offset ? (descriptor.fetchOffset ?? 0) : 0
        var visited = 0
        // `.drain` only: the rows the previous page was handed.
        var previous: Set<PersistentIdentifier> = []
        while true {
            page.fetchOffset = offset
            let fetched = try autoreleasepool { () throws -> Int in
                let context = ModelContext(container)
                let rows = try context.fetch(page)
                var handed: Set<PersistentIdentifier> = []
                var ownerWrote = false
                for row in rows {
                    let id = row.persistentModelID
                    if paging == .drain {
                        guard !previous.contains(id) else { throw WalkError.drainMadeNoProgress }
                        handed.insert(id)
                    }
                    if let live: T = owner.registeredModel(for: id) {
                        try body(live)
                        ownerWrote = true
                    } else {
                        try body(row)
                    }
                }
                if context.hasChanges { try context.save() }
                if ownerWrote, owner.hasChanges { try owner.save() }
                previous = handed
                return rows.count
            }
            visited += fetched
            if paging == .offset { offset += fetched }
            if fetched < pageSize { return visited }
        }
    }
}
