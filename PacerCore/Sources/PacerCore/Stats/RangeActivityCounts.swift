import Foundation
import SwiftData

/// How many projects and how many sessions had activity in a range, for
/// History's range summary. Read from the rollups only — `ProjectDailyAggregate`
/// and `SessionInfo`, or their per-account twins for one account — never from
/// `TokenSample`.
///
/// `accountId` follows the cards' scope switch: `nil` reads the all-accounts
/// tables, an id reads that account's rows of the per-account ones.
///
/// What each costs, which decides where a caller runs it:
/// - `sessions` and `projectDays` are SQL COUNTs: nothing is materialised, so
///   they are cheap enough for every scan tick on the main actor.
/// - `projects` has to read the rows' paths to tell them apart (SwiftData has
///   no COUNT DISTINCT, and it faults whole objects however few properties a
///   fetch asks for). Run it off the main actor, and only when `projectDays`
///   moved or project attribution changed: a project new to the range always
///   brings a project-day row with it.
public enum RangeActivityCounts {

    /// The instant a range's first day starts, or `nil` for all time.
    ///
    /// The daily rollups are filtered on `date >= formatDate(since)`, which
    /// takes the whole of `since`'s day; sessions are counted from that
    /// day's start so they cover the same days. `TimeRange.since` is already
    /// a day's start (#342); this keeps any other `since` honest too.
    public static func dayStart(_ since: Date?, calendar: Calendar = .current) -> Date? {
        since.map { calendar.startOfDay(for: $0) }
    }

    /// Sessions with any activity on or after `since`'s day — the sessions
    /// whose last turn falls in the range, which is every session that had a
    /// turn in it.
    public static func sessions(_ context: ModelContext, since: Date?, accountId: String?) -> Int {
        let start = dayStart(since)
        if let accountId {
            let descriptor: FetchDescriptor<AccountSessionInfo>
            if let start {
                descriptor = FetchDescriptor(predicate: #Predicate<AccountSessionInfo> {
                    $0.accountId == accountId && $0.lastSeenAt >= start
                })
            } else {
                descriptor = FetchDescriptor(predicate: #Predicate<AccountSessionInfo> {
                    $0.accountId == accountId
                })
            }
            return (try? context.fetchCount(descriptor)) ?? 0
        }
        let descriptor: FetchDescriptor<SessionInfo>
        if let start {
            descriptor = FetchDescriptor(predicate: #Predicate<SessionInfo> { $0.lastSeenAt >= start })
        } else {
            descriptor = FetchDescriptor()
        }
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Project-day rows in the range: the cheap signal that `projects` may
    /// have changed.
    public static func projectDays(_ context: ModelContext, since: Date?, accountId: String?) -> Int {
        if let accountId {
            return (try? context.fetchCount(accountProjectDays(since: since, accountId: accountId))) ?? 0
        }
        return (try? context.fetchCount(projectDays(since: since))) ?? 0
    }

    /// Distinct projects with a project-day row in the range. `(unknown)` —
    /// turns with no working directory — counts as one, as it is one row of
    /// the Projects tab, so the two pages agree for the same range.
    public static func projects(_ context: ModelContext, since: Date?, accountId: String?) -> Int {
        var paths = Set<String>()
        if let accountId {
            var descriptor = accountProjectDays(since: since, accountId: accountId)
            descriptor.propertiesToFetch = [\.projectPath]
            for row in (try? context.fetch(descriptor)) ?? [] { paths.insert(row.projectPath) }
        } else {
            var descriptor = projectDays(since: since)
            descriptor.propertiesToFetch = [\.projectPath]
            for row in (try? context.fetch(descriptor)) ?? [] { paths.insert(row.projectPath) }
        }
        return paths.count
    }

    private static func projectDays(since: Date?) -> FetchDescriptor<ProjectDailyAggregate> {
        guard let since else { return FetchDescriptor() }
        let cutoff = TokenSample.formatDate(since)
        return FetchDescriptor(predicate: #Predicate<ProjectDailyAggregate> { $0.date >= cutoff })
    }

    private static func accountProjectDays(
        since: Date?, accountId: String
    ) -> FetchDescriptor<AccountProjectDailyAggregate> {
        guard let since else {
            return FetchDescriptor(predicate: #Predicate<AccountProjectDailyAggregate> {
                $0.accountId == accountId
            })
        }
        let cutoff = TokenSample.formatDate(since)
        return FetchDescriptor(predicate: #Predicate<AccountProjectDailyAggregate> {
            $0.date >= cutoff && $0.accountId == accountId
        })
    }
}
