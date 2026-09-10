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

    /// How the machine's accounts are actually used.
    ///
    /// This used to be a `Bool`, and it answered the wrong question. Its first
    /// test was "did more than one account have usage today", which is true for
    /// someone who *switched* accounts twice — the commonest case there is, and
    /// the opposite of parallel. Measured on the maintainer's machine: 37
    /// activation spans, **zero** overlapping and **zero** pinned to a session
    /// root, and the old test still returned "parallel".
    ///
    /// The distinction matters because it decides how much of a cramped surface
    /// to spend. Sequential use has one binding account at a time; concurrent
    /// use has several at once, and showing one of them is showing half.
    public enum Mode: Sendable, Equatable {
        /// One account has ever been seen. No question to answer.
        case single
        /// Several accounts, used one at a time — a switcher, or `/login`.
        case sequential
        /// Several accounts live at the same time.
        case concurrent
    }

    public static func mode(
        context: ModelContext,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Mode {
        let accounts = (try? context.fetch(FetchDescriptor<Account>()))?.count ?? 0
        guard accounts > 1 else { return .single }
        // Two definitive signals, no heuristics.
        //
        // A session-mode profile is `cswap run N` handing a session its own
        // `CLAUDE_CONFIG_DIR`, which exists precisely so two accounts can run
        // at once — its presence *is* the declaration. And overlapping trail
        // spans are two logins observed live at the same instant.
        if usesSessionProfiles(homeDirectory: homeDirectory) { return .concurrent }
        return trail(context: context).hasConcurrentAccounts ? .concurrent : .sequential
    }

    /// Whether any account switcher has handed a session its own config root.
    public static func usesSessionProfiles(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        !ExternalAccountDirectory.discoverProfileRoots(homeDirectory: homeDirectory).isEmpty
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
