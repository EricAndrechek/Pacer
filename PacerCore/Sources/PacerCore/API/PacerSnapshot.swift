import Foundation
import SwiftData

/// The canonical, versioned read model Pacer exposes to the outside world.
///
/// One builder feeds every external surface — the Shortcuts/App Intents JSON
/// intent and the local HTTP server (`/v1/snapshot`, `/metrics`, SSE) — so
/// they all report numbers that agree with each other and with the dashboard.
/// Reads the shared App-Group store directly, so it answers correctly whether
/// or not the app's UI is running, exactly like the widgets.
///
/// Dates encode as ISO-8601 strings; durations are integer seconds-from-now.
/// Bump `schemaVersion` on a breaking change; additive fields don't require a
/// bump.
///
/// **Deliberately does not follow the app's account scope.**
///
/// The scope is a *display* preference for one window. A scripted consumer —
/// a pacing script, a status bar, a CI gate — wants to say what it means, and
/// would otherwise get different numbers depending on what a human last
/// clicked in an app it cannot see. So the unscoped payload reports every
/// account, always, and per-account figures live behind an explicit
/// `?account=` — which the builder now takes.
///
/// **What `?account=` scopes: everything.** Limits, cost, tokens, pace,
/// session and overage all become that account's, and `account` echoes the id
/// back so a saved response says which question it answered. A payload where
/// half the fields obeyed the parameter and half did not would be the kind of
/// thing a consumer reads wrong once and never notices.
public struct PacerSnapshotPayload: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    /// The `?account=` this was built for, echoed back; absent when the
    /// payload covers every account (with limits, as ever, the active
    /// login's — see `Limits`).
    public let account: String?
    public let limits: Limits
    public let cost: Cost
    public let tokens: Tokens
    public let pace: Pace
    public let session: Session?
    public let overageUSD: Double
    public let dataSource: DataSource

    public init(schemaVersion: Int, generatedAt: Date, account: String? = nil,
                limits: Limits, cost: Cost, tokens: Tokens, pace: Pace,
                session: Session?, overageUSD: Double, dataSource: DataSource) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.account = account
        self.limits = limits
        self.cost = cost
        self.tokens = tokens
        self.pace = pace
        self.session = session
        self.overageUSD = overageUSD
        self.dataSource = dataSource
    }

    /// One login's rate-limit windows.
    ///
    /// **Every window the server reports, not two.** `fiveHour` and `sevenDay`
    /// are the account-wide blocks the dashboard's hero cards own; `scoped`
    /// carries the per-model / per-surface caps from the same poll — a "Fable ·
    /// weekly" window and anything else Anthropic starts reporting. The engine
    /// has driven N dynamic windows since v0.4.0 and the dashboard renders them
    /// as first-class pace columns; for a while this payload was the one
    /// surface that still knew exactly two.
    ///
    /// Nothing here is enumerated: a scoped window that appears in a poll shows
    /// up with zero code change, and one that vanishes drops out of the next.
    public struct Limits: Codable, Sendable {
        /// The account-wide 5-hour block, `nil` before the first sample lands.
        public let fiveHour: Window?
        /// The account-wide 7-day block, `nil` before the first sample lands.
        public let sevenDay: Window?
        /// The latest poll's per-model / per-surface windows, ordered by
        /// `identity` so a consumer diffing two responses sees a stable list.
        /// Empty when the account reports none.
        ///
        /// Account-wide `session` / `weekly_all` rows are *not* here: they
        /// duplicate `fiveHour` / `sevenDay`, and reporting a window twice is
        /// how a consumer ends up double-counting it.
        public let scoped: [Window]

        public init(fiveHour: Window?, sevenDay: Window?, scoped: [Window] = []) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
            self.scoped = scoped
        }

        public struct Window: Codable, Sendable {
            /// Stable key for this window: `"five_hour"` / `"seven_day"` for
            /// the fixed blocks, or the `limits[]` composite identity
            /// (`kind|model|surface`) for a scoped one. Threads a window's
            /// history across polls, and is the `window` label on the
            /// Prometheus series.
            public let identity: String
            /// Human label — "5-hour", "7-day", "Fable".
            public let label: String
            /// The server's bucketing word: `session` / `weekly` for the fixed
            /// blocks, raw and unvalidated for a scoped window (an OPEN set —
            /// a new word arrives verbatim rather than being dropped).
            public let group: String
            public let usedPercent: Double
            public let resetsAt: Date?
            public let resetsInSeconds: Int?
            public let projectedEndPercent: Double?
            public let projectedEndLowPercent: Double?
            public let projectedEndHighPercent: Double?
            public let willHitLimit: Bool
            public let limitEtaAt: Date?
            public let limitEtaInSeconds: Int?
            /// Whether this was the binding limit in its group at sample time.
            /// Scoped windows only — the fixed blocks are read from a source
            /// that carries no such flag, so `nil` there means "not reported",
            /// not "false".
            public let isActive: Bool?
            /// Recent burn in percentage points per hour, from the engine's
            /// descriptive slope over a per-window lookback (90 min for a
            /// session-scale window, 24 h for a weekly one). `nil` when no
            /// fresh projection backs this window.
            ///
            /// This is what turns headroom into time. `usedPercent` says where
            /// you are and `limitEtaInSeconds` says when the model thinks you
            /// arrive; this says how fast you are going right now, which is the
            /// one a consumer can sanity-check against its own behaviour.
            public let burnPercentPerHour: Double?
            /// The server's raw severity word for a scoped window (also an
            /// OPEN set; `nil` for the fixed blocks). Kept verbatim so a
            /// consumer can act on an urgency hint before the percentage is
            /// high, and so a severity Pacer has never seen is still passed on.
            public let severity: String?

            public init(identity: String, label: String, group: String,
                        usedPercent: Double, resetsAt: Date?, resetsInSeconds: Int?,
                        projectedEndPercent: Double? = nil,
                        projectedEndLowPercent: Double? = nil,
                        projectedEndHighPercent: Double? = nil,
                        willHitLimit: Bool = false,
                        limitEtaAt: Date? = nil, limitEtaInSeconds: Int? = nil,
                        burnPercentPerHour: Double? = nil,
                        isActive: Bool? = nil, severity: String? = nil) {
                self.identity = identity
                self.label = label
                self.group = group
                self.usedPercent = usedPercent
                self.resetsAt = resetsAt
                self.resetsInSeconds = resetsInSeconds
                self.projectedEndPercent = projectedEndPercent
                self.projectedEndLowPercent = projectedEndLowPercent
                self.projectedEndHighPercent = projectedEndHighPercent
                self.willHitLimit = willHitLimit
                self.limitEtaAt = limitEtaAt
                self.limitEtaInSeconds = limitEtaInSeconds
                self.burnPercentPerHour = burnPercentPerHour
                self.isActive = isActive
                self.severity = severity
            }
        }

        /// Every window in one list — the fixed blocks that exist, then the
        /// scoped ones. What a consumer that wants "all my limits" iterates,
        /// and what the metric renderer walks.
        public var all: [Window] {
            [fiveHour, sevenDay].compactMap { $0 } + scoped
        }
    }

    public struct Cost: Codable, Sendable {
        public let todayUSD: Double
        public let weekUSD: Double
        public let monthUSD: Double
        public let allTimeUSD: Double
        public let projectedTodayUSD: Double?
        public let projectedTodayLowUSD: Double?
        public let projectedTodayHighUSD: Double?
        public let projectedMonthUSD: Double?
        public let projectedMonthLowUSD: Double?
        public let projectedMonthHighUSD: Double?

        public init(todayUSD: Double, weekUSD: Double, monthUSD: Double, allTimeUSD: Double,
                    projectedTodayUSD: Double?, projectedTodayLowUSD: Double?,
                    projectedTodayHighUSD: Double?, projectedMonthUSD: Double?,
                    projectedMonthLowUSD: Double?, projectedMonthHighUSD: Double?) {
            self.todayUSD = todayUSD
            self.weekUSD = weekUSD
            self.monthUSD = monthUSD
            self.allTimeUSD = allTimeUSD
            self.projectedTodayUSD = projectedTodayUSD
            self.projectedTodayLowUSD = projectedTodayLowUSD
            self.projectedTodayHighUSD = projectedTodayHighUSD
            self.projectedMonthUSD = projectedMonthUSD
            self.projectedMonthLowUSD = projectedMonthLowUSD
            self.projectedMonthHighUSD = projectedMonthHighUSD
        }
    }

    public struct Tokens: Codable, Sendable {
        public let todayInput: Int
        public let todayOutput: Int
        public let todayCacheRead: Int
        /// Input + output (cache excluded) — matches the menu bar's "today tokens".
        public let todayTotal: Int

        public init(todayInput: Int, todayOutput: Int, todayCacheRead: Int, todayTotal: Int) {
            self.todayInput = todayInput
            self.todayOutput = todayOutput
            self.todayCacheRead = todayCacheRead
            self.todayTotal = todayTotal
        }
    }

    public struct Pace: Codable, Sendable {
        /// 0…1 — today's projected spend as a percentile of your daily norm.
        public let percentile: Double?
        /// "running hot" / "about normal" / "quieter than usual".
        public let status: String?

        public init(percentile: Double?, status: String?) {
            self.percentile = percentile
            self.status = status
        }
    }

    public struct Session: Codable, Sendable {
        public let project: String
        public let projectPath: String
        public let costUSD: Double
        public let tokens: Int
        public let lastActiveAt: Date

        public init(project: String, projectPath: String, costUSD: Double,
                    tokens: Int, lastActiveAt: Date) {
            self.project = project
            self.projectPath = projectPath
            self.costUSD = costUSD
            self.tokens = tokens
            self.lastActiveAt = lastActiveAt
        }
    }

    public struct DataSource: Codable, Sendable {
        public let source: String?
        public let lastSampleAt: Date?
        public let ageSeconds: Int?
        /// True when a fresh (≤30 min) engine projection backs the forecast fields.
        public let forecastFresh: Bool

        public init(source: String?, lastSampleAt: Date?, ageSeconds: Int?, forecastFresh: Bool) {
            self.source = source
            self.lastSampleAt = lastSampleAt
            self.ageSeconds = ageSeconds
            self.forecastFresh = forecastFresh
        }
    }

    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Builder (single source of truth for every external surface)

public enum PacerSnapshotBuilder {

    private static let fiveHourKey = RateLimitWindowName.fiveHour
    private static let sevenDayKey = RateLimitWindowName.sevenDay

    /// The server's `group` word for the two fixed blocks. They arrive through
    /// the top-level `five_hour` / `seven_day` fields rather than `limits[]`,
    /// so nothing carries the group down with them — but they *are* the
    /// account-wide `session` and `weekly` buckets, and saying so is what lets
    /// a consumer treat `limits.all` as one homogeneous list.
    private static let fiveHourGroup = "session"
    private static let sevenDayGroup = "weekly"

    /// Newest-first bound for the scoped `limits[]` read. One poll writes a
    /// handful of scoped rows; 64 covers far more scoped windows than an
    /// account realistically has, and keeps this off the append-only table's
    /// full history. Same bound the menu bar uses.
    private static let scopedFetchLimit = 64

    /// Read the shared store + the exported engine outlook and assemble the
    /// full snapshot. `nonisolated` and self-contained (creates its own
    /// short-lived `ModelContext`), so it can run on the App Intents main
    /// actor *or* the HTTP server's background queue without a hop.
    ///
    /// `account` is a **resolved rollup key** — pass `PacerAccountsBuilder`'s
    /// output, not a raw query parameter. Nil is the default and means what it
    /// always did: cost and tokens across every account, limits for the active
    /// login.
    public nonisolated static func build(account: String? = nil,
                                         now: Date = Date()) throws -> PacerSnapshotPayload {
        try build(container: PacerStore.sharedModelContainer(), account: account,
                  activeAccountId: UsageScope.storedActiveAccountId, now: now)
    }

    /// Test seam: the same build against a caller-supplied container, with the
    /// active login named rather than read out of App Group defaults — which
    /// are process-wide, and so cannot be set by one test without reaching into
    /// every other one running beside it.
    nonisolated static func build(container: ModelContainer, account: String?,
                                  activeAccountId: String?,
                                  now: Date) throws -> PacerSnapshotPayload {
        let context = ModelContext(container)
        let calendar = Calendar.current

        // --- Rate-limit windows (fixed + scoped, one account's) ---
        //
        // Unscoped, this is the **active** login's, never the app's picked
        // scope: a scripted consumer must not get different numbers because a
        // human clicked something in an app it cannot see. `/v1/accounts`
        // reports `activeAccountId` so the caller knows whose limits these are.
        let limitAccount = account ?? activeAccountId
        let limits = limits(
            context: context, limitAccount: limitAccount,
            engineScope: engineScope(limitAccount: limitAccount, activeAccountId: activeAccountId),
            now: now)
        let freshestSample = (try? context.fetch(
            LimitScope.rateLimits(account: limitAccount, limit: 1)))?.first

        // --- Engine outlook export (cost / pace), fresh only ---
        //
        // A *different* scope from the limits above, and deliberately so. The
        // all-accounts engine has no rate-limit meaning — two 5-hour windows do
        // not sum — so it fits the active login's windows, which is exactly
        // what an unscoped `limits` block wants. Cost is the opposite: the
        // all-accounts projection blends both logins' spend, so a per-account
        // request must not borrow it. When that account's engine scope has gone
        // cold (nothing has asked for it in 15 minutes) the projections are
        // simply absent and `forecastFresh` is false — an honest gap beats a
        // number describing someone else's habits.
        let costScope: EngineScope = account.map(EngineScope.account) ?? .allAccounts
        let costSnapshot = engineSnapshot(context: context, scope: costScope)

        // --- Daily aggregates (cost + tokens, all spans from one fetch) ---
        let daily = PacerUsageBuilder.dailyRows(context, account: account)
        let todayKey = TokenSample.formatDate(now)
        let weekKey = TokenSample.formatDate(calendar.date(byAdding: .day, value: -6, to: now) ?? now)
        let monthKey: String = {
            let comps = calendar.dateComponents([.year, .month], from: now)
            return calendar.date(from: comps).map { TokenSample.formatDate($0) } ?? todayKey
        }()
        let todayRows = daily.filter { $0.date == todayKey }

        let cost = PacerSnapshotPayload.Cost(
            todayUSD: todayRows.reduce(0) { $0 + $1.totalCostUSD },
            weekUSD: daily.filter { $0.date >= weekKey }.reduce(0) { $0 + $1.totalCostUSD },
            monthUSD: daily.filter { $0.date >= monthKey }.reduce(0) { $0 + $1.totalCostUSD },
            allTimeUSD: daily.reduce(0) { $0 + $1.totalCostUSD },
            projectedTodayUSD: costSnapshot?.cost?.projectedTodayUSD,
            projectedTodayLowUSD: costSnapshot?.cost?.projectedTodayLoUSD,
            projectedTodayHighUSD: costSnapshot?.cost?.projectedTodayHiUSD,
            projectedMonthUSD: costSnapshot?.cost?.projectedMonthUSD,
            projectedMonthLowUSD: costSnapshot?.cost?.projectedMonthLoUSD,
            projectedMonthHighUSD: costSnapshot?.cost?.projectedMonthHiUSD)

        let todayInput = todayRows.reduce(Int64(0)) { $0 + $1.inputTokens }
        let todayOutput = todayRows.reduce(Int64(0)) { $0 + $1.outputTokens }
        let todayCacheRead = todayRows.reduce(Int64(0)) { $0 + $1.cacheReadTokens }
        let tokens = PacerSnapshotPayload.Tokens(
            todayInput: Int(todayInput),
            todayOutput: Int(todayOutput),
            todayCacheRead: Int(todayCacheRead),
            todayTotal: Int(todayInput + todayOutput))

        let pace = PacerSnapshotPayload.Pace(
            percentile: costSnapshot?.cost?.pacePercentile,
            status: costSnapshot?.cost?.paceNote)

        // --- Running session (most recent by last activity) ---
        let session = latestSession(context: context, account: account).map {
            PacerSnapshotPayload.Session(
                project: URL(fileURLWithPath: $0.projectPath).lastPathComponent,
                projectPath: $0.projectPath,
                costUSD: $0.cumulativeCostUSD,
                // Input + output, cache excluded — `SessionRow.totalTokens`
                // counts cache too, and swapping to it here would quietly
                // change a number that has always matched `tokens.todayTotal`.
                tokens: Int($0.cumulativeInputTokens + $0.cumulativeOutputTokens),
                lastActiveAt: $0.lastSeenAt)
        }

        // --- Extra (overage) usage ---
        let overageUSD = (try? context.fetch(
            LimitScope.extraUsage(account: limitAccount, limit: 1)))?.first?.amountUSD ?? 0

        let dataSource = PacerSnapshotPayload.DataSource(
            source: freshestSample?.source,
            lastSampleAt: freshestSample?.sampledAt,
            ageSeconds: freshestSample.map { max(0, Int(now.timeIntervalSince($0.sampledAt))) },
            forecastFresh: costSnapshot != nil)

        return PacerSnapshotPayload(
            schemaVersion: 1,
            generatedAt: now,
            account: account.map(PacerUsageBuilder.publicKey),
            limits: limits,
            cost: cost,
            tokens: tokens,
            pace: pace,
            session: session,
            overageUSD: overageUSD,
            dataSource: dataSource)
    }

    /// One account's full window set — the fixed 5h/7d blocks plus every
    /// scoped per-model window in the latest poll.
    ///
    /// Split out of `build` because `/metrics` needs exactly this for each
    /// account and nothing else: the full snapshot's daily-aggregate scan per
    /// account per scrape would be real work for numbers the metric renderer
    /// already has.
    public nonisolated static func limits(account: String?,
                                          now: Date = Date()) throws -> PacerSnapshotPayload.Limits {
        let context = ModelContext(try PacerStore.sharedModelContainer())
        return limits(context: context, limitAccount: account,
                      engineScope: engineScope(limitAccount: account,
                                               activeAccountId: UsageScope.storedActiveAccountId),
                      now: now)
    }

    /// Which engine scope's outlook describes `limitAccount`'s windows.
    ///
    /// The all-accounts engine fits the **active login's** rate-limit windows
    /// (see `EngineScope`), so for that account it is both the right answer and
    /// the only one that is reliably warm. Any other account gets its own
    /// scope, which may be cold — then there is no projection, which is the
    /// honest result.
    nonisolated static func engineScope(limitAccount: String?,
                                        activeAccountId: String?) -> EngineScope {
        guard let limitAccount, limitAccount != activeAccountId else { return .allAccounts }
        return .account(limitAccount)
    }

    nonisolated static func limits(context: ModelContext, limitAccount: String?,
                                   engineScope scope: EngineScope,
                                   now: Date) -> PacerSnapshotPayload.Limits {
        let rlRows = (try? context.fetch(
            LimitScope.rateLimits(account: limitAccount, limit: 16))) ?? []
        let outlook = engineSnapshot(context: context, scope: scope)

        let scopedRows = ((try? context.fetch(LimitScope.modelScopedLimits(
            account: limitAccount, limit: scopedFetchLimit))) ?? [])
            .map(\.scopedWindowRow)
            .latestBatch()
            .sorted { $0.identity < $1.identity }
        let scopedOutlooks = Dictionary(
            (outlook?.scoped ?? []).map { ($0.identity, $0.outlook) },
            uniquingKeysWith: { first, _ in first })

        return PacerSnapshotPayload.Limits(
            fiveHour: window(rlRows.first { $0.window == fiveHourKey },
                             identity: fiveHourKey,
                             label: WindowSpec.fixed(.fiveHour).displayName,
                             group: fiveHourGroup,
                             outlook: outlook?.fiveHour, now: now),
            sevenDay: window(rlRows.first { $0.window == sevenDayKey },
                             identity: sevenDayKey,
                             label: WindowSpec.fixed(.sevenDay).displayName,
                             group: sevenDayGroup,
                             outlook: outlook?.sevenDay, now: now),
            scoped: scopedRows.map { row in
                window(identity: row.identity, label: row.label, group: row.group,
                       usedPercent: row.percent, resetsAt: row.resetsAt,
                       isActive: row.isActive, severity: row.severity,
                       outlook: scopedOutlooks[row.identity], now: now)
            })
    }

    /// One fixed window's live usage from the freshest sample, or nil when no
    /// sample has landed yet.
    private static func window(
        _ sample: RateLimitSample?,
        identity: String, label: String, group: String,
        outlook: EngineSnapshot.WindowOutlook?,
        now: Date
    ) -> PacerSnapshotPayload.Limits.Window? {
        guard let sample else { return nil }
        return window(identity: identity, label: label, group: group,
                      usedPercent: sample.usedPercentage, resetsAt: sample.resetsAt,
                      outlook: outlook, now: now)
    }

    /// Assemble one window's live usage plus the engine's projection — but only
    /// attach the projection when the snapshot belongs to the *same* cycle as
    /// the sample (reset within ±2 min). A projection from a previous cycle
    /// would be nonsense, exactly as the pace-chart widget guards.
    private static func window(
        identity: String, label: String, group: String,
        usedPercent: Double, resetsAt: Date?,
        isActive: Bool? = nil, severity: String? = nil,
        outlook: EngineSnapshot.WindowOutlook?,
        now: Date
    ) -> PacerSnapshotPayload.Limits.Window {
        let resetsInSeconds = resetsAt.map { max(0, Int($0.timeIntervalSince(now))) }

        var endPct: Double?
        var endLo: Double?
        var endHi: Double?
        var crossingAt: Date?
        var burn: Double?
        if let outlook, let resetsAt,
           abs(outlook.resetsUnix - resetsAt.timeIntervalSince1970) < 120 {
            endPct = outlook.endPct
            endLo = outlook.endLoPct
            endHi = outlook.endHiPct
            burn = outlook.burnPctPerHour
            if let c = outlook.crossingDate, c > now { crossingAt = c }
        }
        return PacerSnapshotPayload.Limits.Window(
            identity: identity,
            label: label,
            group: group,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            resetsInSeconds: resetsInSeconds,
            projectedEndPercent: endPct,
            projectedEndLowPercent: endLo,
            projectedEndHighPercent: endHi,
            willHitLimit: crossingAt != nil,
            limitEtaAt: crossingAt,
            limitEtaInSeconds: crossingAt.map { max(0, Int($0.timeIntervalSince(now))) },
            burnPercentPerHour: burn,
            isActive: isActive,
            severity: severity)
    }

    /// The most recent session for one account, or across every account when
    /// unscoped. Normalised to `SessionRow` so the two tables render through
    /// one code path.
    private static func latestSession(context: ModelContext, account: String?) -> SessionRow? {
        if let account {
            var descriptor = FetchDescriptor<AccountSessionInfo>(
                predicate: #Predicate { $0.accountId == account },
                sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor))?.first?.sessionRow
        }
        var descriptor = FetchDescriptor<SessionInfo>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.sessionRow
    }

    /// Read + decode the engine's outlook export from `ClaudeCodeMeta`. `nil`
    /// when absent or stale (the app may not be running; an old projection is
    /// worse than none) — same contract the widgets use.
    private static func engineSnapshot(context: ModelContext, scope: EngineScope) -> EngineSnapshot? {
        let key = EngineSnapshot.metaKey(for: scope)
        let descriptor = FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key })
        guard let json = try? context.fetch(descriptor).first?.value,
              let snapshot = EngineSnapshot.decode(json), snapshot.isFresh else { return nil }
        return snapshot
    }
}
