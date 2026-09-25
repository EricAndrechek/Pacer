import Foundation
import SwiftData

/// Materializes `SessionInfo` rows from the underlying `TokenSample`
/// table. Recomputes per-session — never the whole table. Counterpart
/// to `AggregateRecomputer` and `ProjectAggregateRecomputer`: same
/// dirty-set pattern, keyed by `sessionId` rather than `(date, model)`
/// or `(project, date)`.
///
/// Maintaining this rollup is what lets `ProjectDetailView` display
/// the sessions list instantly. Without it, the detail view had to
/// drop into a `RollupWorker` and iterate every TokenSample for the
/// project on each scan tick — measurable lag on a populated install.
@ScanActor
public final class SessionInfoRecomputer {

    private let container: ModelContainer
    private let context: ModelContext
    private let mode: CostMode
    private let pricingTable: PricingTable
    private let cache: SessionRollupCache

    /// `cache` should outlive the recomputer — `ScanCoordinator` holds one for
    /// the life of the scan loop. The default (a fresh, empty cache) is
    /// correct, just slow: every session takes the full path once.
    public init(
        container: ModelContainer,
        context: ModelContext,
        mode: CostMode = .auto,
        pricingTable: PricingTable = .shared,
        cache: SessionRollupCache = SessionRollupCache()
    ) {
        self.container = container
        self.context = context
        self.mode = mode
        self.pricingTable = pricingTable
        self.cache = cache
    }

    public struct Stats: Sendable {
        public var sessionsRecomputed: Int
        public var sessionsUpserted: Int
        public var sessionsDeleted: Int
        /// Mirror of `AggregateRecomputer.Stats.fastPathApplied` — see
        /// that doc for the diagnostic intent.
        public var fastPathApplied: Int = 0
    }

    /// Above this many dirty session ids we hand off to a background
    /// `@ModelActor` worker. Backfill on first install can produce
    /// hundreds-thousands of dirty ids; normal incremental scans
    /// produce a handful and stay on the main context.
    private static let bulkRecomputeThreshold = 64

    /// Recompute dirty sessions. `pending` and `polluted` opt the
    /// per-session path into the incremental fast path — see
    /// `AggregateRecomputer.recompute` for the design, and `fastPathApply`
    /// for why this one needs `SessionRollupCache`. Empty defaults preserve
    /// legacy "always full-recompute".
    @discardableResult
    public func recompute(
        sessionIds: Set<String>,
        snapshots: SampleSnapshotCache? = nil,
        pending: [String: [TokenSample]] = [:],
        polluted: Set<String> = []
    ) async throws -> Stats {
        var stats = Stats(sessionsRecomputed: 0, sessionsUpserted: 0, sessionsDeleted: 0)
        if sessionIds.isEmpty { return stats }
        // Sync pricing snapshot via `SampleCostCache.current()` for the
        // per-session path — matches the same change in
        // `AggregateRecomputer.recompute`. The bulk path below still
        // awaits because it runs off-MainActor (no contention).
        let snapshot: PricingTable.Snapshot = (mode == .display)
            ? PricingTable.Snapshot(pricingByModel: [:])
            : SampleCostCache.current()
        if sessionIds.count >= Self.bulkRecomputeThreshold {
            // The bulk worker writes these rows from another context and
            // does not seed the cache, so what the cache holds for them is
            // about to be out of date.
            cache.forget(sessionIds)
            try context.save()
            let worker = SessionInfoBulkWorker(modelContainer: container)
            return try await worker.bulkRecompute(
                sessionIds: sessionIds, mode: mode, snapshot: snapshot,
                snapshots: snapshots ?? SampleSnapshotCache(container: container))
        }
        for sid in sessionIds {
            stats.sessionsRecomputed += 1
            let pendingForSid = pending[sid] ?? []
            let isPolluted = polluted.contains(sid)
            if isPolluted { cache.forget([sid]) }
            if !isPolluted, !pendingForSid.isEmpty,
               try fastPathApply(sessionId: sid, pending: pendingForSid,
                                 snapshot: snapshot, stats: &stats) {
                continue
            }
            try recomputeOne(sessionId: sid, snapshot: snapshot, stats: &stats)
        }
        return stats
    }

    /// Incremental fast path for SessionInfo and its per-account rows.
    ///
    /// `topModel` is chosen by comparing per-model totals, which the rows do
    /// not store, so the rows alone cannot be advanced by a delta: a Sonnet
    /// subagent's turns inside an Opus session might or might not overtake it.
    /// This used to fall through to the full path whenever a pending sample's
    /// model differed from the row's, and — since multi-account — whenever
    /// more than one account existed at all. Together that meant nearly every
    /// cycle re-fetched every sample of every active session: 1–2 s per cycle
    /// on long sessions, holding the store while the UI waited on it.
    ///
    /// So the complete `SessionRollupValues` behind each row are kept in
    /// `SessionRollupCache`, seeded by the full path. Here the pending samples
    /// are added to those values and the rows rewritten from them — the same
    /// `SessionRollupValues.add` and the same writers the full path uses, so
    /// the two paths cannot disagree. No cache entry (first touch since
    /// launch, or just polluted) means the full path, which seeds one.
    private func fastPathApply(
        sessionId: String,
        pending: [TokenSample],
        snapshot: PricingTable.Snapshot,
        stats: inout Stats
    ) throws -> Bool {
        let sid = sessionId
        guard var values = cache.values(for: sid) else { return false }
        let existing = try context.fetch(
            FetchDescriptor<SessionInfo>(
                predicate: #Predicate<SessionInfo> { $0.sessionId == sid }
            )
        ).first
        guard let existing else { return false }

        for s in pending {
            values.global.add(s, mode: mode, snapshot: snapshot)
            let key = s.accountId ?? AccountDailyAggregate.unattributedKey
            values.byAccount[key, default: SessionRollupValues()]
                .add(s, mode: mode, snapshot: snapshot)
        }

        let accountRows = try context.fetch(
            FetchDescriptor<AccountSessionInfo>(
                predicate: #Predicate<AccountSessionInfo> { $0.sessionId == sid }
            )
        )
        var rowsByAccount: [String: AccountSessionInfo] = [:]
        for row in accountRows { rowsByAccount[row.accountId] = row }
        let touched = Set(pending.map { $0.accountId ?? AccountDailyAggregate.unattributedKey })
        for key in touched {
            guard let accountValues = values.byAccount[key] else { continue }
            if let row = rowsByAccount[key] {
                accountValues.write(to: row)
            } else {
                context.insert(accountValues.makeAccountRow(accountId: key, sessionId: sid))
            }
        }
        values.global.write(to: existing)
        cache.store(values, for: sid)

        stats.sessionsUpserted += 1
        stats.fastPathApplied += 1
        return true
    }

    private func recomputeOne(
        sessionId: String,
        snapshot: PricingTable.Snapshot,
        stats: inout Stats
    ) throws {
        let sid = sessionId
        let samples = try context.fetch(
            FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> { $0.sessionId == sid }
            )
        )
        let existing = try context.fetch(
            FetchDescriptor<SessionInfo>(
                predicate: #Predicate<SessionInfo> { $0.sessionId == sid }
            )
        ).first
        let byAccount = try syncAccountSessionRows(
            context: context, sessionId: sid, samples: samples,
            mode: mode, snapshot: snapshot)
        let global = Self.applySamples(
            sessionId: sid,
            samples: samples,
            existing: existing,
            mode: mode,
            snapshot: snapshot,
            insert: { context.insert($0) },
            delete: { context.delete($0) },
            stats: &stats
        )
        if let global {
            cache.store(SessionRollupCache.Values(global: global, byAccount: byAccount),
                        for: sid, rebuiltAt: Date())
        } else {
            cache.forget([sid])
        }
    }

    /// Returns the values the row was written from, or nil when the session
    /// has no samples (and its row, if any, was deleted).
    @discardableResult
    fileprivate nonisolated static func applySamples<S: AggregatableSample>(
        sessionId: String,
        samples: [S],
        existing: SessionInfo?,
        mode: CostMode,
        snapshot: PricingTable.Snapshot,
        insert: (SessionInfo) -> Void,
        delete: (SessionInfo) -> Void,
        stats: inout Stats
    ) -> SessionRollupValues? {
        if samples.isEmpty {
            if let existing {
                delete(existing)
                stats.sessionsDeleted += 1
            }
            return nil
        }

        var values = SessionRollupValues()
        for sample in samples { values.add(sample, mode: mode, snapshot: snapshot) }

        if let existing {
            values.write(to: existing)
        } else {
            insert(values.makeSessionRow(sessionId: sessionId))
        }
        stats.sessionsUpserted += 1
        return values
    }
}

/// Bring `AccountSessionInfo` for one session in line with its samples.
///
/// A conversation that spans an account switch has real usage on both sides,
/// so this is a split rather than a partition: each row's `firstSeenAt` /
/// `lastSeenAt` are that account's first and last turns *within* the session.
/// Returns the per-account values the rows were written from.
@discardableResult
func syncAccountSessionRows<S: AggregatableSample>(
    context: ModelContext,
    sessionId: String,
    samples: [S],
    mode: CostMode,
    snapshot: PricingTable.Snapshot
) throws -> [String: SessionRollupValues] {
    var byAccount: [String: SessionRollupValues] = [:]
    for sample in samples {
        let key = sample.accountId ?? AccountDailyAggregate.unattributedKey
        var values = byAccount[key] ?? SessionRollupValues()
        values.add(sample, mode: mode, snapshot: snapshot)
        byAccount[key] = values
    }

    let sid = sessionId
    let existing = try context.fetch(
        FetchDescriptor<AccountSessionInfo>(
            predicate: #Predicate<AccountSessionInfo> { $0.sessionId == sid }
        )
    )
    var rows: [String: AccountSessionInfo] = [:]
    for row in existing { rows[row.accountId] = row }

    for (accountId, values) in byAccount {
        if let row = rows.removeValue(forKey: accountId) {
            values.write(to: row)
        } else {
            context.insert(values.makeAccountRow(accountId: accountId, sessionId: sessionId))
        }
    }
    for orphan in rows.values { context.delete(orphan) }
    return byAccount
}

/// The complete `SessionRollupValues` behind recently touched session rows,
/// so the fast path can advance `topModel` exactly (see
/// `SessionInfoRecomputer.fastPathApply`).
///
/// In memory only, and only ever filled from a full recompute of the session,
/// so it is exactly what the committed rows were written from. Anything that
/// changes a session's samples other than a plain insert — a streamed turn's
/// upgrade, a re-attribution, an alias merge, a cost-mode change — marks the
/// session polluted, which drops its entry here before the full path runs.
/// Bounded by the sessions touched since launch; a few hundred small values.
@ScanActor
public final class SessionRollupCache {
    struct Values {
        var global: SessionRollupValues
        var byAccount: [String: SessionRollupValues]
    }

    private var entries: [String: Values] = [:]
    /// When each entry stops being trusted. Set only when the entry is built
    /// from the session's samples (the full path); the fast path advancing it
    /// does not extend it.
    private var expiresAt: [String: Date] = [:]

    /// The longest a cached entry is advanced by deltas before the session is
    /// rebuilt from its samples again: a hard bound on how long any drift in a
    /// cached total can last, the same on every machine whatever the number
    /// of active sessions. Price changes, rewritten samples and failed cycles
    /// already reset entries immediately; this bounds whatever has no name.
    ///
    /// Expiry, not a sweep. A sweep (every active session rebuilt each
    /// ten-minute pass) measured a 3.3-4.3 s scan every ten minutes on a real
    /// store. A one-session rotation fixed the cost but made the bound depend
    /// on how many sessions were active. An entry that expires is simply not
    /// used, so the session takes the full path on its next turn: at most
    /// one rebuild per session per `maxAge`, at the moment it is touched.
    static let maxAge: TimeInterval = 30 * 60
    /// Each entry's age is spread over ±`maxAgeJitter` so sessions first seen
    /// together (every active session right after launch) don't all expire in
    /// the same scan and bring the sweep's burst back.
    static let maxAgeJitter: TimeInterval = 5 * 60

    public nonisolated init() {}

    /// The cached values, or nil when there are none or they have expired.
    func values(for sessionId: String, now: Date = Date()) -> Values? {
        guard let expiry = expiresAt[sessionId], now < expiry else { return nil }
        return entries[sessionId]
    }
    /// `rebuiltAt` is non-nil when `values` came from the samples themselves
    /// (the full path), which starts a new expiry window.
    func store(_ values: Values, for sessionId: String, rebuiltAt: Date? = nil) {
        entries[sessionId] = values
        if let rebuiltAt {
            let jitter = Double.random(in: -Self.maxAgeJitter...Self.maxAgeJitter)
            expiresAt[sessionId] = rebuiltAt.addingTimeInterval(Self.maxAge + jitter)
        }
    }
    func forget(_ sessionIds: Set<String>) {
        for sid in sessionIds {
            entries[sid] = nil
            expiresAt[sid] = nil
        }
    }
    func forgetAll() {
        entries.removeAll()
        expiresAt.removeAll()
    }

    /// The `SampleCostCache.generation` the entries were priced under.
    private var pricingGeneration: UInt64?

    /// Forget every entry if prices changed since the last call. Each cached
    /// `totalCostUSD` bakes in the snapshot it was built from, and the fast
    /// path only ever adds to it, so a price change would otherwise never
    /// reach a session that stays active. Forgetting (rather than rebuilding)
    /// keeps it cheap: each session takes the full path on its next touch.
    /// Returns whether anything was forgotten.
    @discardableResult
    func forgetAllIfPricingChanged(generation: UInt64) -> Bool {
        guard pricingGeneration != generation else { return false }
        pricingGeneration = generation
        let hadEntries = !entries.isEmpty
        entries.removeAll()
        expiresAt.removeAll()
        return hadEntries
    }

    var count: Int { entries.count }
}

extension SessionRollupValues {
    func write(to row: SessionInfo) {
        row.firstSeenAt = firstSeenAt
        row.lastSeenAt = lastSeenAt
        row.projectPath = projectPath ?? ""
        row.ccVersion = ccVersion
        row.cumulativeCostUSD = totalCostUSD
        row.cumulativeInputTokens = inputTokens
        row.cumulativeOutputTokens = outputTokens
        row.cumulativeCacheReadTokens = cacheReadTokens
        row.cumulativeCacheCreation5mTokens = cacheCreation5mTokens
        row.cumulativeCacheCreation1hTokens = cacheCreation1hTokens
        row.topModel = topModel
    }

    func write(to row: AccountSessionInfo) {
        row.firstSeenAt = firstSeenAt
        row.lastSeenAt = lastSeenAt
        row.projectPath = projectPath ?? ""
        row.ccVersion = ccVersion
        row.cumulativeCostUSD = totalCostUSD
        row.cumulativeInputTokens = inputTokens
        row.cumulativeOutputTokens = outputTokens
        row.cumulativeCacheReadTokens = cacheReadTokens
        row.cumulativeCacheCreation5mTokens = cacheCreation5mTokens
        row.cumulativeCacheCreation1hTokens = cacheCreation1hTokens
        row.topModel = topModel
    }

    func makeSessionRow(sessionId: String) -> SessionInfo {
        SessionInfo(
            sessionId: sessionId,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            projectPath: projectPath ?? "",
            ccVersion: ccVersion,
            cumulativeCostUSD: totalCostUSD,
            cumulativeInputTokens: inputTokens,
            cumulativeOutputTokens: outputTokens,
            cumulativeCacheReadTokens: cacheReadTokens,
            cumulativeCacheCreation5mTokens: cacheCreation5mTokens,
            cumulativeCacheCreation1hTokens: cacheCreation1hTokens,
            topModel: topModel)
    }

    func makeAccountRow(accountId: String, sessionId: String) -> AccountSessionInfo {
        AccountSessionInfo(
            accountId: accountId, sessionId: sessionId,
            firstSeenAt: firstSeenAt, lastSeenAt: lastSeenAt,
            projectPath: projectPath ?? "", ccVersion: ccVersion,
            cumulativeCostUSD: totalCostUSD,
            cumulativeInputTokens: inputTokens,
            cumulativeOutputTokens: outputTokens,
            cumulativeCacheReadTokens: cacheReadTokens,
            cumulativeCacheCreation5mTokens: cacheCreation5mTokens,
            cumulativeCacheCreation1hTokens: cacheCreation1hTokens,
            topModel: topModel)
    }
}

/// Off-main bulk recompute path for SessionInfo. Owns its own
/// `ModelContext` via `@ModelActor`. Same shape as
/// `ProjectAggregateBulkWorker`.
@ModelActor
actor SessionInfoBulkWorker {

    private static let yieldInterval = 32

    func bulkRecompute(
        sessionIds: Set<String>,
        mode: CostMode,
        snapshot: PricingTable.Snapshot,
        snapshots: SampleSnapshotCache
    ) async throws -> SessionInfoRecomputer.Stats {
        var stats = SessionInfoRecomputer.Stats(
            sessionsRecomputed: 0, sessionsUpserted: 0, sessionsDeleted: 0)

        // Shared with the daily/hourly/project workers — see SampleSnapshot.
        var grouped: [String: [SampleSnapshot.Row]] = [:]
        for s in try snapshots.snapshot().rows {
            guard let sid = s.sessionId, !sid.isEmpty else { continue }
            grouped[sid, default: []].append(s)
        }
        let existingAll = try modelContext.fetch(FetchDescriptor<SessionInfo>())
        var existingById: [String: SessionInfo] = [:]
        for row in existingAll { existingById[row.sessionId] = row }

        var processed = 0
        for sid in sessionIds {
            stats.sessionsRecomputed += 1
            try syncAccountSessionRows(
                context: modelContext, sessionId: sid, samples: grouped[sid] ?? [],
                mode: mode, snapshot: snapshot)
            SessionInfoRecomputer.applySamples(
                sessionId: sid,
                samples: grouped[sid] ?? [],
                existing: existingById[sid],
                mode: mode,
                snapshot: snapshot,
                insert: { modelContext.insert($0) },
                delete: { modelContext.delete($0) },
                stats: &stats
            )
            processed += 1
            if processed.isMultiple(of: Self.yieldInterval) {
                await Task.yield()
            }
        }

        try modelContext.save()
        return stats
    }
}
