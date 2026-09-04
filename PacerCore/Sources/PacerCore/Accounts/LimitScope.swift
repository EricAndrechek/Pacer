import Foundation
import SwiftData

/// Reads of the rate-limit tables, scoped to one account.
///
/// The live sample tables used to hold exactly one account's rows, so every
/// read site could ignore accounts entirely. They now hold every account's,
/// and **a read that forgets to scope is silently wrong** — it returns two
/// logins' windows interleaved and shows whichever sorted first. There is no
/// crash and no empty state to notice; the number is just someone else's.
///
/// So the scoping lives here rather than being spelled out at each of the
/// fifty-odd call sites. A descriptor from this type is scoped by
/// construction, and the three predicate builders cover the sites that need
/// to compose something of their own.
///
/// **Which account?** `UsageScope.limitAccountId` — the picked scope, else the
/// active login. Never "all", because two 5-hour windows do not sum into a
/// third one. A nil account here means "no scope known yet" (a fresh install
/// before the first poll), and reads everything, which is correct precisely
/// because there is only one account's data to read.
public enum LimitScope {

    // MARK: - Predicates

    public static func rateLimitPredicate(account: String?, since: Date? = nil) -> Predicate<RateLimitSample> {
        switch (account, since) {
        case let (a?, s?): return #Predicate { $0.accountId == a && $0.sampledAt >= s }
        case let (a?, nil): return #Predicate { $0.accountId == a }
        case let (nil, s?): return #Predicate { $0.sampledAt >= s }
        case (nil, nil): return #Predicate { _ in true }
        }
    }

    public static func usageLimitPredicate(account: String?, since: Date? = nil) -> Predicate<UsageLimitSample> {
        switch (account, since) {
        case let (a?, s?): return #Predicate { $0.accountId == a && $0.sampledAt >= s }
        case let (a?, nil): return #Predicate { $0.accountId == a }
        case let (nil, s?): return #Predicate { $0.sampledAt >= s }
        case (nil, nil): return #Predicate { _ in true }
        }
    }

    public static func extraUsagePredicate(account: String?, since: Date? = nil) -> Predicate<ExtraUsageSample> {
        switch (account, since) {
        case let (a?, s?): return #Predicate { $0.accountId == a && $0.sampledAt >= s }
        case let (a?, nil): return #Predicate { $0.accountId == a }
        case let (nil, s?): return #Predicate { $0.sampledAt >= s }
        case (nil, nil): return #Predicate { _ in true }
        }
    }

    // MARK: - Descriptors
    //
    // Newest-first, which is what every caller wants: the read path is either
    // "the latest reading" or "the last N hours of them".

    public static func rateLimits(account: String?, since: Date? = nil,
                                  limit: Int? = nil) -> FetchDescriptor<RateLimitSample> {
        var d = FetchDescriptor<RateLimitSample>(
            predicate: rateLimitPredicate(account: account, since: since),
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        d.fetchLimit = limit
        return d
    }

    public static func usageLimits(account: String?, since: Date? = nil,
                                   limit: Int? = nil) -> FetchDescriptor<UsageLimitSample> {
        var d = FetchDescriptor<UsageLimitSample>(
            predicate: usageLimitPredicate(account: account, since: since),
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        d.fetchLimit = limit
        return d
    }

    public static func extraUsage(account: String?, since: Date? = nil,
                                  limit: Int? = nil) -> FetchDescriptor<ExtraUsageSample> {
        var d = FetchDescriptor<ExtraUsageSample>(
            predicate: extraUsagePredicate(account: account, since: since),
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        d.fetchLimit = limit
        return d
    }
}
