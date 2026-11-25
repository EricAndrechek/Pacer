import Foundation
import SwiftData
import Synchronization

// MARK: - The poller's store writes, off the main actor (#429)
//
// Every write the poller makes: `TokenLaneMeta`, the `Account` rows and fields
// a poll owns (readings, plan, `isActive`, the rows a poll, a switch or cswap's
// roster creates, a rename), and the rate-limit sample tables. These all ran in
// `MainActor.run` blocks, once per poll or more: a fetch of every lane-meta row
// and a save, the account by id, the two `latestSample` probes, the hourly
// eviction over three tables, every `Account` on a switch. Each is small, but
// under memory pressure any fetch can page the store back in, and on the main
// thread that is a stall of seconds (PACER-19, #413).
//
// So each is a `nonisolated static` function here, the shape #417 gave the
// poller's reads (`accountSummaries`, `isNewerThanStored`): a context of its
// own, Sendable values in and out, one synchronous section from the first
// fetch to the save. The poller calls them on its own executor and nowhere
// else, which makes it the one writer of these rows on the poll path. Its
// writes never race each other, and because each is synchronous, nothing else
// the poller does can interleave with one. The main actor gets only finished
// values: the signals, posted after the save has landed.
//
// The poller's executor is a serial dispatch queue of its own (#445,
// `OAuthPoller.queue`), so a section that blocks, a page-in under memory
// pressure, say, holds that queue's thread and not one of the cooperative
// pool's. Do not move a writer onto a detached task to get it off the poller:
// the writes would lose their order and the switcher ingest its atomicity.
//
// A context of its own reads and writes what is saved, which is all the
// main-actor versions did. They made a fresh context too; none of them used the
// main context. So a reader that refreshes on the signal sees the same rows it
// did before.
//
// `bin/lint-hang-patterns.sh` (`store-in-main-hop`) flags a context, fetch or
// save inside a hop to the main actor, so this shape cannot quietly come back.

extension OAuthPoller {

    // MARK: Lane metadata

    /// What the store holds for the lane pool, read once per launch.
    struct LoadedLaneMeta: Sendable {
        var meta: [String: LaneMetaSnapshot]
        var activeKey: String?
        var activeOrg: String?
        var metaPrimaryOrg: String?
    }

    /// Every persisted lane's metadata, and the account the store says is
    /// active. Pure reads.
    nonisolated static func readLaneMeta(container: ModelContainer) -> LoadedLaneMeta {
        let context = ModelContext(container)
        let rows = (try? context.fetch(FetchDescriptor<TokenLaneMeta>())) ?? []
        var map: [String: LaneMetaSnapshot] = [:]
        var metaPrimary: String?
        for r in rows {
            let account = OAuthPollScheduler.AccountStatus(rawValue: r.accountRaw)
            map[r.id] = LaneMetaSnapshot(
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
        // The active account is the source of truth for `activeAccountKey`.
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let active = accounts.first { $0.isActive }
        return LoadedLaneMeta(meta: map, activeKey: active?.id, activeOrg: active?.organizationId,
                              metaPrimaryOrg: metaPrimary)
    }

    /// Upsert every lane's metadata by fingerprint and delete the rows of
    /// tokens no longer in the pool. Returns whether the save landed.
    ///
    /// Fetches the whole table, as before: one row per token, a handful, and
    /// the rows to prune are exactly the ones no lane names.
    @discardableResult
    nonisolated static func writeLaneMeta(_ rows: [LaneMetaSnapshot], now: Date,
                                          container: ModelContainer) -> Bool {
        let keep = Set(rows.map(\.id))
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
        do {
            try context.save()
            return true
        } catch {
            Log.write("OAuthPoller", "lane-meta persist failed: \(error)")
            return false
        }
    }

    // MARK: Accounts

    /// What making an account active found and did. `saved` is whether a save
    /// with changes landed, which is when `AccountWriteSignal` is due.
    struct Activation: Sendable, Equatable {
        var organizationId: String?
        var created: Bool
        var changed: Bool
        var exists: Bool
        var saved: Bool
    }

    /// Flip `Account.isActive` to `incoming` alone, creating its row first from
    /// `seed` when there is one and the row is missing (`Account.ensure`), in
    /// one context and one save, so no reader sees the switch half-done.
    nonisolated static func writeActivation(_ incoming: String, seed: Account.Seed?,
                                            container: ModelContainer) -> Activation {
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
                saved = true
            } catch {
                Log.write("OAuthPoller", "could not save the active account: \(error)")
            }
        }
        return Activation(organizationId: incomingOrg, created: created, changed: changed,
                          exists: exists, saved: saved)
    }

    /// Create a row for each seed that has none (`Account.ensure`, create-only).
    /// Returns the ids created and whether a save landed; a failed save
    /// creates nothing.
    nonisolated static func writeRosterAccounts(
        _ seeds: [Account.Seed], container: ModelContainer
    ) -> (created: [String], saved: Bool) {
        let context = ModelContext(container)
        var made: [String] = []
        for seed in seeds where Account.ensure(seed, in: context).created {
            made.append(seed.id)
        }
        guard context.hasChanges else { return (made, false) }
        do {
            try context.save()
            return (made, true)
        } catch {
            Log.write("OAuthPoller", "could not save accounts from the switcher's roster: \(error)")
            return ([], false)
        }
    }

    /// Rename account `id`, or restore its derived name when `name` is blank.
    /// Returns whether the row exists (and so was written).
    ///
    /// Clearing the name restores the derived placeholder rather than leaving
    /// an empty string, because `Account.label` treats a blank name as absent
    /// and would fall through to the raw uuid.
    nonisolated static func writeAccountName(id: String, to name: String,
                                             container: ModelContainer) -> Bool {
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

    // MARK: One poll

    /// Everything one poll writes, decided before the write.
    struct PollRecord: Sendable {
        var snapshot: RateLimitSnapshot
        var accountKey: String
        var organizationId: String?
        var subscriptionType: String?
        var rateLimitTier: String?
        var isActive: Bool
        var laneSource: CredentialCandidate.Source
        var laneId: String?
        var source: String
        /// What this poll's plan changes, decided in memory (`observePlan`).
        var plan: AccountPlanState.Change?
        /// What the live meter showed just before the readings (#318).
        var measured: [LiveMeterDrift.Measurement]
        /// Whether this save also moves rows past `liveWindowDays` to the
        /// archive: the hourly gate (`evictionIsDue`), asked by the caller.
        var evictStaleRows: Bool
    }

    /// What `writePoll` did: whether its save landed, and whether it inserted
    /// any history rows (the scan-cycle summary is posted only then).
    struct PollWrite: Sendable, Equatable {
        var saved: Bool
        var wroteRows: Bool
    }

    /// Upsert the `Account` row (identity + cached latest readings for the
    /// switcher) and write the poll's history rows, stamped with the account,
    /// in one save.
    nonisolated static func writePoll(_ record: PollRecord, container: ModelContainer) -> PollWrite {
        let context = ModelContext(container)
        let captured = record.snapshot
        let organizationId = record.organizationId
        let subscriptionType = record.subscriptionType
        let isActive = record.isActive
        let laneSource = record.laneSource
        let laneId = record.laneId
        let source = record.source
        let measured = record.measured

        // --- Upsert the account + its cached latest readings ---
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
                rateLimitTier: record.rateLimitTier
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
            // A poll with a 7-day window and no 5-hour one means the
            // account has no 5-hour limit (verified Ultra, since
            // 2026-10-30) — not a failed read, which carries neither.
            // Keeping the last value showed a frozen "5h 87%" beside a
            // fresh poll time on every account surface.
            account.latestFiveHourPct = nil
            account.latestFiveHourResetsAt = nil
        }
        if let w = captured.sevenDay {
            account.latestSevenDayPct = w.usedPercentage
            account.latestSevenDayResetsAt = w.resetsAt
        }
        if let cents = captured.extraUsageCents { account.latestExtraUsageCents = cents }
        account.latestPolledAt = captured.sampledAt

        // --- History rows: every account, stamped ---
        //
        // This used to be `if isActive { live } else { archive }`, and the
        // swap in `setActiveAccount` moved rows between the two so the
        // live tables always held exactly one account. That kept every
        // read site free of accounts at the price of the other account's
        // pace chart not existing: 45,973 archived rows on this machine,
        // current to the minute, that nothing could draw.
        //
        // Now every account writes here and reads filter by `accountId`.
        // The archive keeps its second job — cold storage past
        // `liveWindowDays` — and `evictStaleLiveRows` still fills it.
        var wroteRows = false
        if let window = captured.fiveHour {
            logIfUsageWentDown(
                windowName: RateLimitWindowName.fiveHour,
                prior: latestSample(context, window: RateLimitWindowName.fiveHour, accountId: key),
                newUsed: window.usedPercentage,
                newReset: window.resetsAt,
                laneSource: laneSource
            )
            context.insert(RateLimitSample(
                sampledAt: captured.sampledAt,
                window: RateLimitWindowName.fiveHour,
                usedPercentage: window.usedPercentage,
                resetsAt: window.resetsAt,
                source: source,
                accountId: key,
                laneId: laneId
            ))
            wroteRows = true
        }
        if let window = captured.sevenDay {
            logIfUsageWentDown(
                windowName: RateLimitWindowName.sevenDay,
                prior: latestSample(context, window: RateLimitWindowName.sevenDay, accountId: key),
                newUsed: window.usedPercentage,
                newReset: window.resetsAt,
                laneSource: laneSource
            )
            context.insert(RateLimitSample(
                sampledAt: captured.sampledAt,
                window: RateLimitWindowName.sevenDay,
                usedPercentage: window.usedPercentage,
                resetsAt: window.resetsAt,
                source: source,
                accountId: key,
                laneId: laneId
            ))
            wroteRows = true
        }
        // Extra-usage is account-level (not per-window); write at
        // most one row per snapshot when present. nil means the
        // field was omitted — leave the prior row rather than
        // overwrite with a phantom zero.
        if let cents = captured.extraUsageCents {
            context.insert(ExtraUsageSample(
                sampledAt: captured.sampledAt,
                amountCents: cents,
                source: source,
                accountId: key
            ))
            wroteRows = true
        }
        // The scoped `limits[]` representation (per-model weekly
        // windows, severity, binding flag). One generic row per item,
        // all stamped with the same `sampledAt` so the dashboard reads
        // them back as one "latest batch" — a limit dropped from the
        // response simply stops appearing. Keyed by a stable composite
        // identity, so new models/kinds persist with no schema change.
        // Two accounts that share a model identity (e.g. both have a
        // "Fable" weekly) keep separate scoped history via `accountId`.
        for limit in captured.limits {
            context.insert(UsageLimitSample(
                from: limit,
                sampledAt: captured.sampledAt,
                source: source,
                accountId: key,
                laneId: laneId
            ))
            wroteRows = true
        }
        // One row per window the live meter had a value for, beside its
        // reading. An insert each and nothing read: `measured` was built
        // before this write.
        if !measured.isEmpty, LiveMeterOutcome.isRegistered(in: context) {
            for row in LiveMeterOutcome.rows(account: key, measurements: measured) { context.insert(row) }
        }
        if record.evictStaleRows {
            let moved = evictStaleLiveRows(context: context, accountId: key)
            if moved > 0 {
                Log.write("OAuthPoller",
                          "evicted \(moved) live row(s) older than \(Int(liveWindowDays))d to the archive")
            }
        }
        do {
            try context.save()
            return PollWrite(saved: true, wroteRows: wroteRows)
        } catch {
            Log.write("OAuthPoller", "persist failed: \(error)")
            return PollWrite(saved: false, wroteRows: wroteRows)
        }
    }

    // MARK: Non-monotonic usage diagnostics

    /// Most recent persisted OAuth sample for one account's window (or nil).
    ///
    /// Scoped by account because the live table holds every account's rows.
    /// Unscoped, "the previous reading" would routinely be a *different*
    /// account's, and the non-monotonic diagnostic would fire on every poll
    /// that happened to interleave two logins.
    private static func latestSample(_ context: ModelContext, window: String,
                                     accountId: String) -> RateLimitSample? {
        var d = FetchDescriptor<RateLimitSample>(
            predicate: #Predicate {
                $0.window == window && $0.source == "oauth" && $0.accountId == accountId
            },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// Log when a window's utilization *decreases* for a reason that
    /// isn't one of the two resets we already recognize — i.e. a small
    /// within-window wobble, the kind a lagging backend replica (possibly
    /// surfaced by interleaving tokens) could produce. Purely diagnostic:
    /// one grep-able line, no behavior change. We deliberately do NOT log:
    ///   - a normal rollover — `resets_at` advanced past the prior anchor;
    ///   - an off-schedule global reset — a collapse from a meaningful
    ///     level to ~0 (handled by `GlobalRateLimitReset`).
    private static func logIfUsageWentDown(
        windowName: String,
        prior: RateLimitSample?,
        newUsed: Double,
        newReset: Date?,
        laneSource: CredentialCandidate.Source
    ) {
        guard let prior else { return }
        let priorUsed = prior.usedPercentage
        guard newUsed < priorUsed - 0.01 else { return }   // not a decrease

        // Rollover: the window advanced to a later reset anchor.
        let rolloverTolerance: TimeInterval = 10 * 60
        if let pr = prior.resetsAt, let nr = newReset, nr.timeIntervalSince(pr) > rolloverTolerance {
            return
        }
        // Off-schedule global reset: collapse to ~0 on an unchanged anchor.
        if priorUsed > 5, newUsed < 1 { return }

        let anchor: String
        if let pr = prior.resetsAt, let nr = newReset {
            let drift = Int(nr.timeIntervalSince(pr).rounded())
            anchor = drift == 0 ? "resets_at unchanged" : "resets_at drift \(drift)s"
        } else {
            anchor = "resets_at nil"
        }
        Log.write("OAuthPoller", String(
            format: "usage DECREASED (non-reset): %@ %.1f%%→%.1f%% via %@ token; %@ — likely backend replica lag",
            windowName, priorUsed, newUsed, laneSource.rawValue, anchor
        ))
    }

    // MARK: Eviction

    /// Test seam for the eviction pass — it is the one piece of the swap
    /// whose correctness is "nothing was lost", which is worth asserting
    /// directly rather than through a full poll cycle.
    static func testEvictStaleLiveRows(context: ModelContext, accountId: String) -> Int {
        evictStaleLiveRows(context: context, accountId: accountId)
    }

    /// When eviction last ran. In-memory only: re-running once after a
    /// restart costs one bounded pass and saves persisting a timestamp
    /// nothing else needs. Behind a lock now that polls write off the main
    /// actor: a test process runs many pollers at once.
    private static let lastEvictionAt = Mutex<Date?>(nil)

    static func evictionIsDue(now: Date) -> Bool {
        lastEvictionAt.withLock { last in
            guard let previous = last else {
                last = now
                return true
            }
            guard now.timeIntervalSince(previous) >= 3600 else { return false }
            last = now
            return true
        }
    }

    /// Move the active account's live rows older than the window into the
    /// archive, so the live tables stay a bounded cache.
    ///
    /// Without this the bound only applies on a switch, and a single-account
    /// user — who never switches — accumulates live rows forever. That is
    /// exactly how this machine reached 90,200 live rate-limit rows: nothing
    /// was ever wrong, they simply never left.
    ///
    /// Eviction, not deletion. Every row is written to the archive before it
    /// is removed, and the archive is never pruned.
    private static func evictStaleLiveRows(context: ModelContext, accountId: String) -> Int {
        let cutoff = Date().addingTimeInterval(-liveWindowDays * 86_400)
        var moved = 0

        let rls = (try? context.fetch(FetchDescriptor<RateLimitSample>(
            predicate: #Predicate { $0.sampledAt < cutoff }))) ?? []
        for r in rls {
            context.insert(AccountUsageArchive(
                accountId: r.accountId ?? accountId,
                kind: AccountUsageArchive.kindRateLimit,
                sampledAt: r.sampledAt, window: r.window,
                usedPercentage: r.usedPercentage, resetsAt: r.resetsAt,
                source: r.source, laneId: r.laneId))
            context.delete(r)
            moved += 1
        }

        let extras = (try? context.fetch(FetchDescriptor<ExtraUsageSample>(
            predicate: #Predicate { $0.sampledAt < cutoff }))) ?? []
        for e in extras {
            context.insert(AccountUsageArchive(
                accountId: e.accountId ?? accountId,
                kind: AccountUsageArchive.kindExtraUsage,
                sampledAt: e.sampledAt, amountCents: e.amountCents,
                source: e.source))
            context.delete(e)
            moved += 1
        }

        let limits = (try? context.fetch(FetchDescriptor<UsageLimitSample>(
            predicate: #Predicate { $0.sampledAt < cutoff }))) ?? []
        for l in limits {
            context.insert(AccountUsageArchive(
                accountId: l.accountId ?? accountId,
                kind: AccountUsageArchive.kindUsageLimit,
                sampledAt: l.sampledAt, usedPercentage: l.percent,
                resetsAt: l.resetsAt, source: l.source,
                identity: l.identity, limitKind: l.kind, group: l.group,
                label: l.label, severity: l.severity, isActive: l.isActive,
                modelId: l.modelId, modelDisplayName: l.modelDisplayName,
                surface: l.surface, laneId: l.laneId))
            context.delete(l)
            moved += 1
        }
        return moved
    }
}
