import Foundation
import Observation
import SwiftData

/// One account's menu-bar window readings: the fixed 5-hour and 7-day readings
/// of its latest poll, and its recent scoped `limits[]` rows.
public struct MenuBarWindowReadings: Sendable, Equatable {
    public var fixed: [LimitSamplePoint]
    public var scoped: [ScopedWindowRow]

    public init(fixed: [LimitSamplePoint] = [], scoped: [ScopedWindowRow] = []) {
        self.fixed = fixed
        self.scoped = scoped
    }

    /// Read on `context`, which may be any context: the dropdown passes its
    /// main one, the label a fresh one off the main thread.
    ///
    /// Latest batch only for the fixed windows: a window the last poll no
    /// longer reported (the 5-hour one on a verified Ultra account) must not
    /// keep its last value as if it were current.
    ///
    /// The scoped fetch is bounded newest-first, enough to resolve the latest
    /// poll's batch without scanning the append-only table: one poll writes a
    /// handful of scoped rows, and 64 covers far more scoped windows than an
    /// account has. The bound and the scope are applied together. With every
    /// account writing this table, an unscoped "newest 64" can be entirely the
    /// other login's rows, and the caller would render its windows as this
    /// account's.
    public static func read(_ context: ModelContext, account: String?) -> MenuBarWindowReadings {
        let fixed = ((try? context.fetch(LimitScope.rateLimits(account: account, limit: 8))) ?? [])
            .map(\.limitPoint)
            .latestBatch()
        let scoped = ((try? context.fetch(LimitScope.modelScopedLimits(account: account, limit: 64))) ?? [])
            .map(\.scopedWindowRow)
        return MenuBarWindowReadings(fixed: fixed, scoped: scoped)
    }
}

/// What the menu-bar label draws from the store, read off the main thread and
/// only when something it shows was written (PACER-19).
///
/// The label is hosted in the `NSStatusItem` and never unmounts. It held four
/// `@Query`s, and a `@Query` re-fetches on every save of the store, whatever
/// changed, on the main thread (AGENTS.md, "SwiftData facts"): the label paid
/// a fetch for each one its chips read on every save, all day. On a Mac under
/// memory pressure one of them, a one-row indexed fetch of the newest turn,
/// paged in for over two seconds with the main thread waiting on it.
///
/// Two halves, each with its own trigger, so neither re-reads for the other's
/// writes:
///
/// - **Usage** (today's spend and tokens, the newest turn's model), keyed on
///   the local day, the spend scope and `SampleWriteSignal.generation`, and
///   only when a chip shows one of them. The default chips show none.
/// - **Limits** (the windows the icon, the percent chips and the tooltip
///   draw), keyed on `RateLimitWriteSignal.generation`, the scope, the active
///   login and the accounts a chip is pinned to.
///
/// Every read runs on its own `ModelContext` in a detached task and hands back
/// `Sendable` values, assigned in one main-actor turn, so a half's parts never
/// disagree about whose they are. A value equal to the one shown is not
/// assigned, so a read that found nothing new redraws nothing.
@MainActor
@Observable
public final class MenuBarLabelFeed {

    // MARK: - Usage

    /// Everything the usage read depends on. A save that changes none of
    /// these is not a reason to read.
    public struct UsageKey: Hashable, Sendable {
        /// The local day, as `PacerToday.key` and the rollups write it.
        public var day: String
        /// The spend scope: nil is every account (`DailyAggregate`), an id
        /// that account's rows (`AccountDailyAggregate`, its own turns).
        public var account: String?
        /// `SampleWriteSignal.generation`.
        public var writes: UInt64
        /// A cost or tokens chip is shown.
        public var today: Bool
        /// The active-model chip is shown.
        public var model: Bool

        public init(day: String, account: String?, writes: UInt64, today: Bool, model: Bool) {
            self.day = day
            self.account = account
            self.writes = writes
            self.today = today
            self.model = model
        }
    }

    public struct Usage: Sendable, Equatable {
        /// Today's rows for the scope, by model. Empty when no chip asked.
        public var today: [DailyRow]
        /// The newest turn's raw model id for the scope, nil when no chip
        /// asked or there is none.
        public var latestModel: String?

        public init(today: [DailyRow] = [], latestModel: String? = nil) {
            self.today = today
            self.latestModel = latestModel
        }

        public var costUSD: Double { today.reduce(0) { $0 + $1.totalCostUSD } }
        public var tokens: Int64 { today.reduce(0) { $0 + $1.tokens.all } }
    }

    // MARK: - Limits

    public struct LimitsKey: Hashable, Sendable {
        /// `RateLimitWriteSignal.generation`.
        public var writes: UInt64
        /// `UsageScope.accountId` and `.activeAccountId`, resolved in the read
        /// the way the dropdown resolves them (`resolveLimitAccountId`), with
        /// the store's active row as the cold-start fallback.
        public var scope: String?
        public var active: String?
        /// The accounts a chip is pinned to, sorted.
        public var pinned: [String]

        public init(writes: UInt64, scope: String?, active: String?, pinned: [String]) {
            self.writes = writes
            self.scope = scope
            self.active = active
            self.pinned = pinned
        }
    }

    public struct Limits: Sendable, Equatable {
        /// Whose readings `windows` are. The label pairs them with that
        /// account's live values, which must be the same account's.
        public var account: String?
        public var windows: MenuBarWindowReadings
        /// The readings of each account a chip names, by account id.
        public var pinned: [String: MenuBarWindowReadings]
        /// Short names for those accounts, so a chip reads "personal 42%".
        /// Read only when a chip is pinned.
        public var accountLabels: [String: String]

        public init(account: String? = nil, windows: MenuBarWindowReadings = MenuBarWindowReadings(),
                    pinned: [String: MenuBarWindowReadings] = [:], accountLabels: [String: String] = [:]) {
            self.account = account
            self.windows = windows
            self.pinned = pinned
            self.accountLabels = accountLabels
        }
    }

    // MARK: - State

    public private(set) var usage = Usage()
    public private(set) var limits = Limits()

    @ObservationIgnored private let usageLane = KeyedReadLane<UsageKey, Usage>()
    @ObservationIgnored private let limitsLane = KeyedReadLane<LimitsKey, Limits>()

    /// Reads each half has started. Diagnostic: nothing draws them.
    public var usageReads: Int { usageLane.reads }
    public var limitsReads: Int { limitsLane.reads }

    public init() {}

    /// Make `usage` `key`'s, unless it already is.
    public func loadUsage(_ key: UsageKey, from container: ModelContainer) async {
        await usageLane.load(key, read: { key in
            Self.readUsage(key, in: ModelContext(container))
        }, apply: { [self] value in
            if value != usage { usage = value }
        })
    }

    /// Make `limits` `key`'s, unless it already is.
    public func loadLimits(_ key: LimitsKey, from container: ModelContainer) async {
        await limitsLane.load(key, read: { key in
            Self.readLimits(key, in: ModelContext(container))
        }, apply: { [self] value in
            if value != limits { limits = value }
        })
    }

    // MARK: - Reads

    /// Today's rows from the table the scope selects, and the newest turn,
    /// each only when asked. All three fetches are predicated on indexed
    /// columns and the newest-turn one is capped at a row.
    public nonisolated static func readUsage(_ key: UsageKey, in context: ModelContext) -> Usage {
        var usage = Usage()
        if key.today {
            let day = key.day
            let rows: [DailyRow]
            if let account = key.account {
                rows = ((try? context.fetch(FetchDescriptor<AccountDailyAggregate>(
                    predicate: #Predicate { $0.date == day && $0.accountId == account }))) ?? [])
                    .map(\.dailyRow)
            } else {
                rows = ((try? context.fetch(FetchDescriptor<DailyAggregate>(
                    predicate: #Predicate { $0.date == day }))) ?? [])
                    .map(\.dailyRow)
            }
            // A stable order, so a read that found the same rows compares
            // equal to the last and redraws nothing.
            usage.today = rows.sorted { $0.model < $1.model }
        }
        if key.model {
            var newest = FetchDescriptor<TokenSample>(
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
            // Scoped like the totals beside it: unscoped, this named whichever
            // account wrote last, so a menu bar scoped to one account showed
            // the other's model.
            if let account = key.account {
                newest.predicate = #Predicate { $0.accountId == account }
            }
            newest.fetchLimit = 1
            usage.latestModel = (try? context.fetch(newest))?.first?.model
        }
        return usage
    }

    /// The scope's windows, each pinned account's, and their names when any
    /// chip is pinned. A user who pins nothing pays for one account's read.
    public nonisolated static func readLimits(_ key: LimitsKey, in context: ModelContext) -> Limits {
        let account = UsageScope.resolveLimitAccountId(scope: key.scope, active: key.active, in: context)
        var limits = Limits(account: account, windows: MenuBarWindowReadings.read(context, account: account))
        for id in key.pinned {
            limits.pinned[id] = MenuBarWindowReadings.read(context, account: id)
        }
        if !key.pinned.isEmpty {
            let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
            limits.accountLabels = Dictionary(accounts.map { ($0.id, $0.shortLabel) },
                                              uniquingKeysWith: { first, _ in first })
        }
        return limits
    }
}

/// Reads one value per key off the main actor: a key whose value is already
/// shown is not read again, one read runs at a time, and a key asked for while
/// one runs is read after it — only the latest such key, so the key asked for
/// last is always the one left showing.
///
/// The gate `PaceChartCard` and the dropdown's engine ask use, for their
/// reason: a detached read is not cancelled when the `.task` that started it
/// is, so without it a burst of key changes (a scope flipped twice, a run of
/// scan cycles) starts reads that land in any order, and an old account's
/// answer can land last and stay.
@MainActor
final class KeyedReadLane<Key: Hashable & Sendable, Value: Sendable> {
    typealias Read = @Sendable (Key) -> Value
    private typealias Request = (key: Key, read: Read)

    /// The key whose value was last applied.
    private(set) var shown: Key?
    private(set) var reads = 0
    private var inFlight: Key?
    private var queued: Request?

    /// Read `key` (and whatever is queued behind it), handing each value to
    /// `apply` on the main actor in the turn its read lands. Returns at once
    /// when another call's loop will do the read.
    func load(_ key: Key, read: @escaping Read, apply: (Value) -> Void) async {
        if let inFlight {
            // The one in flight already is the latest wish: drop anything
            // queued in between, or it would be read after and left showing.
            queued = key == inFlight ? nil : (key: key, read: read)
            return
        }
        guard key != shown else { return }
        var next: Request? = (key: key, read: read)
        while let current = next {
            inFlight = current.key
            queued = nil
            reads += 1
            let value = await Task.detached(priority: .userInitiated) {
                current.read(current.key)
            }.value
            apply(value)
            shown = current.key
            next = queued
        }
        inFlight = nil
    }
}
