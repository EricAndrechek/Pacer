import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #429: the poller's store writes (`TokenLaneMeta`, `Account`, a poll's
// history rows and the hourly eviction) moved off the main actor, into the
// `nonisolated static` writers of OAuthPoller+Store.swift, called on the
// poller. These pin three things:
//
// - each writer leaves exactly the rows the main-actor block it replaced left
//   (the old blocks are copied below, verbatim, as the reference);
// - each runs with no main actor at all;
// - through the poller's real entry points, every save it makes is off the
//   main thread, and the signals are posted after the saves they announce.
//
// Fictional ids throughout.

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(for: Schema(PacerStore.allModelTypes),
                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

/// Synchronous, so it can ask `Thread` from inside a task.
private func onMainThread() -> Bool { Thread.isMainThread }

/// Whole seconds, so a date survives the store unchanged on both paths.
private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
private let t0 = now.addingTimeInterval(-3_600)
/// Past `OAuthPoller.liveWindowDays`, so the eviction moves it.
private let old = now.addingTimeInterval(-90 * 86_400)

// MARK: - Row dumps

/// Every row of every table the poller writes, as text, sorted: two stores
/// compare equal when they hold the same rows, whatever order a fetch returns.
/// `seenTimes: false` leaves out `Account.firstSeenAt`/`lastSeenAt`, which
/// `Account.ensure` stamps with the wall clock.
private func dump(_ container: ModelContainer, seenTimes: Bool = true) -> [String] {
    let c = ModelContext(container)
    func d(_ v: Any?) -> String { v.map { "\($0)" } ?? "-" }
    var out: [String] = []
    for a in (try? c.fetch(FetchDescriptor<Account>())) ?? [] {
        out.append("account \(a.id) org=\(d(a.organizationId)) name=\(a.displayName) active=\(a.isActive)"
            + (seenTimes ? " first=\(a.firstSeenAt) last=\(a.lastSeenAt)" : "")
            + " plan=\(d(a.subscriptionType)) tier=\(d(a.rateLimitTier)) slot=\(d(a.switcherSlot))"
            + " email=\(d(a.emailAddress)) orgName=\(d(a.organizationName))"
            + " 5h=\(d(a.latestFiveHourPct))@\(d(a.latestFiveHourResetsAt))"
            + " 7d=\(d(a.latestSevenDayPct))@\(d(a.latestSevenDayResetsAt))"
            + " cents=\(d(a.latestExtraUsageCents)) polled=\(d(a.latestPolledAt))")
    }
    for m in (try? c.fetch(FetchDescriptor<TokenLaneMeta>())) ?? [] {
        out.append("lane \(m.id) src=\(m.sourceRaw) org=\(d(m.organizationId)) acct=\(m.accountRaw)"
            + " exp=\(d(m.expiresAt)) polled=\(d(m.lastPolledAt)) cool=\(d(m.cooldownUntil))"
            + " fails=\(m.consecutiveFailures) updated=\(m.updatedAt)")
    }
    for r in (try? c.fetch(FetchDescriptor<RateLimitSample>())) ?? [] {
        out.append("rl \(r.sampledAt) \(r.window) \(r.usedPercentage) \(d(r.resetsAt)) \(r.source)"
            + " acct=\(d(r.accountId)) lane=\(d(r.laneId))")
    }
    for e in (try? c.fetch(FetchDescriptor<ExtraUsageSample>())) ?? [] {
        out.append("extra \(e.sampledAt) \(e.amountCents) \(e.source) acct=\(d(e.accountId))")
    }
    for l in (try? c.fetch(FetchDescriptor<UsageLimitSample>())) ?? [] {
        out.append("limit \(l.sampledAt) \(l.identity) \(l.kind) \(l.group) \(l.label) \(l.percent)"
            + " \(d(l.resetsAt)) \(l.severity) \(l.isActive) \(d(l.modelId)) \(d(l.modelDisplayName))"
            + " \(d(l.surface)) \(l.source) acct=\(d(l.accountId)) lane=\(d(l.laneId))")
    }
    for a in (try? c.fetch(FetchDescriptor<AccountUsageArchive>())) ?? [] {
        out.append("archive \(a.accountId) \(a.kind) \(a.sampledAt) \(d(a.window)) \(d(a.usedPercentage))"
            + " \(d(a.resetsAt)) \(d(a.amountCents)) \(a.source) \(d(a.identity)) \(d(a.limitKind))"
            + " \(d(a.group)) \(d(a.label)) \(d(a.severity)) \(d(a.isActive)) \(d(a.modelId))"
            + " \(d(a.modelDisplayName)) \(d(a.surface)) lane=\(d(a.laneId))")
    }
    for e in (try? c.fetch(FetchDescriptor<AccountPlanEvent>())) ?? [] {
        out.append("plan \(e.accountId) \(e.observedAt) \(e.kind) \(d(e.subscriptionType)) \(d(e.rateLimitTier))"
            + " prev=\(d(e.previousSubscriptionType))/\(d(e.previousRateLimitTier)) by=\(d(e.reportedBy))")
    }
    for o in (try? c.fetch(FetchDescriptor<LiveMeterOutcome>())) ?? [] {
        out.append("meter \(o.accountId) \(o.window) \(o.readingAt) \(o.readingPercent) \(d(o.readingResetsAt))"
            + " prev=\(o.previousAt)/\(o.previousPercent) same=\(o.sameCycle) shown=\(o.shownPercent)"
            + " live=\(o.livePercent) exact=\(o.exactPercent)/\(o.exactAdded) carry=\(o.carry)"
            + " spend=\(o.spendUSD) rate=\(o.rateSource) restarted=\(o.restarted) fit=\(o.fitDay)"
            + " held=\(d(o.heldImplied))@\(d(o.heldAt)) readingHeld=\(d(o.readingHeldImplied)) runaway=\(o.runaway)")
    }
    return out.sorted()
}

// MARK: - The main-actor blocks #429 replaced, verbatim, as the reference

/// `saveAllLaneMeta`'s block.
@MainActor
private func oldSaveAllLaneMeta(_ rows: [OAuthPoller.LaneMetaSnapshot], now: Date,
                                container: ModelContainer) {
    let keep = Set(rows.map { $0.id })
    let context = ModelContext(container)
    let existing = (try? context.fetch(FetchDescriptor<TokenLaneMeta>())) ?? []
    var byId: [String: TokenLaneMeta] = [:]
    for e in existing { byId[e.id] = e }
    for row in rows {
        if let m = byId[row.id] {
            m.sourceRaw = row.sourceRaw
            m.organizationId = row.organizationId
            m.accountRaw = row.account.rawValue
            m.expiresAt = row.expiresAt
            m.lastPolledAt = row.lastPolledAt
            m.cooldownUntil = row.cooldownUntil
            m.consecutiveFailures = row.consecutiveFailures
            m.updatedAt = now
        } else {
            context.insert(TokenLaneMeta(
                id: row.id,
                sourceRaw: row.sourceRaw,
                organizationId: row.organizationId,
                accountRaw: row.account.rawValue,
                expiresAt: row.expiresAt,
                lastPolledAt: row.lastPolledAt,
                cooldownUntil: row.cooldownUntil,
                consecutiveFailures: row.consecutiveFailures,
                updatedAt: now
            ))
        }
    }
    for e in existing where !keep.contains(e.id) { context.delete(e) }
    do { try context.save() }
    catch { Log.write("OAuthPoller", "lane-meta persist failed: \(error)") }
}

/// `loadPersistedMetaIfNeeded`'s block.
@MainActor
private func oldLoadLaneMeta(container: ModelContainer)
    -> (meta: [String: OAuthPoller.LaneMetaSnapshot], activeKey: String?, activeOrg: String?, metaPrimaryOrg: String?) {
    let context = ModelContext(container)
    let rows = (try? context.fetch(FetchDescriptor<TokenLaneMeta>())) ?? []
    var map: [String: OAuthPoller.LaneMetaSnapshot] = [:]
    var metaPrimary: String?
    for r in rows {
        let account = OAuthPollScheduler.AccountStatus(rawValue: r.accountRaw)
        map[r.id] = OAuthPoller.LaneMetaSnapshot(
            id: r.id,
            sourceRaw: r.sourceRaw,
            organizationId: r.organizationId,
            account: account,
            expiresAt: r.expiresAt,
            lastPolledAt: r.lastPolledAt,
            cooldownUntil: r.cooldownUntil,
            consecutiveFailures: r.consecutiveFailures
        )
        if account == .primary, metaPrimary == nil { metaPrimary = r.organizationId }
    }
    let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
    let active = accounts.first { $0.isActive }
    return (map, active?.id, active?.organizationId, metaPrimary)
}

/// `recordPoll`'s block, up to and including the save. The diagnostic log
/// line (`logIfUsageWentDown`) writes nothing and is left out; the eviction
/// is the same pass, run on the same gate.
@MainActor
private func oldRecordPoll(_ record: OAuthPoller.PollRecord, container: ModelContainer) -> Bool {
    let context = ModelContext(container)
    let captured = record.snapshot
    let organizationId = record.organizationId
    let subscriptionType = record.subscriptionType
    let rateLimitTier = record.rateLimitTier
    let isActive = record.isActive
    let laneId = record.laneId
    let source = record.source
    let measured = record.measured

    let key = record.accountKey
    let accounts = (try? context.fetch(
        FetchDescriptor<Account>(predicate: #Predicate { $0.id == key })
    )) ?? []
    let account: Account
    if let existing = accounts.first {
        account = existing
    } else {
        account = Account(
            id: key,
            organizationId: organizationId,
            displayName: Account.defaultName(forOrg: organizationId, subscriptionType: subscriptionType),
            isActive: isActive,
            firstSeenAt: captured.sampledAt,
            lastSeenAt: captured.sampledAt,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier
        )
        context.insert(account)
    }
    account.lastSeenAt = captured.sampledAt
    if account.organizationId == nil, let organizationId { account.organizationId = organizationId }
    if let plan = record.plan { account.apply(plan, in: context) }
    if isActive { account.isActive = true }
    if let w = captured.fiveHour {
        account.latestFiveHourPct = w.usedPercentage
        account.latestFiveHourResetsAt = w.resetsAt
    } else if LimitSamplePoint.hasNoFiveHourWindow(hasFiveHour: false, hasSevenDay: captured.sevenDay != nil) {
        account.latestFiveHourPct = nil
        account.latestFiveHourResetsAt = nil
    }
    if let w = captured.sevenDay {
        account.latestSevenDayPct = w.usedPercentage
        account.latestSevenDayResetsAt = w.resetsAt
    }
    if let cents = captured.extraUsageCents { account.latestExtraUsageCents = cents }
    account.latestPolledAt = captured.sampledAt

    if let window = captured.fiveHour {
        context.insert(RateLimitSample(
            sampledAt: captured.sampledAt, window: RateLimitWindowName.fiveHour,
            usedPercentage: window.usedPercentage, resetsAt: window.resetsAt,
            source: source, accountId: key, laneId: laneId))
    }
    if let window = captured.sevenDay {
        context.insert(RateLimitSample(
            sampledAt: captured.sampledAt, window: RateLimitWindowName.sevenDay,
            usedPercentage: window.usedPercentage, resetsAt: window.resetsAt,
            source: source, accountId: key, laneId: laneId))
    }
    if let cents = captured.extraUsageCents {
        context.insert(ExtraUsageSample(
            sampledAt: captured.sampledAt, amountCents: cents, source: source, accountId: key))
    }
    for limit in captured.limits {
        context.insert(UsageLimitSample(
            from: limit, sampledAt: captured.sampledAt, source: source, accountId: key, laneId: laneId))
    }
    if !measured.isEmpty, LiveMeterOutcome.isRegistered(in: context) {
        for row in LiveMeterOutcome.rows(account: key, measurements: measured) { context.insert(row) }
    }
    if record.evictStaleRows {
        _ = OAuthPoller.testEvictStaleLiveRows(context: context, accountId: key)
    }
    do {
        try context.save()
        return true
    } catch {
        return false
    }
}

/// `activateAccount`'s block.
@MainActor
private func oldActivate(_ incoming: String, seed: Account.Seed?, container: ModelContainer)
    -> (organizationId: String?, created: Bool, changed: Bool, exists: Bool, saved: Bool) {
    let context = ModelContext(container)
    var created = false
    if let seed, seed.id == incoming {
        created = Account.ensure(seed, in: context).created
    }
    let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
    var incomingOrg: String?
    var changed = created
    var exists = false
    for account in accounts {
        let active = (account.id == incoming)
        if account.isActive != active {
            account.isActive = active
            changed = true
        }
        if active {
            incomingOrg = account.organizationId
            exists = true
        }
    }
    var saved = false
    if context.hasChanges {
        do {
            try context.save()
            saved = true   // where the block posted `AccountWriteSignal`
        } catch {
            Log.write("OAuthPoller", "could not save the active account: \(error)")
        }
    }
    return (incomingOrg, created, changed, exists, saved)
}

/// `provisionSwitcherAccounts`'s block.
@MainActor
private func oldProvision(_ seeds: [Account.Seed], container: ModelContainer) -> (created: [String], posted: Bool) {
    let context = ModelContext(container)
    var made: [String] = []
    for seed in seeds where Account.ensure(seed, in: context).created {
        made.append(seed.id)
    }
    var posted = false
    if context.hasChanges {
        do { try context.save() } catch {
            return ([], false)
        }
        posted = true
    }
    return (made, posted)
}

/// `renameAccount`'s block. Returns whether it posted.
@MainActor
private func oldRename(id: String, to name: String, container: ModelContainer) -> Bool {
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
    guard let account = (try? context.fetch(descriptor))?.first else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    account.displayName = trimmed.isEmpty
        ? Account.defaultName(forOrg: account.organizationId,
                              subscriptionType: account.subscriptionType)
        : trimmed
    try? context.save()
    return true
}

// MARK: - Seeds

/// Two accounts, a lane-meta row for each of two tokens plus one stale one, a
/// plan event, a prior reading per window, and one row per sample table old
/// enough to evict (one with no account, as pre-multi-account rows are).
@MainActor
private func seed(_ container: ModelContainer) throws {
    let c = ModelContext(container)
    c.insert(Account(id: "acme-a", organizationId: "acme-a", displayName: "Claude account (max)",
                     isActive: true, firstSeenAt: old, lastSeenAt: t0,
                     subscriptionType: "max", rateLimitTier: nil, emailAddress: "a@example.com",
                     latestFiveHourPct: 60, latestSevenDayPct: 30, latestPolledAt: t0))
    let b = Account(id: "acme-b", organizationId: "acme-b", displayName: "Claude account (pro)",
                    isActive: false, firstSeenAt: old, lastSeenAt: t0, subscriptionType: "pro")
    b.switcherSlot = 2
    c.insert(b)
    c.insert(AccountPlanEvent(accountId: "acme-a", AccountPlanState.Event(
        observedAt: old, kind: AccountPlanEvent.kindFirst, subscriptionType: "max", rateLimitTier: nil)))
    for (id, org, acct) in [("lane-keep", "acme-a", "primary"), ("lane-moved", "acme-b", "secondary"),
                            ("lane-gone", "acme-a", "primary")] {
        c.insert(TokenLaneMeta(id: id, sourceRaw: "keychain", organizationId: org, accountRaw: acct,
                               expiresAt: now.addingTimeInterval(3_600), lastPolledAt: t0,
                               cooldownUntil: nil, consecutiveFailures: 0, updatedAt: t0))
    }
    c.insert(RateLimitSample(sampledAt: t0, window: RateLimitWindowName.fiveHour, usedPercentage: 60,
                             resetsAt: now.addingTimeInterval(7_200), source: RateLimitSource.oauth,
                             accountId: "acme-a", laneId: "lane-keep"))
    c.insert(RateLimitSample(sampledAt: t0, window: RateLimitWindowName.sevenDay, usedPercentage: 30,
                             resetsAt: now.addingTimeInterval(86_400), source: RateLimitSource.oauth,
                             accountId: "acme-a", laneId: "lane-keep"))
    c.insert(RateLimitSample(sampledAt: old, window: RateLimitWindowName.fiveHour, usedPercentage: 77,
                             resetsAt: nil, source: RateLimitSource.oauth, accountId: "acme-b", laneId: "lane-moved"))
    c.insert(ExtraUsageSample(sampledAt: old, amountCents: 125, source: RateLimitSource.oauth))
    c.insert(UsageLimitSample(sampledAt: old, identity: "weekly_scoped|Fable|", kind: "weekly_scoped",
                              group: "weekly", label: "Fable", percent: 40, resetsAt: nil, severity: "normal",
                              isActive: true, modelId: nil, modelDisplayName: "Fable", surface: nil,
                              source: RateLimitSource.oauth, accountId: "acme-a", laneId: "lane-keep"))
    try c.save()
}

private func window(_ pct: Double, in seconds: TimeInterval) -> RateLimitWindow {
    RateLimitWindow(usedPercentage: pct, resetsAt: now.addingTimeInterval(seconds))
}

private func scoped(_ name: String, _ pct: Double) -> UsageLimit {
    UsageLimit(kind: "weekly_scoped", group: "weekly", percent: pct, severity: UsageLimitSeverity("normal"),
               resetsAt: now.addingTimeInterval(86_400),
               scope: UsageLimitScope(model: UsageLimitScope.Model(id: nil, displayName: name), surface: nil),
               isActive: false)
}

/// One window the live meter had a value for, and one it had none for.
private func measurements(at: Date) -> [LiveMeterDrift.Measurement] {
    let reading = MeterReading(at: at, percent: 65, resetsAt: now.addingTimeInterval(7_200))
    let previous = MeterReading(at: t0, percent: 60, resetsAt: now.addingTimeInterval(7_200))
    let value = LiveMeterValue(percent: 63, reading: previous, addedPoints: 3, exactAdded: 3.4, spendUSD: 12,
                               rateSource: .perModel, restarted: false, asOf: at, fittedDay: "2026-11-23")
    return [
        LiveMeterDrift.Measurement(window: RateLimitWindowName.fiveHour, reading: reading, value: value,
                                   sameCycle: true, readingHeldImplied: nil, runaway: .fine),
        LiveMeterDrift.Measurement(window: RateLimitWindowName.sevenDay, reading: reading, value: nil,
                                   sameCycle: nil, readingHeldImplied: nil, runaway: nil),
    ]
}

/// The polls the comparison runs: every branch of the account upsert and of
/// the history rows, with and without the eviction.
private func pollCases(planFrom container: ModelContainer) -> [(name: String, record: OAuthPoller.PollRecord)] {
    let at = now.addingTimeInterval(-60)
    func plan(_ account: String, _ sub: String?, _ tier: String?) -> AccountPlanState.Change? {
        var state = AccountPlanState.load(accountId: account, in: ModelContext(container))
        return state.observe(subscriptionType: sub, rateLimitTier: tier, at: at, reportedBy: "keychain")
    }
    func record(_ snapshot: RateLimitSnapshot, account: String, active: Bool, sub: String?, tier: String?,
                lane: CredentialCandidate.Source = .keychain, laneId: String? = "lane-keep",
                source: String = RateLimitSource.oauth, measured: [LiveMeterDrift.Measurement] = [],
                evict: Bool = false) -> OAuthPoller.PollRecord {
        OAuthPoller.PollRecord(
            snapshot: snapshot, accountKey: account, organizationId: snapshot.organizationId,
            subscriptionType: sub, rateLimitTier: tier, isActive: active, laneSource: lane, laneId: laneId,
            source: source, plan: plan(account, sub, tier), measured: measured, evictStaleRows: evict)
    }
    return [
        ("the active account, everything at once, a plan change and the eviction",
         record(RateLimitSnapshot(sampledAt: at, fiveHour: window(65, in: 7_200), sevenDay: window(31, in: 86_400),
                                  extraUsageCents: 250, organizationId: "acme-a",
                                  limits: [scoped("Fable", 44)]),
                account: "acme-a", active: true, sub: "max", tier: "default_claude_max_20x",
                measured: measurements(at: at), evict: true)),
        ("a usage decrease the diagnostic logs",
         record(RateLimitSnapshot(sampledAt: at, fiveHour: window(40, in: 7_200), sevenDay: nil,
                                  extraUsageCents: nil, organizationId: "acme-a", limits: []),
                account: "acme-a", active: true, sub: "max", tier: nil)),
        ("an account seen for the first time, not active",
         record(RateLimitSnapshot(sampledAt: at, fiveHour: window(10, in: 7_200), sevenDay: nil,
                                  extraUsageCents: nil, organizationId: "acme-new", limits: []),
                account: "acme-new", active: false, sub: "pro", tier: nil, lane: .desktop, laneId: "lane-new")),
        ("no 5-hour window (Ultra) clears the cached one",
         record(RateLimitSnapshot(sampledAt: at, fiveHour: nil, sevenDay: window(40, in: 86_400),
                                  extraUsageCents: nil, organizationId: "acme-a", limits: []),
                account: "acme-a", active: true, sub: nil, tier: nil)),
        ("a switcher-cache reading: no plan, no lane",
         record(RateLimitSnapshot(sampledAt: at, fiveHour: window(20, in: 7_200), sevenDay: nil,
                                  extraUsageCents: nil, organizationId: "acme-b",
                                  limits: [scoped("Fable", 12)]),
                account: "acme-b", active: false, sub: nil, tier: nil, lane: .parked, laneId: nil,
                source: RateLimitSource.cswap)),
        ("a response with no windows writes the account and no history",
         record(RateLimitSnapshot(sampledAt: at, fiveHour: nil, sevenDay: nil, extraUsageCents: nil,
                                  organizationId: "acme-a", limits: []),
                account: "acme-a", active: true, sub: nil, tier: nil, evict: true)),
    ]
}

// MARK: - Tests

@Suite("OAuthPoller store writes, off the main actor (#429)")
struct OAuthPollerStoreTests {

    @Test("A poll writes what the main-actor block wrote: account, history, plan, meter, eviction")
    func pollMatchesOldPath() async throws {
        let probe = try makeContainer()
        try await seed(probe)
        for (name, record) in pollCases(planFrom: probe) {
            let reference = try makeContainer(), moved = try makeContainer()
            try await seed(reference)
            try await seed(moved)
            let oldSaved = await oldRecordPoll(record, container: reference)
            let (write, onMain) = await Task.detached {
                (OAuthPoller.writePoll(record, container: moved), onMainThread())
            }.value
            #expect(!onMain, "\(name)")
            #expect(write.saved && oldSaved, "\(name)")
            let windows = record.snapshot.fiveHour != nil || record.snapshot.sevenDay != nil
                || record.snapshot.extraUsageCents != nil || !record.snapshot.limits.isEmpty
            #expect(write.wroteRows == windows, "\(name)")
            #expect(dump(moved) == dump(reference), "\(name)")
            #expect(dump(moved) != dump(probe), "\(name): the poll wrote something")
        }
    }

    @Test("The eviction moves every stale row to the archive, in the poll's save")
    func evictionByHand() async throws {
        let container = try makeContainer()
        try await seed(container)
        let record = try #require(pollCases(planFrom: container).first?.record)
        #expect(record.evictStaleRows)
        let write = await Task.detached { OAuthPoller.writePoll(record, container: container) }.value
        #expect(write.saved)
        let rows = dump(container)
        #expect(!rows.contains { $0.hasPrefix("rl ") && $0.contains(" 77.0 ") }, "the old live row left")
        #expect(!rows.contains { $0.hasPrefix("extra ") && $0.contains(" 125 ") })
        #expect(!rows.contains { $0.hasPrefix("limit ") && $0.contains(" 40.0 ") })
        let archived = rows.filter { $0.hasPrefix("archive ") }
        #expect(archived.count == 3, "nothing lost: \(archived)")
        // Each keeps its own account; the row with none goes to the account
        // that polled.
        #expect(archived.contains { $0.hasPrefix("archive acme-b ") && $0.contains(" 77.0 ") })
        #expect(archived.contains { $0.hasPrefix("archive acme-a ") && $0.contains(" 40.0 ") })
        #expect(archived.contains { $0.hasPrefix("archive acme-a ") && $0.contains(" 125 ") })
    }

    @Test("Lane metadata: the same upserts and prunes, and the same launch read")
    func laneMetaMatchesOldPath() async throws {
        let reference = try makeContainer(), moved = try makeContainer()
        try await seed(reference)
        try await seed(moved)
        let rows = [
            OAuthPoller.LaneMetaSnapshot(id: "lane-keep", sourceRaw: "keychain", organizationId: "acme-a",
                                         account: .primary, expiresAt: now.addingTimeInterval(7_200),
                                         lastPolledAt: now, cooldownUntil: nil, consecutiveFailures: 0),
            OAuthPoller.LaneMetaSnapshot(id: "lane-moved", sourceRaw: "desktop", organizationId: "acme-b",
                                         account: .secondary, expiresAt: nil, lastPolledAt: t0,
                                         cooldownUntil: now.addingTimeInterval(21_600), consecutiveFailures: 3),
            OAuthPoller.LaneMetaSnapshot(id: "lane-new", sourceRaw: "override", organizationId: nil,
                                         account: .unknown, expiresAt: nil, lastPolledAt: nil,
                                         cooldownUntil: nil, consecutiveFailures: 0),
        ]
        await oldSaveAllLaneMeta(rows, now: now, container: reference)
        let (saved, onMain) = await Task.detached {
            (OAuthPoller.writeLaneMeta(rows, now: now, container: moved), onMainThread())
        }.value
        #expect(saved && !onMain)
        #expect(dump(moved) == dump(reference))
        let lanes = dump(moved).filter { $0.hasPrefix("lane ") }
        #expect(lanes.map { $0.split(separator: " ")[1] } == ["lane-keep", "lane-moved", "lane-new"],
                "upserted, inserted, and the stale one pruned")

        let expected = await oldLoadLaneMeta(container: moved)
        let (loaded, loadOnMain) = await Task.detached {
            (OAuthPoller.readLaneMeta(container: moved), onMainThread())
        }.value
        #expect(!loadOnMain)
        #expect(loaded.meta == expected.meta)
        #expect(loaded.activeKey == expected.activeKey && loaded.activeKey == "acme-a")
        #expect(loaded.activeOrg == expected.activeOrg)
        #expect(loaded.metaPrimaryOrg == expected.metaPrimaryOrg && loaded.metaPrimaryOrg == "acme-a")
    }

    @Test("Activation: the same flags, the same created row, the same answer",
          arguments: [("acme-b", false), ("acme-a", false), ("acme-new", true), ("acme-unknown", false)])
    func activationMatchesOldPath(incoming: String, withSeed: Bool) async throws {
        let reference = try makeContainer(), moved = try makeContainer()
        try await seed(reference)
        try await seed(moved)
        let seed = withSeed
            ? Account.Seed(id: incoming, organizationId: incoming, emailAddress: "new@example.com") : nil
        let expected = await oldActivate(incoming, seed: seed, container: reference)
        let (got, onMain) = await Task.detached {
            (OAuthPoller.writeActivation(incoming, seed: seed, container: moved), onMainThread())
        }.value
        #expect(!onMain)
        #expect(got == OAuthPoller.Activation(organizationId: expected.organizationId, created: expected.created,
                                              changed: expected.changed, exists: expected.exists,
                                              saved: expected.saved))
        #expect(dump(moved, seenTimes: false) == dump(reference, seenTimes: false))
    }

    @Test("Roster provisioning: creates the same rows, touches none that exist")
    func rosterMatchesOldPath() async throws {
        let reference = try makeContainer(), moved = try makeContainer()
        try await seed(reference)
        try await seed(moved)
        let seeds = [Account.Seed(id: "acme-b", organizationId: "acme-b", emailAddress: "ignored@example.com"),
                     Account.Seed(id: "acme-c", organizationId: "acme-c", emailAddress: "c@example.com",
                                  switcherSlot: 3),
                     Account.Seed(id: "acme-d", organizationId: "acme-d")]
        let expected = await oldProvision(seeds, container: reference)
        let (got, onMain) = await Task.detached {
            (OAuthPoller.writeRosterAccounts(seeds, container: moved), onMainThread())
        }.value
        #expect(!onMain)
        #expect(got.created == expected.created && got.created == ["acme-c", "acme-d"])
        #expect(got.saved == expected.posted && got.saved)
        #expect(dump(moved, seenTimes: false) == dump(reference, seenTimes: false))

        // An unchanged roster saves nothing, so it posts nothing.
        let again = await Task.detached { OAuthPoller.writeRosterAccounts(seeds, container: moved) }.value
        #expect(again.created.isEmpty && !again.saved)
    }

    @Test("Rename: the same name, the derived one back on a blank, nothing for an unknown id",
          arguments: [("acme-b", "Side"), ("acme-a", "   "), ("acme-unknown", "Nobody")])
    func renameMatchesOldPath(id: String, name: String) async throws {
        let reference = try makeContainer(), moved = try makeContainer()
        try await seed(reference)
        try await seed(moved)
        let expected = await oldRename(id: id, to: name, container: reference)
        let (got, onMain) = await Task.detached {
            (OAuthPoller.writeAccountName(id: id, to: name, container: moved), onMainThread())
        }.value
        #expect(!onMain)
        #expect(got == expected)
        #expect(dump(moved) == dump(reference))
    }

    /// The poller's whole store traffic, through its real entry points: a
    /// poll, a roster ingest, a switch (with a seed, so a row is created), a
    /// rename. Every save it makes is watched (`ModelContext.didSave`, posted
    /// on the saving thread) and must be off the main thread; a control save
    /// on main shows the watch would catch one.
    ///
    /// The signals follow the saves: `AccountWriteSignal` from the poller, off
    /// main, finding the row; the scan-cycle summary on main, finding the
    /// reading it announces; `RateLimitWriteSignal` moved for the account.
    ///
    /// Not done by holding the main thread while the poller runs: in the full
    /// parallel suite, tests that block a pool thread on main starve the
    /// poller, and the hold would only time out (and stall everyone else).
    @Test("Every save the poller makes is off the main thread, and its signals follow the saves")
    func everySaveIsOffMain() async throws {
        let container = try makeContainer()
        let key = "acme-off-main-\(UUID().uuidString.prefix(8))"
        let roster = SwitcherUsageCache.Contents(
            accounts: [.init(organizationId: "acme-roster", emailAddress: "side@example.com", slot: 2)],
            readings: [])
        let poller = OAuthPoller(client: client(org: key, fiveHour: 42), container: container,
                                 clock: TestClock(), switcherCache: { roster })
        await poller.stopPublishingScopeForTesting()
        let saves = SaveSpy(container)
        let accountPost = SignalProbe(name: AccountWriteSignal.name, sender: poller) {
            (onMainThread(), fiveHour(container, key))
        }
        let summaryPost = SignalProbe(name: .pacerScanCycleDidComplete, sender: nil, accept: {
            ($0.object as? ScanCycleSummary)?.rateLimitAccountId == key
        }) { (onMainThread(), samples(container, key)) }
        let generationBefore = await MainActor.run { RateLimitWriteSignal.shared.generation(of: key) }

        // A poll: lane meta read, the account and its reading, the lane meta.
        let outcome = await poller.runOnce()
        #expect(outcome == .success(fiveHourPct: 42, sevenDayPct: nil))
        #expect(samples(container, key) == 1 && laneMeta(container) == 1)
        let pollSaves = saves.seen.count
        #expect(pollSaves >= 2, "the poll's save and the lane meta's")
        #expect(accountPost.seen.first.map { !$0.0 && $0.1 == 42 } == true,
                "AccountWriteSignal posted by the poller, off main, after the row landed")
        try await waitFor { summaryPost.seen.count == 1 }
        #expect(summaryPost.seen.first.map { $0.0 && $0.1 == 1 } == true,
                "the summary is posted on main, after the reading it announces was saved")
        let generationAfter = await MainActor.run { RateLimitWriteSignal.shared.generation(of: key) }
        #expect(generationAfter > generationBefore, "RateLimitWriteSignal moved for this account")

        // The roster, a switch that creates its row, a rename.
        await poller.ingestSwitcherCacheNow()
        await poller.setActiveAccount(id: "acme-new", seed: Account.Seed(id: "acme-new", organizationId: "acme-new"),
                                      seenAt: nil)
        await poller.renameAccount(id: key, to: "Work")
        let rows = dump(container, seenTimes: false)
        #expect(rows.contains { $0.hasPrefix("account acme-roster ") })
        #expect(rows.contains { $0.hasPrefix("account acme-new ") && $0.contains(" active=true ") })
        #expect(rows.contains { $0.hasPrefix("account \(key) ") && $0.contains(" name=Work ") })
        #expect(saves.seen.count >= pollSaves + 4, "roster, activation, its lane meta, rename")
        #expect(saves.seen.allSatisfy { !$0 }, "no save on the main thread: \(saves.seen)")

        // The control: a save on main is seen as one.
        try await MainActor.run {
            let context = ModelContext(container)
            context.insert(ClaudeCodeMeta(key: "control-\(key)", value: "x"))
            try context.save()
        }
        #expect(saves.seen.last == true, "the watch sees a main-thread save")
    }
}

// MARK: - The poller's own queue (#445)

// The poller's executor is a serial dispatch queue of its own, so its blocking
// store work holds that queue's thread and not one of the cooperative pool's.
// These pin where that work runs, through the poller's real entry points, and
// that it still takes turns.
@Suite("OAuthPoller runs on a serial queue of its own (#445)")
struct OAuthPollerQueueTests {

    /// A poll, a roster ingest, a switch that creates its row and a rename.
    /// Every save (`ModelContext.didSave`, posted on the saving thread), every
    /// keychain read of discovery and every read of cswap's cache runs on the
    /// poller's queue: not on main, and not on a cooperative-pool thread. A
    /// control read from a plain task shows the label tells the two apart.
    @Test("Every save, keychain read and cswap cache read runs on the poller's queue")
    func storeWorkRunsOnThePollersQueue() async throws {
        let container = try makeContainer()
        let key = "acme-queue-\(UUID().uuidString.prefix(8))"
        let roster = SwitcherUsageCache.Contents(
            accounts: [.init(organizationId: "acme-queue-roster", emailAddress: "side@example.com", slot: 2)],
            readings: [])
        let keychainReads = QueueLog()
        let cacheReads = QueueLog()
        let poller = OAuthPoller(client: client(org: key, fiveHour: 42, onKeychainRead: keychainReads.note),
                                 container: container, clock: TestClock(),
                                 switcherCache: { cacheReads.note(); return roster })
        await poller.stopPublishingScopeForTesting()
        let saves = SaveQueueSpy(container)

        #expect(await poller.runOnce() == .success(fiveHourPct: 42, sevenDayPct: nil))
        await poller.ingestSwitcherCacheNow()
        await poller.setActiveAccount(id: "acme-queue-new",
                                      seed: Account.Seed(id: "acme-queue-new", organizationId: "acme-queue-new"),
                                      seenAt: nil)
        await poller.renameAccount(id: key, to: "Work")
        #expect(fiveHour(container, key) == 42 && laneMeta(container) == 1)

        let label = OAuthPoller.queueLabel
        #expect(saves.labels.count >= 6, "the poll and its lane meta, roster, activation and its lane meta, rename")
        #expect(saves.labels.allSatisfy { $0 == label }, "every save on the poller's queue: \(saves.labels)")
        #expect(!keychainReads.seen.isEmpty && keychainReads.seen.allSatisfy { $0 == label },
                "discovery's keychain reads: \(keychainReads.seen)")
        #expect(!cacheReads.seen.isEmpty && cacheReads.seen.allSatisfy { $0 == label },
                "cswap's cache reads: \(cacheReads.seen)")

        // The control: a task on the shared pool is on a cooperative queue.
        let pooled = await Task.detached { currentQueueLabel() }.value
        #expect(pooled != label && pooled.contains("cooperative"), "a pool thread reads as one: \(pooled)")
    }

    /// Polls and switcher ingests asked for all at once, with a transport that
    /// suspends so the polls overlap at their request. The actor is still
    /// serial: no two saves are ever in flight together, every one is on the
    /// poller's queue, cswap's reading lands once however many ingests read
    /// it, and each account is one row.
    @Test("Concurrent polls and switcher ingests still take turns, and a reading lands once")
    func concurrentCallsSerialize() async throws {
        let container = try makeContainer()
        let key = "acme-turns-\(UUID().uuidString.prefix(8))"
        let side = "acme-turns-side-\(UUID().uuidString.prefix(8))"
        let contents = SwitcherUsageCache.Contents(
            accounts: [.init(organizationId: side, emailAddress: "side@example.com", slot: 2)],
            readings: [SwitcherUsageCache.Reading(
                organizationId: side, fetchedAt: now.addingTimeInterval(-60), lastAttemptAt: nil,
                nextPollAt: nil, pollInterval: 600,
                fiveHour: .init(percent: 30, resetsAt: now.addingTimeInterval(3_600)),
                sevenDay: nil, scoped: [])])
        let poller = OAuthPoller(client: client(org: key, fiveHour: 42, requestDelay: .milliseconds(20)),
                                 container: container, clock: TestClock(), switcherCache: { contents })
        await poller.stopPublishingScopeForTesting()
        let saves = SaveQueueSpy(container)

        let rounds = 6
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<rounds {
                group.addTask { _ = await poller.runOnce() }
                group.addTask { await poller.ingestSwitcherCacheNow() }
            }
        }

        #expect(saves.deepest == 1, "two saves in flight at once: \(saves.deepest)")
        #expect(saves.labels.count >= rounds, "a save per poll at least")
        #expect(saves.labels.allSatisfy { $0 == OAuthPoller.queueLabel }, "\(saves.labels)")
        #expect(samples(container, side) == 1, "cswap's reading recorded once, not once per ingest")
        #expect(accountRows(container, key) == 1 && accountRows(container, side) == 1)
        #expect(fiveHour(container, key) == 42 && fiveHour(container, side) == 30)
        #expect(laneMeta(container) == 1)
    }
}

// MARK: - Scaffolding

/// The label of the dispatch queue the caller runs on. A job of the poller's
/// runs on `OAuthPoller.queueLabel`; a default actor's job, or any task on the
/// shared pool, on `com.apple.root.<class>-qos.cooperative`.
private func currentQueueLabel() -> String { String(cString: __dispatch_queue_get_label(nil)) }

/// The queue each call of `note` ran on, in order.
private final class QueueLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    @Sendable func note() {
        let label = currentQueueLabel()
        lock.withLock { values.append(label) }
    }

    var seen: [String] { lock.withLock { values } }
}

/// The queue each save of a context on `container` ran on, and the most saves
/// ever in flight at once (`willSave` to `didSave`, both posted on the saving
/// thread). One, if the saves take turns.
private final class SaveQueueSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [String] = []
    private var inFlight = 0
    private var maxInFlight = 0
    private var observers: [any NSObjectProtocol] = []

    init(_ container: ModelContainer) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ModelContext.willSave, object: nil, queue: nil) {
            [weak self] note in
            guard let self, (note.object as? ModelContext)?.container === container else { return }
            lock.withLock {
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
            }
        })
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
            [weak self] note in
            guard let self, (note.object as? ModelContext)?.container === container else { return }
            let label = currentQueueLabel()
            lock.withLock {
                inFlight -= 1
                saved.append(label)
            }
        })
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    var labels: [String] { lock.withLock { saved } }
    var deepest: Int { lock.withLock { maxInFlight } }
}

/// Whether each save of a context on `container` ran on the main thread, in
/// order. `ModelContext.didSave` is posted by the saving context, on the
/// thread that saved.
private final class SaveSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    private var observer: (any NSObjectProtocol)?

    init(_ container: ModelContainer) {
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil,
                                                          queue: nil) { [weak self] note in
            guard let context = note.object as? ModelContext, context.container === container else { return }
            let main = onMainThread()
            self?.lock.withLock { self?.values.append(main) }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var seen: [Bool] { lock.withLock { values } }
}

/// What `read` returned at each post of `name` from `sender` (any sender when
/// nil) that `accept` lets through, on the posting thread.
private final class SignalProbe<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    private var observer: (any NSObjectProtocol)?

    init(name: Notification.Name, sender: AnyObject?,
         accept: @escaping @Sendable (Notification) -> Bool = { _ in true },
         read: @escaping @Sendable () -> Value) {
        observer = NotificationCenter.default.addObserver(forName: name, object: sender, queue: nil) {
            [weak self] note in
            guard accept(note) else { return }
            let value = read()
            self?.lock.withLock { self?.values.append(value) }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var seen: [Value] { lock.withLock { values } }
}

private func waitFor(_ ready: @Sendable () -> Bool) async throws {
    for _ in 0..<500 {
        if ready() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out")
}

private func fiveHour(_ container: ModelContainer, _ id: String) -> Double? {
    let rows = (try? ModelContext(container).fetch(FetchDescriptor<Account>(
        predicate: #Predicate { $0.id == id }))) ?? []
    return rows.first?.latestFiveHourPct
}

private func samples(_ container: ModelContainer, _ account: String) -> Int {
    (try? ModelContext(container).fetchCount(FetchDescriptor<RateLimitSample>(
        predicate: #Predicate { $0.accountId == account }))) ?? 0
}

private func laneMeta(_ container: ModelContainer) -> Int {
    (try? ModelContext(container).fetchCount(FetchDescriptor<TokenLaneMeta>())) ?? 0
}

private func accountRows(_ container: ModelContainer, _ id: String) -> Int {
    (try? ModelContext(container).fetchCount(FetchDescriptor<Account>(
        predicate: #Predicate { $0.id == id }))) ?? 0
}

/// `onKeychainRead` is called on every read of the canned keychain item;
/// `requestDelay` makes each usage request suspend that long first.
private func client(org: String, fiveHour: Double,
                    onKeychainRead: @escaping @Sendable () -> Void = {},
                    requestDelay: Duration? = nil) -> OAuthClient {
    let blob = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
        "accessToken": "tok-429-\(org)",
        "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
    ]])
    let body = #"{"five_hour":{"utilization":\#(fiveHour),"resets_at":"2026-05-06T17:00:00Z"}}"#
    return OAuthClient(
        keychain: KeychainOAuth(rawReader: { onKeychainRead(); return .success(blob) }),
        transport: { _ in
            if let requestDelay { try await Task.sleep(for: requestDelay) }
            return try HTTPOutcome.success(jsonBody: body, headers: ["anthropic-organization-id": org]).materialize()
        },
        desktopEnabled: { false })
}
