import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The HTTP API answers from a snapshot built in the background (#191), so
/// three things have to hold for that to be invisible to a consumer: the
/// snapshot carries everything an endpoint used to read on demand, a cached
/// answer says what a fresh build at the moment of the request would have
/// said, and `?account=` resolves exactly as it did against the store.
@Suite("API snapshot")
struct PacerAPISnapshotTests {

    static let work = "74598a77-aaaa"
    static let home = "e34c1364-bbbb"
    static let spare = "e34d0000-cccc"
    static let pinnedRoot = "/tmp/profiles/2"

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
            Account.self, AccountActivation.self, DailyAggregate.self,
            AccountDailyAggregate.self, SessionInfo.self, AccountSessionInfo.self,
            ClaudeCodeMeta.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Midday, so moving the clock a few minutes can never cross midnight and
    /// change which rows count as today.
    static var noon: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }

    /// Three logins — the active one, one pinned to its own profile, and one
    /// with no usage — each with the fixed blocks, plus a scoped window and
    /// today's usage for the first two. Readings land a minute before `now`
    /// so every age is non-zero.
    @MainActor
    static func seed(_ context: ModelContext, now: Date) {
        context.insert(Account(id: work, organizationId: work, displayName: "Work",
                               isActive: true, firstSeenAt: .distantPast, lastSeenAt: now))
        context.insert(Account(id: home, organizationId: home, displayName: "Home",
                               isActive: false, firstSeenAt: .distantPast, lastSeenAt: now))
        context.insert(Account(id: spare, organizationId: spare, displayName: "Spare",
                               isActive: false, firstSeenAt: .distantPast, lastSeenAt: now))
        context.insert(AccountActivation(
            accountId: work, startedAt: now.addingTimeInterval(-86_400),
            endedAt: nil, rootPath: nil, source: AccountActivation.sourceObserved))
        context.insert(AccountActivation(
            accountId: home, startedAt: now.addingTimeInterval(-3_600),
            endedAt: nil, rootPath: pinnedRoot, source: AccountActivation.sourceObserved))

        let sampled = now.addingTimeInterval(-60)
        let reset = now.addingTimeInterval(3_600)
        for (account, five, seven) in [(work, 37.0, 21.0), (home, 2.0, 5.0), (spare, 0.0, 1.0)] {
            context.insert(RateLimitSample(
                sampledAt: sampled, window: RateLimitWindowName.fiveHour,
                usedPercentage: five, resetsAt: reset,
                source: RateLimitSource.oauth, accountId: account))
            context.insert(RateLimitSample(
                sampledAt: sampled, window: RateLimitWindowName.sevenDay,
                usedPercentage: seven, resetsAt: reset.addingTimeInterval(86_400),
                source: RateLimitSource.oauth, accountId: account))
        }
        for (account, percent) in [(work, 16.0), (home, 40.0)] {
            context.insert(UsageLimitSample(
                sampledAt: sampled, identity: "weekly_scoped|Fable|", kind: "weekly_scoped",
                group: "weekly", label: "Fable", percent: percent, resetsAt: reset,
                severity: "normal", isActive: false, modelId: nil, modelDisplayName: "Fable",
                surface: nil, source: RateLimitSource.oauth, accountId: account))
        }
        context.insert(ExtraUsageSample(sampledAt: sampled, amountCents: 250,
                                        source: RateLimitSource.oauth, accountId: work))

        let today = TokenSample.formatDate(now)
        context.insert(DailyAggregate(date: today, model: "claude-opus-5",
                                      inputTokens: 300, outputTokens: 600,
                                      cacheReadTokens: 900, totalCostUSD: 9))
        context.insert(AccountDailyAggregate(accountId: work, date: today, model: "claude-opus-5",
                                             inputTokens: 100, outputTokens: 200,
                                             cacheReadTokens: 300, cacheCreation5mTokens: 0,
                                             cacheCreation1hTokens: 0, totalCostUSD: 6))
        context.insert(AccountDailyAggregate(accountId: home, date: today, model: "claude-opus-5",
                                             inputTokens: 200, outputTokens: 400,
                                             cacheReadTokens: 600, cacheCreation5mTokens: 0,
                                             cacheCreation1hTokens: 0, totalCostUSD: 3))
        context.insert(SessionInfo(sessionId: "s-global", firstSeenAt: sampled, lastSeenAt: sampled,
                                   projectPath: "/Users/x/Code/Globex", cumulativeCostUSD: 9,
                                   cumulativeInputTokens: 300, cumulativeOutputTokens: 600,
                                   cumulativeCacheReadTokens: 900))
        try? context.save()
    }

    @MainActor
    static func seededSnapshot(now: Date) throws -> (PacerAPISnapshot, ModelContainer) {
        let container = try makeContainer()
        seed(ModelContext(container), now: now)
        let snapshot = try PacerAPISnapshot.build(container: container, activeAccountId: work, now: now)
        return (snapshot, container)
    }

    // MARK: - The build

    @MainActor
    @Test func buildFillsEveryEndpointFromTheStore() throws {
        let now = Self.noon
        let (snapshot, _) = try Self.seededSnapshot(now: now)

        #expect(snapshot.builtAt == now)
        // `/v1/snapshot`: every account's cost, the active login's limits.
        #expect(snapshot.unscoped.cost.todayUSD == 9)
        #expect(snapshot.unscoped.limits.fiveHour?.usedPercent == 37)
        #expect(snapshot.unscoped.overageUSD == 2.5)
        // `/v1/snapshot?account=`: every number that account's.
        #expect(snapshot.byAccount[Self.home]?.cost.todayUSD == 3)
        #expect(snapshot.byAccount[Self.home]?.limits.fiveHour?.usedPercent == 2)
        // `/v1/accounts`.
        #expect(Set(snapshot.accounts.accounts.map(\.id)) == [Self.work, Self.home, Self.spare])
        #expect(snapshot.accounts.activeAccountId == Self.work)
        // `/metrics`' per-model and per-account today.
        #expect(snapshot.todayModels.map(\.model) == ["claude-opus-5"])
        #expect(snapshot.todayModels.first?.costUSD == 9)
        #expect(snapshot.todayModelsByAccount[Self.home]?.first?.costUSD == 3)
        #expect(snapshot.todayModelsByAccount[Self.spare]?.isEmpty == true)
        #expect(snapshot.configRoots == [Self.pinnedRoot: Self.home])
    }

    /// `/metrics` reports every login's windows, not only the active one's,
    /// so every real account needs its own limits in the snapshot.
    @MainActor
    @Test func everyAccountHasItsOwnLimits() throws {
        let (snapshot, _) = try Self.seededSnapshot(now: Self.noon)

        #expect(Set(snapshot.limits.keys) == [Self.work, Self.home, Self.spare])
        #expect(snapshot.limits[Self.work]?.fiveHour?.usedPercent == 37)
        #expect(snapshot.limits[Self.home]?.fiveHour?.usedPercent == 2)
        #expect(snapshot.limits[Self.home]?.sevenDay?.usedPercent == 5)
        #expect(snapshot.limits[Self.home]?.scoped.map(\.usedPercent) == [40])
        #expect(snapshot.limits[Self.spare]?.scoped.isEmpty == true)
    }

    /// Resolution is answered from the snapshot, so a key it can return with
    /// no payload behind it would be a 503 for a perfectly good request.
    @MainActor
    @Test func everyResolvableKeyHasAPayload() throws {
        let now = Self.noon
        let (snapshot, _) = try Self.seededSnapshot(now: now)

        for id in [Self.work, Self.home, Self.spare] {
            #expect(snapshot.payload(account: id, at: now)?.account == id)
        }
        #expect(snapshot.payload(account: AccountDailyAggregate.unattributedKey, at: now)?.account
            == PacerAccountsBuilder.unattributedAlias)
        #expect(snapshot.payload(account: nil, at: now)?.account == nil)
    }

    // MARK: - A cached answer is a fresh one

    /// The property the whole design leans on: a payload built at `t` and
    /// served at `t + Δ` is byte-for-byte what a build at `t + Δ` would have
    /// produced from the same rows — countdowns, ages and all.
    @MainActor
    @Test func aCachedPayloadServedLaterMatchesAFreshBuildThen() throws {
        let built = Self.noon
        let served = built.addingTimeInterval(95)
        let (snapshot, container) = try Self.seededSnapshot(now: built)

        for account in [nil, Self.work, Self.home] as [String?] {
            let cached = try #require(snapshot.payload(account: account, at: served))
            let fresh = try PacerSnapshotBuilder.build(container: container, account: account,
                                                       activeAccountId: Self.work, now: served)
            #expect(try cached.encodedJSON() == fresh.encodedJSON())
        }
        #expect(snapshot.accountList(at: served).generatedAt == served)
    }

    @MainActor
    @Test func metricsRenderAtTheRequestWithTheSnapshotsAge() throws {
        let built = Self.noon
        let (snapshot, _) = try Self.seededSnapshot(now: built)
        let text = snapshot.metrics(account: nil, now: built.addingTimeInterval(30),
                                    version: "1", build: "1").prometheusText()

        #expect(text.contains("pacer_api_data_age_seconds 30"))
        // Rebased: the reset was an hour after the build, so 3570 s now.
        #expect(text.contains("pacer_rate_limit_reset_seconds{account=\"\(Self.home)\",window=\"five_hour\"} 3570"))
        #expect(text.contains("pacer_rate_limit_sample_age_seconds{account=\"\(Self.work)\",window=\"five_hour\"} 90"))
        #expect(text.contains("pacer_rate_limit_used_ratio{account=\"\(Self.work)\",window=\"five_hour\"} 0.37"))
        #expect(text.contains("pacer_model_cost_usd{model=\"claude-opus-5\"} 9"))
        #expect(text.contains("pacer_account_cost_usd{account=\"\(Self.home)\"} 3"))
    }

    /// A client pinned to one login gets only that login's windows; the
    /// per-account spend still covers everyone, as it always did.
    @MainActor
    @Test func metricsForOneAccountCarryOnlyItsWindows() throws {
        let now = Self.noon
        let (snapshot, _) = try Self.seededSnapshot(now: now)
        let text = snapshot.metrics(account: Self.home, now: now,
                                    version: "1", build: "1").prometheusText()

        #expect(text.contains("pacer_rate_limit_used_ratio{account=\"\(Self.home)\",window=\"five_hour\"} 0.02"))
        #expect(!text.contains("pacer_rate_limit_used_ratio{account=\"\(Self.work)\""))
        #expect(text.contains("pacer_account_cost_usd{account=\"\(Self.work)\"} 6"))
    }

    // MARK: - Resolving `?account=` / `?config_dir=` from the cached list

    /// Every case the store-backed resolution handles, answered from the
    /// snapshot — and answered the same way the store answers it.
    @MainActor
    @Test func accountResolutionFromTheCachedListMatchesTheStore() throws {
        let (snapshot, container) = try Self.seededSnapshot(now: Self.noon)
        let knownInStore = (try ModelContext(container).fetch(FetchDescriptor<Account>()))
            .map(\.id).sorted()

        let cases: [([String: String], PacerAccountQuery)] = [
            ([:], .all),
            (["account": ""], .all),
            (["account": Self.home], .scoped(Self.home)),
            // A unique prefix, as `pace.sh accounts` prints them (#184).
            (["account": "74598a77"], .scoped(Self.work)),
            (["account": " e34c "], .scoped(Self.home)),
            (["account": "unattributed"], .scoped(AccountDailyAggregate.unattributedKey)),
            // Ambiguous between two ids, and too short to count as a prefix.
            (["account": "e34"],
             .rejected("Unknown account \"e34\". Known: \(Self.work), \(Self.home), \(Self.spare), unattributed\n")),
            (["account": "ffff"],
             .rejected("Unknown account \"ffff\". Known: \(Self.work), \(Self.home), \(Self.spare), unattributed\n")),
            (["config_dir": Self.pinnedRoot + "/"], .scoped(Self.home)),
            (["config_dir": "/tmp/nowhere," + Self.pinnedRoot], .scoped(Self.home)),
            // A profile Pacer has never seen a login in: unscoped, not an error.
            (["config_dir": "/tmp/profiles/77"], .all),
            // ...unless the caller also named an account.
            (["config_dir": "/tmp/profiles/77", "account": "74598a77"], .scoped(Self.work)),
            (["config_dir": Self.pinnedRoot, "account": Self.work], .scoped(Self.home)),
        ]
        for (query, expected) in cases {
            #expect(snapshot.resolve(query) == expected, "query: \(query)")
            let fromStore = PacerAccountQuery.resolve(
                query,
                account: { try PacerAccountsBuilder.resolve(parameter: $0, known: knownInStore) },
                configDir: { try PacerAccountsBuilder.resolve(configDir: $0, container: container) })
            #expect(fromStore == expected, "query: \(query)")
        }
    }

    // MARK: - The holder

    @MainActor
    @Test func theCacheSwapsWholeSnapshotsAndClears() throws {
        let cache = PacerAPISnapshotCache()
        #expect(cache.current == nil)
        let (snapshot, _) = try Self.seededSnapshot(now: Self.noon)
        cache.store(snapshot)
        #expect(cache.current?.builtAt == snapshot.builtAt)
        cache.clear()
        #expect(cache.current == nil)
    }

    /// A cold start waits for the first build, briefly, and then gives up.
    @Test func aColdReadWaitsForTheFirstBuildButNotForever() async throws {
        let cache = PacerAPISnapshotCache()
        let started = Date()
        #expect(cache.current(waitingUpTo: 0.1) == nil)
        #expect(Date().timeIntervalSince(started) >= 0.09)

        let snapshot = try await MainActor.run { try Self.seededSnapshot(now: Self.noon).0 }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cache.store(snapshot) }
        let waited = Date()
        #expect(cache.current(waitingUpTo: 10)?.builtAt == snapshot.builtAt)
        #expect(Date().timeIntervalSince(waited) < 5)
    }
}

/// Seconds-from-now fields recomputed at serve time.
@Suite("Rebasing a served payload")
struct PacerSnapshotRebaseTests {

    private let built = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(resetsAt: Date?, resetsIn: Int?, etaAt: Date?, etaIn: Int?,
                        sampledAt: Date?, age: Int?) -> PacerSnapshotPayload.Limits.Window {
        PacerSnapshotPayload.Limits.Window(
            identity: "five_hour", label: "5-hour", group: "session",
            usedPercent: 40, resetsAt: resetsAt, resetsInSeconds: resetsIn,
            projectedEndPercent: 120, projectedEndLowPercent: 100, projectedEndHighPercent: 140,
            willHitLimit: etaAt != nil, limitEtaAt: etaAt, limitEtaInSeconds: etaIn,
            burnPercentPerHour: 12, recentBurnPercentPerHour: 18,
            isActive: true, severity: "warning",
            sampledAt: sampledAt, sampleAgeSeconds: age)
    }

    private var live: PacerSnapshotPayload.Limits.Window {
        window(resetsAt: built.addingTimeInterval(3_600), resetsIn: 3_600,
               etaAt: built.addingTimeInterval(1_800), etaIn: 1_800,
               sampledAt: built.addingTimeInterval(-60), age: 60)
    }

    @Test func countdownsAndAgesAreRecomputedFromTheirDates() {
        let w = live.rebased(to: built.addingTimeInterval(100))
        #expect(w.resetsInSeconds == 3_500)
        #expect(w.limitEtaInSeconds == 1_700)
        #expect(w.sampleAgeSeconds == 160)
        #expect(w.willHitLimit)
        // The absolute dates are what everything is recomputed from; they
        // never move.
        #expect(w.resetsAt == live.resetsAt)
        #expect(w.limitEtaAt == live.limitEtaAt)
        #expect(w.sampledAt == live.sampledAt)
        // Nothing else is time-relative.
        #expect(w.usedPercent == 40)
        #expect(w.projectedEndPercent == 120)
        #expect(w.burnPercentPerHour == 12)
        #expect(w.recentBurnPercentPerHour == 18)
        #expect(w.severity == "warning")
    }

    /// The builder only reports a crossing still ahead of it, so one that has
    /// passed since the build goes exactly the way a rebuild would take it.
    @Test func aCrossingThatHasPassedIsDroppedAsABuildWouldDropIt() {
        let w = live.rebased(to: built.addingTimeInterval(2_000))
        #expect(w.limitEtaAt == nil)
        #expect(w.limitEtaInSeconds == nil)
        #expect(!w.willHitLimit)
        #expect(w.resetsInSeconds == 1_600)
    }

    @Test func countdownsFloorAtZero() {
        let w = live.rebased(to: built.addingTimeInterval(4_000))
        #expect(w.resetsInSeconds == 0)
    }

    @Test func absentValuesStayAbsent() {
        let bare = window(resetsAt: nil, resetsIn: nil, etaAt: nil, etaIn: nil,
                          sampledAt: nil, age: nil)
        let w = bare.rebased(to: built.addingTimeInterval(500))
        #expect(w.resetsAt == nil)
        #expect(w.resetsInSeconds == nil)
        #expect(w.limitEtaAt == nil)
        #expect(w.limitEtaInSeconds == nil)
        #expect(!w.willHitLimit)
        #expect(w.sampledAt == nil)
        #expect(w.sampleAgeSeconds == nil)
    }

    /// A relative value with no date behind it has nothing to be recomputed
    /// from, so it is passed through rather than dropped.
    @Test func aRelativeValueWithNoDateIsLeftAlone() {
        let handBuilt = window(resetsAt: nil, resetsIn: 7_200, etaAt: nil, etaIn: nil,
                               sampledAt: nil, age: 35)
        let w = handBuilt.rebased(to: built.addingTimeInterval(500))
        #expect(w.resetsInSeconds == 7_200)
        #expect(w.sampleAgeSeconds == 35)
    }

    @Test func thePayloadRebasesEveryWindowAndItsDataAge() {
        let payload = PacerSnapshotPayload(
            schemaVersion: 1, generatedAt: built, account: "org-work",
            limits: .init(fiveHour: live, sevenDay: nil, scoped: [live]),
            cost: .init(todayUSD: 3, weekUSD: 4, monthUSD: 5, allTimeUSD: 6,
                        projectedTodayUSD: nil, projectedTodayLowUSD: nil,
                        projectedTodayHighUSD: nil, projectedMonthUSD: nil,
                        projectedMonthLowUSD: nil, projectedMonthHighUSD: nil),
            tokens: .init(todayInput: 1, todayOutput: 2, todayCacheRead: 3, todayTotal: 3),
            pace: .init(percentile: 0.5, status: "about normal"),
            session: nil, overageUSD: 1.5,
            dataSource: .init(source: "oauth", lastSampleAt: built.addingTimeInterval(-30),
                              ageSeconds: 30, forecastFresh: true))
        let served = built.addingTimeInterval(60)
        let r = payload.rebased(to: served)

        #expect(r.generatedAt == served)
        #expect(r.dataSource.ageSeconds == 90)
        #expect(r.dataSource.lastSampleAt == payload.dataSource.lastSampleAt)
        #expect(r.limits.fiveHour?.resetsInSeconds == 3_540)
        #expect(r.limits.sevenDay == nil)
        #expect(r.limits.scoped.map(\.resetsInSeconds) == [3_540])
        #expect(r.limits.scoped.map(\.sampleAgeSeconds) == [120])
        #expect(r.account == "org-work")
        #expect(r.cost.todayUSD == 3)
        #expect(r.overageUSD == 1.5)
        #expect(r.dataSource.forecastFresh)
    }

    @Test func theDataAgeMetricIsOnlyRenderedWhenGiven() {
        let payload = PacerSnapshotPayload(
            schemaVersion: 1, generatedAt: built,
            limits: .init(fiveHour: nil, sevenDay: nil),
            cost: .init(todayUSD: 0, weekUSD: 0, monthUSD: 0, allTimeUSD: 0,
                        projectedTodayUSD: nil, projectedTodayLowUSD: nil,
                        projectedTodayHighUSD: nil, projectedMonthUSD: nil,
                        projectedMonthLowUSD: nil, projectedMonthHighUSD: nil),
            tokens: .init(todayInput: 0, todayOutput: 0, todayCacheRead: 0, todayTotal: 0),
            pace: .init(percentile: nil, status: nil),
            session: nil, overageUSD: 0,
            dataSource: .init(source: nil, lastSampleAt: nil, ageSeconds: nil, forecastFresh: false))
        let without = PacerMetrics(snapshot: payload, version: "1", build: "1").prometheusText()
        #expect(!without.contains("pacer_api_data_age_seconds"))
        let with = PacerMetrics(snapshot: payload, version: "1", build: "1",
                                apiDataAgeSeconds: 12).prometheusText()
        #expect(with.contains("# TYPE pacer_api_data_age_seconds gauge"))
        #expect(with.contains("pacer_api_data_age_seconds 12"))
    }
}
