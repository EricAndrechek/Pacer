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
/// **Each page starts where the last one ended, never at an offset (#394).**
/// A `fetchOffset` page makes SQLite step over every earlier row again: the
/// table is a b-tree, so skipping 975,000 rows means reading the leaf pages
/// that hold them. On a copy of a real 1,022,036-row store the last of 41
/// such pages read 92,355 pages (the whole 369 MB table) to return 25,000
/// rows, 17 s with the file cache gone, and the walk read the table 22 times
/// over: 8.6 GB. Instead each page asks for the rows after the last one it
/// was handed — `Z_PK > ?`, a seek on the table's own key, in the row-id order
/// an unsorted fetch returns anyway — so the walk reads the table once
/// (0.39 GB; 2,383 pages for that same last page, 0.03 s). Sorted walks do the
/// same on their sort key, with the row id breaking ties
/// (`forEach(_:orderedBy:in:)`).
///
/// **Read-only, saved rows only.** Each page's context is discarded, so a
/// write through a model the body is handed is lost, and a fresh context
/// sees what is saved, not what another context holds pending. Callers walk
/// to compute values; a walk that writes goes through `update` (#338).
///
/// **One writer.** Every caller walks synchronously on the scan actor, the
/// only place `TokenSample`s are inserted or deleted. A row inserted mid-walk
/// would still be visited if it sorts after the current page, and a deleted
/// one would simply be missing — no page boundary moves, unlike offset
/// paging — but nothing relies on that.
public enum ModelWalk {

    /// Rows per page. Large because each page is a fetch with its own
    /// context: at 25,000 a 746k-row rebuild's walks took 39.0 s and the cycle
    /// peaked at 317 MB, against 3.5 GB enumerating. (5,000 was ~25% slower
    /// then, when every page also re-scanned the rows before it.)
    public static let pageSize = 25_000

    public enum WalkError: Error, Equatable {
        /// `update` was called with unsaved changes in `owner`.
        case ownerHasPendingChanges
        /// A descriptor with a `sortBy` reached a walk that pages by row id.
        /// Pages are cut by the last row's key, so the walk has to know the
        /// order: use `forEach(_:orderedBy:in:)`.
        case sortedDescriptor
    }

    /// In row-id order — what an unsorted fetch returns, a full table scan.
    /// `descriptor` must have no `sortBy`; its `fetchLimit` and `fetchOffset`
    /// are ignored.
    public static func forEach<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in container: ModelContainer,
        pageSize: Int = pageSize,
        _ body: (T) throws -> Void
    ) throws {
        guard descriptor.sortBy.isEmpty else { throw WalkError.sortedDescriptor }
        try walk(byRowID(descriptor, pageSize), in: container) { _, rows in
            for row in rows { try body(row) }
        }
    }

    /// In ascending `key` order, ties in row-id order — what SQLite returns
    /// for an index on `key`, whose entries carry the row id. `descriptor`
    /// must have no `sortBy` (the walk sets it); its `fetchLimit` and
    /// `fetchOffset` are ignored.
    ///
    /// The page after a row whose key is `k` and id `p` is
    /// `key >= k && (key > k || id > p)`: the leading `>=` is what lets SQLite
    /// seek the index straight to `k`, where `key > k || …` alone would scan
    /// it from the start every page.
    public static func forEach<T: PersistentModel, Key: Comparable & Codable & Sendable>(
        _ descriptor: FetchDescriptor<T>,
        orderedBy key: KeyPath<T, Key> & Sendable,
        in container: ModelContainer,
        pageSize: Int = pageSize,
        _ body: (T) throws -> Void
    ) throws {
        guard descriptor.sortBy.isEmpty else { throw WalkError.sortedDescriptor }
        let base = descriptor.predicate
        var first = descriptor
        first.sortBy = [SortDescriptor(key, order: .forward), SortDescriptor(\.persistentModelID, order: .forward)]
        first.fetchLimit = pageSize
        first.fetchOffset = nil
        let pages = Pages(first: first, limit: pageSize) { last in
            let next = Self.after(key, last[keyPath: key], last.persistentModelID)
            guard let base else { return next }
            return #Predicate<T> { base.evaluate($0) && next.evaluate($0) }
        }
        try walk(pages, in: container) { _, rows in
            for row in rows { try body(row) }
        }
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
    /// **Any body, any predicate.** Pages are cut by row id, which no write
    /// moves, so a body may take the rows it is handed out of the predicate —
    /// stamping the rows picked because they are unstamped — or leave them
    /// in, and every matching row is handed out exactly once either way. (The
    /// offset paging this replaced had to be told which: offset windows skip
    /// rows when the page just saved stops matching, so that case refetched
    /// from the top every page instead, re-scanning every row stamped so far.)
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
    /// to the body. `descriptor` must have no `sortBy`; its `fetchLimit` and
    /// `fetchOffset` are ignored.
    @discardableResult
    public static func update<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in container: ModelContainer,
        owner: ModelContext,
        pageSize: Int = pageSize,
        _ body: (T) throws -> Void
    ) throws -> Int {
        guard !owner.hasChanges else { throw WalkError.ownerHasPendingChanges }
        guard descriptor.sortBy.isEmpty else { throw WalkError.sortedDescriptor }
        var visited = 0
        try walk(byRowID(descriptor, pageSize), in: container) { context, rows in
            var ownerWrote = false
            for row in rows {
                if let live: T = owner.registeredModel(for: row.persistentModelID) {
                    try body(live)
                    ownerWrote = true
                } else {
                    try body(row)
                }
            }
            if context.hasChanges { try context.save() }
            if ownerWrote, owner.hasChanges { try owner.save() }
            visited += rows.count
        }
        return visited
    }

    // MARK: - Paging

    /// The first page's descriptor, and how to build the next page's
    /// predicate from the last row of the one before.
    private struct Pages<T: PersistentModel> {
        let first: FetchDescriptor<T>
        let limit: Int
        let after: (T) -> Predicate<T>
    }

    private static func byRowID<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>, _ pageSize: Int
    ) -> Pages<T> {
        let base = descriptor.predicate
        var first = descriptor
        // Row-id order made explicit: the order an unsorted fetch already
        // returns, which SQLite serves from `Z_PK > ?` without a sort.
        first.sortBy = [SortDescriptor(\.persistentModelID, order: .forward)]
        first.fetchLimit = pageSize
        first.fetchOffset = nil
        return Pages(first: first, limit: pageSize) { last in
            let id = last.persistentModelID
            guard let base else { return #Predicate<T> { $0.persistentModelID > id } }
            return #Predicate<T> { base.evaluate($0) && $0.persistentModelID > id }
        }
    }

    /// Fetch page after page until one comes back short. The next page's
    /// predicate is built from the last row before `page` returns, while that
    /// row's context is still alive.
    private static func walk<T: PersistentModel>(
        _ pages: Pages<T>,
        in container: ModelContainer,
        _ page: (ModelContext, [T]) throws -> Void
    ) throws {
        var descriptor = pages.first
        while true {
            let next = try autoreleasepool { () throws -> Predicate<T>? in
                let context = ModelContext(container)
                let rows = try context.fetch(descriptor)
                let next = rows.count < pages.limit ? nil : rows.last.map(pages.after)
                try page(context, rows)
                return next
            }
            guard let next else { return }
            descriptor.predicate = next
        }
    }

    /// `key >= k && (key > k || id > p)`, written out with the expression
    /// builders `#Predicate` expands to, because the macro needs a literal
    /// key path and this one is a parameter.
    private static func after<T: PersistentModel, Key: Comparable & Codable & Sendable>(
        _ key: KeyPath<T, Key> & Sendable, _ k: Key, _ p: PersistentIdentifier
    ) -> Predicate<T> {
        Predicate<T> { row in
            PredicateExpressions.build_Conjunction(
                lhs: PredicateExpressions.build_Comparison(
                    lhs: PredicateExpressions.build_KeyPath(root: row, keyPath: key),
                    rhs: PredicateExpressions.build_Arg(k),
                    op: .greaterThanOrEqual),
                rhs: PredicateExpressions.build_Disjunction(
                    lhs: PredicateExpressions.build_Comparison(
                        lhs: PredicateExpressions.build_KeyPath(root: row, keyPath: key),
                        rhs: PredicateExpressions.build_Arg(k),
                        op: .greaterThan),
                    rhs: PredicateExpressions.build_Comparison(
                        lhs: PredicateExpressions.build_KeyPath(root: row, keyPath: \.persistentModelID),
                        rhs: PredicateExpressions.build_Arg(p),
                        op: .greaterThan)))
        }
    }
}
