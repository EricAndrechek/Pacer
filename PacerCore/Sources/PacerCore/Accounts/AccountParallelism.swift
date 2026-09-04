import Foundation
import SwiftData

/// Whether this machine runs its accounts *in parallel* or one at a time.
///
/// It decides what "all accounts" can mean for a rate limit. Costs add up
/// across accounts; a 5-hour window does not — two accounts at 60% are not
/// 120% of anything, they are two caps on two clocks. So the global view has
/// only two honest options, and which one is right depends on how the machine
/// is actually used:
///
/// - **One at a time** (log out, log in; or a switcher that swaps the active
///   login): only one account's limits constrain you at any moment, so showing
///   that account's windows *is* the global answer.
/// - **In parallel** (two logins live at once, or simply both used today):
///   both sets of limits are binding simultaneously, and showing one of them
///   hides the other.
///
/// Observed rather than configured, for the same reason `AccountTrail` is: a
/// person who starts running parallel sessions gets the richer view without
/// setting anything, and someone who goes back to switching gets the calmer one
/// back.
public enum AccountParallelism {

    /// True when more than one account is in play *right now*, by either test.
    ///
    /// The trail's `hasConcurrentAccounts` catches genuine overlap — two logins
    /// live at the same instant. The same-day test catches the case the trail
    /// cannot see: two accounts used in sequence within one day, whose windows
    /// are nonetheless both open and both constraining. Either is enough.
    public static func isParallel(
        context: ModelContext, now: Date = Date(), calendar: Calendar = .current
    ) -> Bool {
        if accountsActiveToday(context: context, now: now) > 1 { return true }
        return trail(context: context).hasConcurrentAccounts
    }

    /// How many distinct accounts have usage on today's local date.
    public static func accountsActiveToday(context: ModelContext, now: Date = Date()) -> Int {
        let today = TokenSample.formatDate(now)
        let rows = (try? context.fetch(FetchDescriptor<AccountDailyAggregate>(
            predicate: #Predicate { $0.date == today }))) ?? []
        return Set(rows.filter { $0.totalTokens > 0 }.map(\.accountId)).count
    }

    /// The activation trail. A small table — one row per switch — so this is a
    /// cheap read even unbounded.
    public static func trail(context: ModelContext) -> AccountTrail {
        let rows = (try? context.fetch(FetchDescriptor<AccountActivation>())) ?? []
        return AccountTrail(spans: rows.map {
            AccountTrail.Span(accountId: $0.accountId, startedAt: $0.startedAt,
                              endedAt: $0.endedAt, rootPath: $0.rootPath)
        })
    }
}
