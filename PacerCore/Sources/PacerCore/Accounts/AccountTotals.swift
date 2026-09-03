import Foundation
import SwiftData

/// Recent usage per account: what the attribution work is *for*.
///
/// Every other rollup — `DailyAggregate`, `HourlyAggregate`,
/// `ProjectDailyAggregate`, `SessionInfo` — predates accounts and carries no
/// `accountId`, so none of them can answer "what did this account cost".
/// Only `TokenSample` can, and there are hundreds of thousands of those.
///
/// So this is computed off the main actor, cached, and — crucially —
/// **bounded**. A lifetime pass over this machine's 284,835 samples measured
/// **18.4 seconds**, because SwiftData faults whole objects regardless of
/// `propertiesToFetch`. That is far too slow to sit in the scan pipeline at
/// any cadence, and it grows forever.
///
/// A window is also the more useful comparison: what an account has cost
/// *lately* is the question someone with two accounts is asking, and a
/// lifetime figure is dominated by whichever account they used first.
///
/// The proper fix is an `AccountDailyAggregate` maintained incrementally by
/// the recomputers, exactly as `ProjectDailyAggregate` already is for
/// projects — then this becomes a tiny read and the window can be anything.
/// Until that exists, the bound is what keeps the card honest about its
/// cost.
public struct AccountTotals: Sendable, Equatable, Identifiable {
    /// `Account.id`, or nil for turns recorded before the trail existed.
    public let accountId: String?
    public let turns: Int
    public let firstTurnAt: Date?
    public let lastTurnAt: Date?

    public init(accountId: String?, turns: Int, firstTurnAt: Date?, lastTurnAt: Date?) {
        self.accountId = accountId
        self.turns = turns
        self.firstTurnAt = firstTurnAt
        self.lastTurnAt = lastTurnAt
    }

    public var id: String { accountId ?? "\u{0000}unattributed" }
    /// Turns Pacer could not attribute — see `AccountActivation` for why this
    /// is a permanent state rather than a gap to be filled in.
    public var isUnattributed: Bool { accountId == nil }
}

/// Computes and caches `AccountTotals`.
///
/// Deliberately not a `@Model`: these are derived, cheap to recompute, and
/// storing them would mean a fifth rollup to keep consistent with the
/// samples — the exact class of drift `make verify-data` exists to catch.
@ScanActor
public final class AccountTotalsStore {
    public static let shared = AccountTotalsStore()

    /// How stale an answer may get. Lifetime totals move by fractions of a
    /// percent over minutes; recomputing more often would spend real CPU to
    /// change a rendered number by nothing. Paired with an "only when the
    /// scan actually ingested something" gate at the call site, so an idle
    /// machine does no work at all.
    private static let ttl: TimeInterval = 10 * 60

    private var cached: [AccountTotals] = []
    private var computedAt: Date?

    private init() {}

    /// The last computed answer, without triggering work. Views render this.
    public func snapshot() -> [AccountTotals] { cached }

    public var isStale: Bool {
        guard let computedAt else { return true }
        return Date().timeIntervalSince(computedAt) >= Self.ttl
    }

    /// True until the first computation lands. Lets the scan run once on a
    /// cold start even though nothing was ingested that cycle — otherwise a
    /// machine that opens the dashboard before any new usage arrives would
    /// show "not measured yet" indefinitely.
    public var hasNeverComputed: Bool { computedAt == nil }

    /// Recompute if the cache has expired. Returns true when it did work.
    @discardableResult
    public func refreshIfNeeded(container: ModelContainer, force: Bool = false) -> Bool {
        guard force || isStale else { return false }
        cached = Self.compute(container: container)
        computedAt = Date()
        return true
    }

    static func compute(container: ModelContainer) -> [AccountTotals] {
        let started = Date()
        let context = ModelContext(container)

        // Ask SQLite for counts and extremes rather than materialising rows.
        //
        // The obvious implementation — fetch this account's samples and sum
        // them — measured **18.4 s** over 284,835 rows, and still **6.3 s**
        // bounded to 30 days, because SwiftData faults whole objects however
        // few properties you ask for. That is ~66 µs per row either way, so
        // no window makes it viable for a heavy user; the shape of the query
        // has to change, not its range.
        //
        // `fetchCount` compiles to a COUNT and a limit-1 fetch to an
        // ORDER BY … LIMIT 1, both served by the `accountId` and `sampledAt`
        // indexes. Three cheap queries per account instead of one expensive
        // walk.
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        var keys: [String?] = accounts.map { $0.id }
        // Unattributed is a caveat about coverage, not an account, but it
        // still has to be counted or the card would imply full coverage.
        keys.append(nil)

        var results: [AccountTotals] = []
        for key in keys {
            let turns: Int
            let first: Date?
            let last: Date?
            if let key {
                turns = (try? context.fetchCount(
                    FetchDescriptor<TokenSample>(predicate: #Predicate { $0.accountId == key })
                )) ?? 0
                first = edge(context, accountId: key, newest: false)
                last = edge(context, accountId: key, newest: true)
            } else {
                turns = (try? context.fetchCount(
                    FetchDescriptor<TokenSample>(predicate: #Predicate { $0.accountId == nil })
                )) ?? 0
                first = edge(context, accountId: nil, newest: false)
                last = edge(context, accountId: nil, newest: true)
            }
            guard turns > 0 else { continue }
            results.append(AccountTotals(
                accountId: key, turns: turns, firstTurnAt: first, lastTurnAt: last))
        }

        Log.write("AccountTotals",
                  "counted \(results.count) account(s) in "
                    + "\(Int(Date().timeIntervalSince(started) * 1000))ms")

        return results.sorted {
            if $0.isUnattributed != $1.isUnattributed { return !$0.isUnattributed }
            return $0.turns > $1.turns
        }
    }

    /// The oldest or newest turn for an account, as a single indexed row.
    private static func edge(
        _ context: ModelContext, accountId: String?, newest: Bool
    ) -> Date? {
        var descriptor = FetchDescriptor<TokenSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: newest ? .reverse : .forward)]
        )
        if let accountId {
            descriptor.predicate = #Predicate { $0.accountId == accountId }
        } else {
            descriptor.predicate = #Predicate { $0.accountId == nil }
        }
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.sampledAt
    }
}


/// Display-safe, main-actor snapshot of `AccountTotals` for the UI.
///
/// Mirrors `TokenPoolStatus`: the work happens on a background actor and only
/// a small value type crosses to the main thread, so a view never holds a
/// `ModelContext` or triggers a fetch of its own.
@MainActor
@Observable
public final class AccountTotalsStatus {
    public static let shared = AccountTotalsStatus()

    public private(set) var totals: [AccountTotals] = []
    /// nil until the first computation lands, so a view can tell "no
    /// accounts" apart from "not measured yet" and avoid claiming $0.
    public private(set) var computedAt: Date?

    private init() {}

    public func publish(_ totals: [AccountTotals], at date: Date = Date()) {
        self.totals = totals
        self.computedAt = date
    }

    /// Accounts only, in spend order. The unattributed bucket is a caveat
    /// about coverage, not an account, so callers ask for it separately.
    public var accounts: [AccountTotals] { totals.filter { !$0.isUnattributed } }
    public var unattributed: AccountTotals? { totals.first { $0.isUnattributed } }
}
