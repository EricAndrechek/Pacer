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

    public init(
        container: ModelContainer,
        context: ModelContext,
        mode: CostMode = .auto,
        pricingTable: PricingTable = .shared
    ) {
        self.container = container
        self.context = context
        self.mode = mode
        self.pricingTable = pricingTable
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
    /// `AggregateRecomputer.recompute` for the design. SessionInfo's
    /// fast path has one extra constraint vs daily/hourly/project:
    /// `topModel` depends on per-model token totals, which aren't
    /// stored on the row, so it falls through whenever any pending
    /// sample's model differs from the existing row's `topModel`.
    /// Empty defaults preserve legacy "always full-recompute".
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
            if !isPolluted, !pendingForSid.isEmpty,
               try fastPathApply(sessionId: sid, pending: pendingForSid,
                                 snapshot: snapshot, stats: &stats) {
                continue
            }
            try recomputeOne(sessionId: sid, snapshot: snapshot, stats: &stats)
        }
        return stats
    }

    /// Incremental fast path for SessionInfo. Returns `true` only when
    /// the existing `SessionInfo` row exists AND every pending sample
    /// has the same model as `existing.topModel` — otherwise the
    /// per-model token ranking could shift and we can't recompute
    /// `topModel` from deltas alone (the row doesn't store per-model
    /// totals). On `false`, caller falls through to the full
    /// `recomputeOne` path that re-fetches every sample for the
    /// session.
    private func fastPathApply(
        sessionId: String,
        pending: [TokenSample],
        snapshot: PricingTable.Snapshot,
        stats: inout Stats
    ) throws -> Bool {
        let sid = sessionId
        let existing = try context.fetch(
            FetchDescriptor<SessionInfo>(
                predicate: #Predicate<SessionInfo> { $0.sessionId == sid }
            )
        ).first
        guard let existing else { return false }
        // Empty `topModel` would normally mean the row was never
        // populated; defer to full recompute to build it correctly.
        let topModel = existing.topModel
        guard !topModel.isEmpty else { return false }
        // If any pending sample uses a different model, fall through —
        // we can't tell whether the new model overtakes topModel
        // without the per-model totals the full path computes.
        for s in pending {
            if s.model != topModel { return false }
        }

        // With more than one account, take the full recompute instead.
        //
        // The account rows cannot be maintained incrementally the way the
        // global row can: `topModel` is chosen by comparing per-model totals,
        // and an account's top model may differ from the session's (one
        // account ran Opus, the other Sonnet), so the guard above proves
        // nothing about either account's row. Re-deriving them here from a
        // fetch was worse — that fetch does not see the cycle's *pending*
        // inserts, so the account rows sat exactly one batch behind the
        // global row. `verify-data` caught it at one session and $0.85.
        //
        // So the fast path is now conditional on there being one account,
        // which is almost every install: those keep it, and anyone running
        // two pays a full session recompute for correctness.
        if try context.fetchCount(FetchDescriptor<Account>()) > 1 { return false }

        for s in pending {
            existing.cumulativeInputTokens += s.breakdown.inputTokens
            existing.cumulativeOutputTokens += s.breakdown.outputTokens
            existing.cumulativeCacheReadTokens += s.breakdown.cacheReadTokens
            existing.cumulativeCacheCreation5mTokens += s.breakdown.cacheCreation5mTokens
            existing.cumulativeCacheCreation1hTokens += s.breakdown.cacheCreation1hTokens
            let breakdown = TokenBreakdown(
                inputTokens: s.breakdown.inputTokens,
                outputTokens: s.breakdown.outputTokens,
                cacheReadTokens: s.breakdown.cacheReadTokens,
                cacheCreation5mTokens: s.breakdown.cacheCreation5mTokens,
                cacheCreation1hTokens: s.breakdown.cacheCreation1hTokens
            )
            existing.cumulativeCostUSD += CostCalculator.cost(
                storedCostUSD: s.sourceCostUSD,
                model: s.model,
                breakdown: breakdown,
                mode: mode,
                snapshot: snapshot
            )
            if s.sampledAt < existing.firstSeenAt {
                existing.firstSeenAt = s.sampledAt
            }
            if s.sampledAt > existing.lastSeenAt {
                existing.lastSeenAt = s.sampledAt
                // Most-recent sample wins for path + cc version, same
                // as `applySamples`. Only overwrite when the new
                // sample actually carries the field — same fallback
                // rule the full path uses.
                if let path = s.projectPath {
                    existing.projectPath = path
                }
                if let ccVersion = s.ccVersion {
                    existing.ccVersion = ccVersion
                }
            }
        }
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
        try syncAccountSessionRows(
            context: context, sessionId: sid, samples: samples,
            mode: mode, snapshot: snapshot)
        Self.applySamples(
            sessionId: sid,
            samples: samples,
            existing: existing,
            mode: mode,
            snapshot: snapshot,
            insert: { context.insert($0) },
            delete: { context.delete($0) },
            stats: &stats
        )
    }

    fileprivate nonisolated static func applySamples<S: AggregatableSample>(
        sessionId: String,
        samples: [S],
        existing: SessionInfo?,
        mode: CostMode,
        snapshot: PricingTable.Snapshot,
        insert: (SessionInfo) -> Void,
        delete: (SessionInfo) -> Void,
        stats: inout Stats
    ) {
        if samples.isEmpty {
            if let existing {
                delete(existing)
                stats.sessionsDeleted += 1
            }
            return
        }

        var values = SessionRollupValues()
        for sample in samples { values.add(sample, mode: mode, snapshot: snapshot) }
        let path = values.projectPath ?? ""

        if let existing {
            existing.firstSeenAt = values.firstSeenAt
            existing.lastSeenAt = values.lastSeenAt
            existing.projectPath = path
            existing.ccVersion = values.ccVersion
            existing.cumulativeCostUSD = values.totalCostUSD
            existing.cumulativeInputTokens = values.inputTokens
            existing.cumulativeOutputTokens = values.outputTokens
            existing.cumulativeCacheReadTokens = values.cacheReadTokens
            existing.cumulativeCacheCreation5mTokens = values.cacheCreation5mTokens
            existing.cumulativeCacheCreation1hTokens = values.cacheCreation1hTokens
            existing.topModel = values.topModel
        } else {
            insert(SessionInfo(
                sessionId: sessionId,
                firstSeenAt: values.firstSeenAt,
                lastSeenAt: values.lastSeenAt,
                projectPath: path,
                ccVersion: values.ccVersion,
                cumulativeCostUSD: values.totalCostUSD,
                cumulativeInputTokens: values.inputTokens,
                cumulativeOutputTokens: values.outputTokens,
                cumulativeCacheReadTokens: values.cacheReadTokens,
                cumulativeCacheCreation5mTokens: values.cacheCreation5mTokens,
                cumulativeCacheCreation1hTokens: values.cacheCreation1hTokens,
                topModel: values.topModel
            ))
        }
        stats.sessionsUpserted += 1
    }
}

/// Bring `AccountSessionInfo` for one session in line with its samples.
///
/// A conversation that spans an account switch has real usage on both sides,
/// so this is a split rather than a partition: each row's `firstSeenAt` /
/// `lastSeenAt` are that account's first and last turns *within* the session.
func syncAccountSessionRows<S: AggregatableSample>(
    context: ModelContext,
    sessionId: String,
    samples: [S],
    mode: CostMode,
    snapshot: PricingTable.Snapshot
) throws {
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
        let path = values.projectPath ?? ""
        if let row = rows.removeValue(forKey: accountId) {
            row.firstSeenAt = values.firstSeenAt
            row.lastSeenAt = values.lastSeenAt
            row.projectPath = path
            row.ccVersion = values.ccVersion
            row.cumulativeCostUSD = values.totalCostUSD
            row.cumulativeInputTokens = values.inputTokens
            row.cumulativeOutputTokens = values.outputTokens
            row.cumulativeCacheReadTokens = values.cacheReadTokens
            row.cumulativeCacheCreation5mTokens = values.cacheCreation5mTokens
            row.cumulativeCacheCreation1hTokens = values.cacheCreation1hTokens
            row.topModel = values.topModel
        } else {
            context.insert(AccountSessionInfo(
                accountId: accountId, sessionId: sessionId,
                firstSeenAt: values.firstSeenAt, lastSeenAt: values.lastSeenAt,
                projectPath: path, ccVersion: values.ccVersion,
                cumulativeCostUSD: values.totalCostUSD,
                cumulativeInputTokens: values.inputTokens,
                cumulativeOutputTokens: values.outputTokens,
                cumulativeCacheReadTokens: values.cacheReadTokens,
                cumulativeCacheCreation5mTokens: values.cacheCreation5mTokens,
                cumulativeCacheCreation1hTokens: values.cacheCreation1hTokens,
                topModel: values.topModel))
        }
    }
    for orphan in rows.values { context.delete(orphan) }
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
