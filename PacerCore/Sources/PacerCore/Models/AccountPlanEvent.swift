import Foundation
import SwiftData

/// One dated change in an account's plan or rate-limit tier (#352).
///
/// `Account` keeps only the current `subscriptionType` and `rateLimitTier`,
/// so a plan change used to overwrite the only record of the old one. That
/// matters beyond the label: the tier decides how big the budget is, so it
/// changes how many meter points a dollar of usage costs, and a fit or a
/// forecast that spans the change is wrong without knowing when it happened.
/// The plan-limit markers in #226 can read the same rows.
///
/// Append-only. A row is written the first time an account's plan is
/// observed, and again whenever the reported pair changes; an unchanged poll
/// writes nothing (`AccountPlanState`). A handful of rows per account.
///
/// What it can and cannot see: these are the strings stored with each
/// Claude Code login, copied when the login was made. A plan Anthropic
/// renames without changing them (Max 20× became Ultra on 2026-10-30 with
/// `default_claude_max_20x` unchanged) is not a change here; `PlanLabel` and
/// the curated events in #226 carry that. And an account polled through
/// several logins can hear two answers after a real change, until the older
/// login is replaced; `reportedBy` says which kind of login said what.
@Model
public final class Z002AccountPlanEvent {
    #Index<Z002AccountPlanEvent>([\.accountId, \.observedAt])

    /// `Account.id`.
    public var accountId: String
    /// When the poll that reported the new values was taken. The change
    /// happened at or before this, after the previous event's poll.
    public var observedAt: Date
    /// `kindFirst` for the first observation Pacer recorded (the plan was
    /// already in effect, since an unknown time), `kindChange` after that.
    public var kind: String
    /// The values in effect from this event on. Either may be nil when no
    /// login has reported it.
    public var subscriptionType: String?
    public var rateLimitTier: String?
    /// The values before, from the previous event. Nil on a first observation.
    public var previousSubscriptionType: String?
    public var previousRateLimitTier: String?
    /// `CredentialCandidate.Source` of the login that reported it
    /// (`keychain`, `desktop`, `parked`, `held`, `override`), when known.
    public var reportedBy: String?

    public static let kindFirst = "first"
    public static let kindChange = "change"

    public init(
        accountId: String, observedAt: Date, kind: String,
        subscriptionType: String?, rateLimitTier: String?,
        previousSubscriptionType: String? = nil, previousRateLimitTier: String? = nil,
        reportedBy: String? = nil
    ) {
        self.accountId = accountId
        self.observedAt = observedAt
        self.kind = kind
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.previousSubscriptionType = previousSubscriptionType
        self.previousRateLimitTier = previousRateLimitTier
        self.reportedBy = reportedBy
    }

    /// An account's events, oldest first.
    public static func history(for accountId: String, in context: ModelContext) throws -> [AccountPlanEvent] {
        try context.fetch(FetchDescriptor<AccountPlanEvent>(
            predicate: #Predicate { $0.accountId == accountId },
            sortBy: [SortDescriptor(\.observedAt)]))
    }

    /// A pair that comes back within this long of being recorded is two
    /// logins disagreeing, not a new change (`AccountPlanState`).
    public static let flapWindow: TimeInterval = 24 * 3600
}

// Entity numbering: a new model is named Z<NNN><Name> so it sorts after every shipped
// entity (AGENTS.md, "A new @Model sorts after every shipped one"); call sites keep the plain name.
public typealias AccountPlanEvent = Z002AccountPlanEvent

public extension AccountPlanEvent {
    /// The row for a decided event.
    convenience init(accountId: String, _ event: AccountPlanState.Event) {
        self.init(accountId: accountId, observedAt: event.observedAt, kind: event.kind,
                  subscriptionType: event.subscriptionType, rateLimitTier: event.rateLimitTier,
                  previousSubscriptionType: event.previousSubscriptionType,
                  previousRateLimitTier: event.previousRateLimitTier,
                  reportedBy: event.reportedBy)
    }
}

/// Everything the plan rule reads for one account: the pair its row holds and
/// its newest few events. Held in memory, a poll's report is decided without a
/// fetch (#413): the poller loads this once per account, on its own actor, and
/// keeps it, rather than reading the events inside `MainActor.run` on every
/// poll.
///
/// **The rule.** A report applies its plan and tier to the row (a nil keeps
/// what the row has, as the poller always did: a login that omits a field has
/// not said it changed), and appends an event when the pair differs from the
/// newest event, or there is none yet, which is the first observation. A
/// report of neither (a reading from a switcher's cache) observes no plan at
/// all.
///
/// **Two logins, two answers.** Each login carries the plan strings from when
/// it was made, and the poller reads one account through several (the keychain
/// login, Desktop's, a switcher's saved copy). After a real plan change the
/// older ones keep the old strings until they are replaced, so polls alternate
/// between the two pairs and the row with them. An event per alternation would
/// be an event per minute. So within `AccountPlanEvent.flapWindow` of a
/// change, going back to the pair it replaced (or to any pair recorded that
/// recently) is not recorded: the change is written once, when it is first
/// heard, and a disagreement that lasts writes about one row a day. A genuine
/// revert inside the window is recorded when the window ends, still "at or
/// before" its `observedAt`.
///
/// Compared against the *events*, not the row, so the history is
/// self-consistent: an upgrade from a build without the table records one
/// first observation per account on its next poll.
public struct AccountPlanState: Sendable, Equatable {

    /// An event as the rule reads it, and as it is written.
    public struct Event: Sendable, Equatable {
        public let observedAt: Date
        public let kind: String
        public let subscriptionType: String?
        public let rateLimitTier: String?
        public let previousSubscriptionType: String?
        public let previousRateLimitTier: String?
        public let reportedBy: String?

        public init(observedAt: Date, kind: String, subscriptionType: String?, rateLimitTier: String?,
                    previousSubscriptionType: String? = nil, previousRateLimitTier: String? = nil,
                    reportedBy: String? = nil) {
            self.observedAt = observedAt
            self.kind = kind
            self.subscriptionType = subscriptionType
            self.rateLimitTier = rateLimitTier
            self.previousSubscriptionType = previousSubscriptionType
            self.previousRateLimitTier = previousRateLimitTier
            self.reportedBy = reportedBy
        }

        init(_ row: AccountPlanEvent) {
            self.init(observedAt: row.observedAt, kind: row.kind,
                      subscriptionType: row.subscriptionType, rateLimitTier: row.rateLimitTier,
                      previousSubscriptionType: row.previousSubscriptionType,
                      previousRateLimitTier: row.previousRateLimitTier,
                      reportedBy: row.reportedBy)
        }
    }

    /// What one report changes.
    public struct Change: Sendable, Equatable {
        /// The pair the row holds from now on.
        public let subscriptionType: String?
        public let rateLimitTier: String?
        /// Whether that pair differs from what the row held: the plan the
        /// account is on moved, whether or not an event is due for it.
        public let planChanged: Bool
        /// The event to append, when the report is a first observation or a
        /// change.
        public let event: Event?
    }

    public private(set) var subscriptionType: String?
    public private(set) var rateLimitTier: String?
    /// Newest first, at most `kept`: all the rule looks at.
    public private(set) var events: [Event]
    /// False when the store has no event table (a test container that never
    /// registered it): the pair still moves, and no event is ever due, rather
    /// than one inserted into a store that cannot hold it.
    public let recordsEvents: Bool

    /// How many of the newest events the rule reads. A handful exist per
    /// account; eight covers every flap a window can hold.
    static let kept = 8

    public init(subscriptionType: String?, rateLimitTier: String?, events: [Event],
                recordsEvents: Bool = true) {
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.events = Array(events.prefix(Self.kept))
        self.recordsEvents = recordsEvents
    }

    /// The account's state as the store holds it: its row's pair (none yet
    /// for an account with no row) and its newest events. One fetch by the
    /// unique id and one indexed fetch of a few rows, on the caller's context.
    public static func load(accountId: String, in context: ModelContext) -> AccountPlanState {
        var row = FetchDescriptor<Account>(predicate: #Predicate { $0.id == accountId })
        row.fetchLimit = 1
        let account = (try? context.fetch(row))?.first
        let events = newestEvents(accountId: accountId, in: context)
        return AccountPlanState(subscriptionType: account?.subscriptionType,
                                rateLimitTier: account?.rateLimitTier,
                                events: events ?? [], recordsEvents: events != nil)
    }

    /// The account's newest events, newest first; nil when the store has no
    /// event table. Asked of the schema: a fetch of an unregistered type
    /// returns nothing rather than throwing, which would read as "no events
    /// yet" and insert a first one the store cannot hold.
    static func newestEvents(accountId: String, in context: ModelContext) -> [Event]? {
        let name = Schema.entityName(for: AccountPlanEvent.self)
        guard context.container.schema.entities.contains(where: { $0.name == name }) else { return nil }
        var newest = FetchDescriptor<AccountPlanEvent>(
            predicate: #Predicate { $0.accountId == accountId },
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)])
        newest.fetchLimit = kept
        guard let rows = try? context.fetch(newest) else { return nil }
        return rows.map(Event.init)
    }

    /// Apply one report, and say what it changes: the row's new pair and the
    /// event due, if any. Nil for a report of neither field. Pure: the caller
    /// writes what it returns (`Account.apply`).
    public mutating func observe(
        subscriptionType reportedPlan: String?, rateLimitTier reportedTier: String?,
        at observedAt: Date, reportedBy: String? = nil
    ) -> Change? {
        guard reportedPlan != nil || reportedTier != nil else { return nil }
        let plan = reportedPlan ?? subscriptionType
        let tier = reportedTier ?? rateLimitTier
        let planChanged = plan != subscriptionType || tier != rateLimitTier
        subscriptionType = plan
        rateLimitTier = tier
        let event = recordsEvents
            ? Self.due(plan: plan, tier: tier, at: observedAt, reportedBy: reportedBy, after: events)
            : nil
        if let event { remember(event) }
        return Change(subscriptionType: plan, rateLimitTier: tier, planChanged: planChanged, event: event)
    }

    /// The event `plan`/`tier` calls for after `events` (newest first).
    private static func due(plan: String?, tier: String?, at observedAt: Date,
                            reportedBy: String?, after events: [Event]) -> Event? {
        func same(_ e: Event) -> Bool { e.subscriptionType == plan && e.rateLimitTier == tier }
        guard let last = events.first else {
            return Event(observedAt: observedAt, kind: AccountPlanEvent.kindFirst,
                         subscriptionType: plan, rateLimitTier: tier, reportedBy: reportedBy)
        }
        if same(last) { return nil }
        func recent(_ e: Event) -> Bool {
            observedAt.timeIntervalSince(e.observedAt) < AccountPlanEvent.flapWindow
        }
        // Back to what the newest change replaced, or to any pair recorded
        // lately: an older login still answering, not a new change.
        let revert = last.kind == AccountPlanEvent.kindChange && recent(last)
            && last.previousSubscriptionType == plan && last.previousRateLimitTier == tier
        if revert || events.contains(where: { same($0) && recent($0) }) { return nil }
        return Event(observedAt: observedAt, kind: AccountPlanEvent.kindChange,
                     subscriptionType: plan, rateLimitTier: tier,
                     previousSubscriptionType: last.subscriptionType,
                     previousRateLimitTier: last.rateLimitTier,
                     reportedBy: reportedBy)
    }

    /// Keep `event` among the newest, in `observedAt` order as the store sorts
    /// them, so the next report reads what a fetch would have returned.
    private mutating func remember(_ event: Event) {
        let at = events.firstIndex { $0.observedAt <= event.observedAt } ?? events.count
        events.insert(event, at: at)
        if events.count > Self.kept { events.removeLast(events.count - Self.kept) }
    }
}

public extension Account {

    /// Write what `AccountPlanState.observe` decided: the pair, and the event
    /// if one is due. No fetch. Does not save; the caller owns the context.
    func apply(_ change: AccountPlanState.Change, in context: ModelContext) {
        subscriptionType = change.subscriptionType
        rateLimitTier = change.rateLimitTier
        if let event = change.event { context.insert(AccountPlanEvent(accountId: id, event)) }
    }

    /// `AccountPlanState`'s rule against the store, for a caller holding this
    /// row and its context: reads the newest events (one indexed fetch of a
    /// few rows), decides, and writes. The poller decides in memory instead
    /// (`OAuthPoller.observePlan`); the rule is the same one. Does not save.
    func observePlan(
        subscriptionType: String?, rateLimitTier: String?, at observedAt: Date,
        reportedBy: String? = nil, in context: ModelContext
    ) {
        guard subscriptionType != nil || rateLimitTier != nil else { return }
        let events = AccountPlanState.newestEvents(accountId: id, in: context)
        var state = AccountPlanState(subscriptionType: self.subscriptionType,
                                     rateLimitTier: self.rateLimitTier,
                                     events: events ?? [], recordsEvents: events != nil)
        guard let change = state.observe(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier,
                                         at: observedAt, reportedBy: reportedBy) else { return }
        apply(change, in: context)
    }
}
