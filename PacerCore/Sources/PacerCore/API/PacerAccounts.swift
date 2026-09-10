import Foundation
import SwiftData

/// The accounts Pacer is tracking, as the HTTP API sees them.
///
/// This exists so the API can honour the one rule the rest of the account
/// work is built on: **a scripted consumer says what it means.** The
/// dashboard has a scope switcher and every card follows it, but a `curl` in
/// a cron job cannot see what a human last clicked, so `/v1/usage/*` keeps
/// reporting every account unless the caller passes `?account=`. That
/// parameter needs a list of legal values, and this is it.
///
/// **The rows sum to the global totals.** `unattributed` is included as a row
/// rather than hidden, because turns recorded before the activation trail
/// existed are permanently unattributable (see `AccountActivation`) and
/// dropping them would make a consumer's per-account sum quietly disagree
/// with `/v1/usage/daily`. The same invariant `make verify-data` enforces on
/// the rollups holds across this array.
public struct PacerAccountList: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    /// The account whose login drives the rate-limit windows, menu bar and
    /// alerts. Rate limits are a property of the *login*, not of a view
    /// preference, so they are always this account's — the API reports the id
    /// so a consumer can say which account `/v1/snapshot`'s limits describe.
    public let activeAccountId: String?
    /// How this machine actually uses its accounts: `single`, `sequential`
    /// (a switcher — one login binds at a time), or `concurrent` (two live at
    /// once, so both sets of limits bind and reporting one is reporting half).
    ///
    /// Observed, never configured — a session-mode config root exists, or
    /// activation spans genuinely overlap. A consumer needs it for the same
    /// reason the menu bar does: under `concurrent`, "the active login" is not
    /// the whole answer.
    public let parallelism: String
    public let accounts: [Row]

    public init(schemaVersion: Int, generatedAt: Date, activeAccountId: String?,
                parallelism: String = AccountParallelism.Mode.single.rawValue,
                accounts: [Row]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.activeAccountId = activeAccountId
        self.parallelism = parallelism
        self.accounts = accounts
    }

    public struct Row: Codable, Sendable {
        /// The value to pass as `?account=`. A real account's org id, or
        /// `"unattributed"` for the pre-trail bucket (whose internal key
        /// starts with U+0000 and is not URL-safe).
        public let id: String
        /// What the app displays. May be an email address when Pacer has
        /// observed one; the Prometheus `pacer_account_info` series
        /// deliberately uses a coarser name instead.
        public let label: String
        /// The stored name, which is never an email — an auto-derived
        /// placeholder until someone renames the account. Kept alongside
        /// `label` so a consumer that must not handle an email address (the
        /// Prometheus exporter, for one) has something to fall back to.
        public let displayName: String
        public let organizationName: String?
        /// The plan family Claude Code reports (`pro`, `max`, …). Coarse —
        /// both Max tiers say `max`.
        public let subscriptionType: String?
        /// The rate-limit tier (`default_claude_max_20x`, …), raw. This is the
        /// one that says how big the budget is, which is what makes a
        /// percentage per hour mean anything.
        public let rateLimitTier: String?
        /// Those two rendered readably — "Max 20×" — falling back to whatever
        /// was reported when the shape is unfamiliar.
        public let plan: String?
        public let isActive: Bool
        /// True only for the synthetic pre-trail bucket.
        public let unattributed: Bool
        public let firstSeenAt: Date?
        public let lastSeenAt: Date?
        /// Lifetime totals from the per-account daily rollup. Nil when the
        /// account exists but has no attributed usage yet.
        public let usage: Usage?
        /// The account's most recent window readings. Non-active accounts are
        /// still polled, so this is populated for them too — but it is a
        /// cached *latest* reading, not a history.
        public let limits: Limits?
        /// Config roots currently pinned to this account — the directories a
        /// switcher hands a session through `CLAUDE_CONFIG_DIR` so it can run
        /// beside the default login.
        ///
        /// Present so a caller inside such a session can answer "which account
        /// am I?" It knows its own `CLAUDE_CONFIG_DIR`; only Pacer knows whose
        /// login is in it. Empty for the default login and for any account not
        /// currently pinned anywhere.
        public let configRoots: [String]
        /// Sessions that produced a turn on this account in the last 5 minutes
        /// and the last hour.
        ///
        /// A rate-limit window is account-wide, so these are the other claims
        /// on the same percentage. A burn rate already includes all of them —
        /// this says how many ways it is being split, which is what a decision
        /// to fan out further actually turns on.
        public let activeSessions: Int
        public let recentSessions: Int

        public init(id: String, label: String, displayName: String,
                    organizationName: String?, subscriptionType: String?,
                    rateLimitTier: String? = nil, plan: String? = nil,
                    isActive: Bool, unattributed: Bool,
                    firstSeenAt: Date?, lastSeenAt: Date?,
                    usage: Usage?, limits: Limits?, configRoots: [String] = [],
                    activeSessions: Int = 0, recentSessions: Int = 0) {
            self.id = id
            self.label = label
            self.displayName = displayName
            self.organizationName = organizationName
            self.subscriptionType = subscriptionType
            self.rateLimitTier = rateLimitTier
            self.plan = plan
            self.isActive = isActive
            self.unattributed = unattributed
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
            self.usage = usage
            self.limits = limits
            self.configRoots = configRoots
            self.activeSessions = activeSessions
            self.recentSessions = recentSessions
        }
    }

    public struct Usage: Codable, Sendable {
        public let input: Int
        public let output: Int
        public let cacheRead: Int
        public let cacheCreation5m: Int
        public let cacheCreation1h: Int
        public let costUSD: Double
        public let firstDate: String
        public let lastDate: String
    }

    public struct Limits: Codable, Sendable {
        public let fiveHourPercent: Double?
        public let fiveHourResetsAt: Date?
        public let sevenDayPercent: Double?
        public let sevenDayResetsAt: Date?
        public let overageUSD: Double?
        public let polledAt: Date?
    }

    public func encodedJSON() throws -> String { try pacerAPIEncodedJSON(self) }
}

public extension PacerAccountList.Row {
    /// A name safe to publish as a metric label.
    ///
    /// Not `label`, and not `organizationName` either: Anthropic derives the
    /// org name from the account's email, so both real accounts on this
    /// machine report `"<someone>@<domain>'s Organization"`. A metrics
    /// endpoint is the one surface whose output routinely ends up in a hosted
    /// time-series database, so it gets the coarsest name that still tells two
    /// accounts apart — falling back to the id's tail, which is what
    /// `Account.defaultName` would have produced anyway.
    ///
    /// A name the *user* chose is published verbatim. They typed it knowing
    /// where it would go, and it is the only way to get a readable label.
    var metricsName: String {
        if !Account.isDerivedName(displayName) { return displayName }
        if let organizationName, !organizationName.isEmpty, !organizationName.contains("@") {
            return organizationName
        }
        return "Account \(id.suffix(4))"
    }
}

/// Builds `PacerAccountList` and resolves the `?account=` parameter.
///
/// `nonisolated` with its own short-lived `ModelContext`, like
/// `PacerUsageBuilder` and `PacerSnapshotBuilder`, so the HTTP server reads it
/// from its own background queue.
public enum PacerAccountsBuilder {

    /// URL-safe stand-in for `AccountDailyAggregate.unattributedKey`, whose
    /// U+0000 prefix exists to be un-typeable and therefore cannot be a query
    /// parameter.
    public static let unattributedAlias = "unattributed"

    public enum ResolveError: Error, Sendable, Equatable {
        /// The caller named an account that does not exist. Carries the legal
        /// values so the server can answer with them rather than a bare 400.
        case unknownAccount(known: [String])
    }

    /// Map an `?account=` value onto the key the per-account rollups use.
    ///
    /// Validates against the `Account` table rather than against the rollups,
    /// so a freshly discovered account with no usage yet resolves and returns
    /// an empty result — the honest answer — instead of a 400 that implies it
    /// does not exist.
    public nonisolated static func resolve(_ raw: String) throws -> String {
        let wanted = raw.trimmingCharacters(in: .whitespaces)
        if wanted == unattributedAlias { return AccountDailyAggregate.unattributedKey }
        let known = try knownAccountIds()
        guard known.contains(wanted) else {
            throw ResolveError.unknownAccount(known: known + [unattributedAlias])
        }
        return wanted
    }

    /// Which account a `CLAUDE_CONFIG_DIR` is signed into, or nil when no
    /// activation claims that root.
    ///
    /// The half of the join a client cannot do: a session pinned to its own
    /// profile knows the directory it was handed, and only Pacer knows whose
    /// login is inside it. Without this a script running in a pinned session
    /// paces against whichever account holds the *default* login, which under
    /// concurrent use is a different account's windows entirely.
    ///
    /// An unknown root returns nil rather than throwing: a session pinned to a
    /// directory Pacer has never seen a login in is a real state (a brand new
    /// profile), and the honest answer is "cannot say", which the caller turns
    /// back into the active login.
    public nonisolated static func resolve(configDir raw: String) throws -> String? {
        try resolve(configDir: raw, container: PacerStore.sharedModelContainer())
    }

    nonisolated static func resolve(configDir raw: String,
                                    container: ModelContainer) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let context = ModelContext(container)
        let roots = AccountParallelism.trail(context: context).openPinnedRoots
        // `CLAUDE_CONFIG_DIR` is comma-separated, and a session that lists
        // several is reading all of them — the first one an activation claims
        // is the one whose login it is writing under.
        for candidate in trimmed.split(separator: ",") {
            let path = URL(fileURLWithPath: String(candidate).trimmingCharacters(in: .whitespaces))
                .standardizedFileURL.path
            if let account = roots[path] { return account }
        }
        return nil
    }

    /// Every id `?account=` accepts, excluding the unattributed alias.
    public nonisolated static func knownAccountIds() throws -> [String] {
        let context = ModelContext(try PacerStore.sharedModelContainer())
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        return accounts.map(\.id).sorted()
    }

    public nonisolated static func list(now: Date = Date()) throws -> PacerAccountList {
        try list(container: PacerStore.sharedModelContainer(), now: now)
    }

    nonisolated static func list(container: ModelContainer,
                                 now: Date) throws -> PacerAccountList {
        let context = ModelContext(container)
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let rollups = (try? context.fetch(FetchDescriptor<AccountDailyAggregate>())) ?? []
        let pinnedRoots = AccountParallelism.trail(context: context).openPinnedRoots
        let rootsByAccount = Dictionary(grouping: pinnedRoots.keys) { pinnedRoots[$0] ?? "" }

        // How many sessions are drawing on each account right now. One bounded
        // fetch for every account rather than one per account.
        let sessionCutoff = now.addingTimeInterval(-LiveSessionActivity.recentThreshold)
        let liveSessions = (try? context.fetch(FetchDescriptor<AccountSessionInfo>(
            predicate: #Predicate { $0.lastSeenAt >= sessionCutoff }))) ?? []
        var active: [String: Int] = [:]
        var recent: [String: Int] = [:]
        for session in liveSessions {
            recent[session.accountId, default: 0] += 1
            if LiveSessionActivity.from(lastSeen: session.lastSeenAt, now: now) == .active {
                active[session.accountId, default: 0] += 1
            }
        }

        var usage: [String: PacerAccountList.Usage] = [:]
        var acc: [String: Accumulator] = [:]
        for row in rollups {
            var a = acc[row.accountId] ?? Accumulator()
            a.add(row)
            acc[row.accountId] = a
        }
        for (key, a) in acc { usage[key] = a.usage }

        var rows: [PacerAccountList.Row] = accounts
            .sorted { $0.isActive != $1.isActive ? $0.isActive : $0.id < $1.id }
            .map { account in
                PacerAccountList.Row(
                    id: account.id,
                    label: account.label,
                    displayName: account.displayName,
                    organizationName: account.organizationName,
                    subscriptionType: account.subscriptionType,
                    rateLimitTier: account.rateLimitTier,
                    plan: account.planLabel,
                    isActive: account.isActive,
                    unattributed: false,
                    firstSeenAt: account.firstSeenAt,
                    lastSeenAt: account.lastSeenAt,
                    usage: usage[account.id],
                    limits: PacerAccountList.Limits(
                        fiveHourPercent: account.latestFiveHourPct,
                        fiveHourResetsAt: account.latestFiveHourResetsAt,
                        sevenDayPercent: account.latestSevenDayPct,
                        sevenDayResetsAt: account.latestSevenDayResetsAt,
                        overageUSD: account.latestExtraUsageCents.map { Double($0) / 100 },
                        polledAt: account.latestPolledAt),
                    configRoots: (rootsByAccount[account.id] ?? []).sorted(),
                    activeSessions: active[account.id] ?? 0,
                    recentSessions: recent[account.id] ?? 0)
            }

        // Only when there is something in it: an install that has never seen
        // an un-attributed turn should not be told about the concept.
        if let orphans = usage[AccountDailyAggregate.unattributedKey] {
            rows.append(PacerAccountList.Row(
                id: unattributedAlias,
                label: "Unattributed",
                displayName: "Unattributed",
                organizationName: nil,
                subscriptionType: nil,
                isActive: false,
                unattributed: true,
                firstSeenAt: nil,
                lastSeenAt: nil,
                usage: orphans,
                limits: nil))
        }

        return PacerAccountList(
            schemaVersion: 1,
            generatedAt: now,
            activeAccountId: accounts.first(where: \.isActive)?.id,
            parallelism: AccountParallelism.mode(context: context).rawValue,
            accounts: rows)
    }

    private struct Accumulator {
        var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0
        var c5m: Int64 = 0, c1h: Int64 = 0, cost: Double = 0
        var firstDate = "", lastDate = ""

        mutating func add(_ row: AccountDailyAggregate) {
            input += row.inputTokens
            output += row.outputTokens
            cacheRead += row.cacheReadTokens
            c5m += row.cacheCreation5mTokens
            c1h += row.cacheCreation1hTokens
            cost += row.totalCostUSD
            if firstDate.isEmpty || row.date < firstDate { firstDate = row.date }
            if lastDate.isEmpty || row.date > lastDate { lastDate = row.date }
        }

        var usage: PacerAccountList.Usage {
            PacerAccountList.Usage(
                input: Int(input), output: Int(output), cacheRead: Int(cacheRead),
                cacheCreation5m: Int(c5m), cacheCreation1h: Int(c1h),
                costUSD: cost, firstDate: firstDate, lastDate: lastDate)
        }
    }
}
