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
/// writes nothing (`Account.observePlan`). A handful of rows per account.
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
    /// logins disagreeing, not a new change (`Account.observePlan`).
    public static let flapWindow: TimeInterval = 24 * 3600
}

// Entity numbering: a new model is named Z<NNN><Name> so it sorts after every shipped
// entity (AGENTS.md, "A new @Model sorts after every shipped one"); call sites keep the plain name.
public typealias AccountPlanEvent = Z002AccountPlanEvent

public extension Account {

    /// Apply a poll's reported plan and tier to this row, and append an
    /// `AccountPlanEvent` when the pair differs from the newest event (or
    /// there is none yet, which is the first observation).
    ///
    /// A nil input keeps what the row has, as the poller always did: a login
    /// that omits a field has not said it changed. A call that reports
    /// neither (a reading from a switcher's cache) observes no plan at all,
    /// so it records nothing.
    ///
    /// **Two logins, two answers.** Each login carries the plan strings from
    /// when it was made, and the poller reads one account through several
    /// (the keychain login, Desktop's, a switcher's saved copy). After a real
    /// plan change the older ones keep the old strings until they are
    /// replaced, so polls alternate between the two pairs and the row with
    /// them. An event per alternation would be an event per minute. So within
    /// `flapWindow` of a change, going back to the pair it replaced (or to
    /// any pair recorded that recently) is not recorded: the change is
    /// written once, when it is first heard, and a disagreement that lasts
    /// writes about one row a day. A genuine revert inside the window is
    /// recorded when the window ends, still "at or before" its `observedAt`.
    ///
    /// Compared against the *events*, not the row, so the history is
    /// self-consistent: an upgrade from a build without the table records one
    /// first observation per account on its next poll. One indexed fetch of a
    /// few rows per call. Does not save; the caller owns the context.
    func observePlan(
        subscriptionType: String?, rateLimitTier: String?, at observedAt: Date,
        reportedBy: String? = nil, in context: ModelContext
    ) {
        guard subscriptionType != nil || rateLimitTier != nil else { return }
        if let subscriptionType { self.subscriptionType = subscriptionType }
        if let rateLimitTier { self.rateLimitTier = rateLimitTier }
        let plan = self.subscriptionType, tier = self.rateLimitTier

        let account = id
        var newest = FetchDescriptor<AccountPlanEvent>(
            predicate: #Predicate { $0.accountId == account },
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)])
        newest.fetchLimit = 8
        // A schema without the table (a test container that never registered
        // it) throws here; record nothing rather than insert a type the
        // container cannot hold.
        guard let events = try? context.fetch(newest) else { return }
        func same(_ e: AccountPlanEvent) -> Bool { e.subscriptionType == plan && e.rateLimitTier == tier }

        guard let last = events.first else {
            context.insert(AccountPlanEvent(
                accountId: account, observedAt: observedAt, kind: AccountPlanEvent.kindFirst,
                subscriptionType: plan, rateLimitTier: tier, reportedBy: reportedBy))
            return
        }
        if same(last) { return }
        func recent(_ e: AccountPlanEvent) -> Bool {
            observedAt.timeIntervalSince(e.observedAt) < AccountPlanEvent.flapWindow
        }
        // Back to what the newest change replaced, or to any pair recorded
        // lately: an older login still answering, not a new change.
        let revert = last.kind == AccountPlanEvent.kindChange && recent(last)
            && last.previousSubscriptionType == plan && last.previousRateLimitTier == tier
        if revert || events.contains(where: { same($0) && recent($0) }) { return }
        context.insert(AccountPlanEvent(
            accountId: account, observedAt: observedAt, kind: AccountPlanEvent.kindChange,
            subscriptionType: plan, rateLimitTier: tier,
            previousSubscriptionType: last.subscriptionType,
            previousRateLimitTier: last.rateLimitTier,
            reportedBy: reportedBy))
    }
}
