import Foundation
import SwiftData

/// Materializes `ProjectDailyAggregate` rows from underlying
/// `TokenSample` rows. Recomputes per `(projectPath, date)` bucket —
/// never the whole table. The `SamplePersister` tracks which buckets
/// got dirtied during a scan and the coordinator hands that set here.
///
/// Counterpart to `AggregateRecomputer`: same bucket-recompute shape,
/// but keyed by project rather than model. Together they keep the
/// view-side rollups instant — Projects view reads
/// `ProjectDailyAggregate` directly, no per-sample iteration.
@ScanActor
public final class ProjectAggregateRecomputer {

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
        public var pairsRecomputed: Int
        public var aggregatesUpserted: Int
        public var aggregatesDeleted: Int
        /// Mirror of `AggregateRecomputer.Stats.fastPathApplied`. See
        /// that doc for the diagnostic intent.
        public var fastPathApplied: Int = 0
    }

    /// Above this many dirty pairs we hand off to a background
    /// `@ModelActor` worker so the recompute doesn't block MainActor.
    /// Backfill (always thousands of pairs) takes the bulk path; normal
    /// incremental scans (≤ a couple dozen pairs) stay on the per-pair
    /// main-context path where the predicate-filtered fetches are
    /// cheap and visibility of in-flight inserts is free.
    private static let bulkRecomputeThreshold = 64

    /// Recompute dirty `(projectPath, date)` pairs. `pending` and
    /// `polluted` opt into the incremental fast path — see
    /// `AggregateRecomputer.recompute` for the design. Empty defaults
    /// preserve legacy behavior.
    @discardableResult
    public func recompute(
        pairs: Set<ProjectDatePair>,
        pending: [ProjectDatePair: [TokenSample]] = [:],
        polluted: Set<ProjectDatePair> = [],
        snapshots: SampleSnapshotCache? = nil
    ) async throws -> Stats {
        var stats = Stats(pairsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)
        if pairs.isEmpty { return stats }
        // Sync pricing snapshot via `SampleCostCache.current()` for the
        // per-pair path (covers both the legacy full recompute and the
        // new fast path). Swapping out the awaited `pricingTable`
        // lookup here removes ~150 ms of MainActor-contended actor
        // hop from every cycle — see same comment in
        // `AggregateRecomputer.recompute`. The bulk path below still
        // awaits because the bulk worker runs off-MainActor and the
        // cost is amortized across thousands of pairs.
        let snapshot: PricingTable.Snapshot = (mode == .display)
            ? PricingTable.Snapshot(pricingByModel: [:])
            : SampleCostCache.current()
        if pairs.count >= Self.bulkRecomputeThreshold {
            // See AggregateRecomputer — commit any pending main-context
            // inserts so the background worker's separate context can
            // see them.
            try context.save()
            let worker = ProjectAggregateBulkWorker(modelContainer: container)
            return try await worker.bulkRecompute(
                pairs: pairs, mode: mode, snapshot: snapshot,
                snapshots: snapshots ?? SampleSnapshotCache(container: container))
        }
        for pair in pairs {
            stats.pairsRecomputed += 1
            let pendingForPair = pending[pair] ?? []
            let isPolluted = polluted.contains(pair)
            if !isPolluted, !pendingForPair.isEmpty,
               try fastPathApply(pair: pair, pending: pendingForPair,
                                 snapshot: snapshot, stats: &stats) {
                continue
            }
            try recomputeOne(pair: pair, snapshot: snapshot, stats: &stats)
        }
        // No save here — see comment in `AggregateRecomputer.recompute`.
        return stats
    }

    /// Incremental fast path for the project rollup. Unlike the
    /// daily/hourly rollups, this one carries denormalized session +
    /// per-model JSON columns, so the fast path has to decode them,
    /// union the pending samples' contributions in memory, and
    /// re-encode. Even with the round-trip, the savings vs fetching
    /// every TokenSample for the pair (~100ms on a populated bucket)
    /// are large — single-ms typical case once decoded.
    private func fastPathApply(
        pair: ProjectDatePair,
        pending: [TokenSample],
        snapshot: PricingTable.Snapshot,
        stats: inout Stats
    ) throws -> Bool {
        let key = ProjectDailyAggregate.makeKey(
            projectPath: pair.projectPath, date: pair.date)
        let existing = try context.fetch(
            FetchDescriptor<ProjectDailyAggregate>(
                predicate: #Predicate<ProjectDailyAggregate> { $0.projectDateKey == key }
            )
        ).first
        guard let existing else { return false }

        // Hydrate the running totals from the stored row, fold the new
        // samples in, write back. `ProjectRollupValues` owns the
        // decode-merge-encode so the global and per-account rollups share it
        // rather than keeping two copies that can disagree about, say, how a
        // corrupt JSON blob is treated.
        var values = ProjectRollupValues(hydrating: existing)
        for sample in pending { values.add(sample, mode: mode, snapshot: snapshot) }
        values.write(to: existing)

        // The same increment, per account. Rows are keyed by account so a
        // bucket's accounts are maintained independently.
        var perAccount: [String: [TokenSample]] = [:]
        for sample in pending {
            perAccount[sample.accountId ?? AccountDailyAggregate.unattributedKey,
                       default: []].append(sample)
        }
        for (accountId, samples) in perAccount {
            let accountKey = AccountProjectDailyAggregate.makeKey(
                accountId: accountId, projectPath: pair.projectPath, date: pair.date)
            let row = try context.fetch(
                FetchDescriptor<AccountProjectDailyAggregate>(
                    predicate: #Predicate<AccountProjectDailyAggregate> {
                        $0.accountProjectDateKey == accountKey
                    }
                )
            ).first
            var accountValues = row.map { ProjectRollupValues(hydrating: $0) }
                ?? ProjectRollupValues()
            for sample in samples {
                accountValues.add(sample, mode: mode, snapshot: snapshot)
            }
            if let row {
                accountValues.write(to: row)
            } else {
                let fresh = AccountProjectDailyAggregate(
                    accountId: accountId, projectPath: pair.projectPath, date: pair.date,
                    inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                    cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                    totalCostUSD: 0, sessionCount: 0, modelCount: 0,
                    lastActive: .distantPast, sessionIdsJSON: Data(),
                    modelTokensJSON: Data(), modelCostJSON: Data())
                accountValues.write(to: fresh)
                context.insert(fresh)
            }
        }

        stats.aggregatesUpserted += 1
        stats.fastPathApplied += 1
        return true
    }

    private func recomputeOne(
        pair: ProjectDatePair,
        snapshot: PricingTable.Snapshot,
        stats: inout Stats
    ) throws {
        let dateString = pair.date
        let path = pair.projectPath
        let unknownPath = ProjectDailyAggregate.unknownProjectPath
        let samples: [TokenSample]
        if path == unknownPath {
            samples = try context.fetch(
                FetchDescriptor<TokenSample>(
                    predicate: #Predicate<TokenSample> {
                        $0.date == dateString && $0.projectPath == nil
                    }
                )
            )
        } else {
            samples = try context.fetch(
                FetchDescriptor<TokenSample>(
                    predicate: #Predicate<TokenSample> {
                        $0.date == dateString && $0.projectPath == path
                    }
                )
            )
        }

        let key = ProjectDailyAggregate.makeKey(projectPath: path, date: dateString)
        let existing = try context.fetch(
            FetchDescriptor<ProjectDailyAggregate>(
                predicate: #Predicate<ProjectDailyAggregate> { $0.projectDateKey == key }
            )
        ).first

        Self.applySamples(
            pair: pair,
            samples: samples,
            existing: existing,
            mode: mode,
            snapshot: snapshot,
            insert: { context.insert($0) },
            delete: { context.delete($0) },
            stats: &stats
        )
        try syncAccountProjectRows(
            context: context, projectPath: path, date: dateString,
            samples: samples, mode: mode, snapshot: snapshot)
    }

    fileprivate nonisolated static func applySamples<S: AggregatableSample>(
        pair: ProjectDatePair,
        samples: [S],
        existing: ProjectDailyAggregate?,
        mode: CostMode,
        snapshot: PricingTable.Snapshot,
        insert: (ProjectDailyAggregate) -> Void,
        delete: (ProjectDailyAggregate) -> Void,
        stats: inout Stats
    ) {
        let path = pair.projectPath
        let dateString = pair.date
        if samples.isEmpty {
            if let existing {
                delete(existing)
                stats.aggregatesDeleted += 1
            }
            return
        }

        var values = ProjectRollupValues()
        for sample in samples { values.add(sample, mode: mode, snapshot: snapshot) }

        if let existing {
            existing.inputTokens = values.inputTokens
            existing.outputTokens = values.outputTokens
            existing.cacheReadTokens = values.cacheReadTokens
            existing.cacheCreation5mTokens = values.cacheCreation5mTokens
            existing.cacheCreation1hTokens = values.cacheCreation1hTokens
            existing.totalCostUSD = values.totalCostUSD
            existing.sessionCount = values.sessionCount
            existing.modelCount = values.modelCount
            existing.lastActive = values.lastActive
            existing.sessionIdsJSON = values.sessionIdsJSON
            existing.modelTokensJSON = values.modelTokensJSON
            existing.modelCostJSON = values.modelCostJSON
        } else {
            insert(ProjectDailyAggregate(
                projectPath: path,
                date: dateString,
                inputTokens: values.inputTokens,
                outputTokens: values.outputTokens,
                cacheReadTokens: values.cacheReadTokens,
                cacheCreation5mTokens: values.cacheCreation5mTokens,
                cacheCreation1hTokens: values.cacheCreation1hTokens,
                totalCostUSD: values.totalCostUSD,
                sessionCount: values.sessionCount,
                modelCount: values.modelCount,
                lastActive: values.lastActive,
                sessionIdsJSON: values.sessionIdsJSON,
                modelTokensJSON: values.modelTokensJSON,
                modelCostJSON: values.modelCostJSON
            ))
        }
        stats.aggregatesUpserted += 1
    }
}

/// Bring `AccountProjectDailyAggregate` for one (project, date) bucket in line
/// with its samples.
///
/// Folds through the same `ProjectRollupValues` the global rollup uses, once
/// per account, so the only difference between the two is which samples went
/// in. Note that a *session* spanning an account switch legitimately appears
/// in both accounts' sets and once in the global one — so account session
/// counts do not have to sum to the global count, and `verify-data` checks
/// tokens and cost rather than counts.
func syncAccountProjectRows<S: AggregatableSample>(
    context: ModelContext,
    projectPath: String,
    date: String,
    samples: [S],
    mode: CostMode,
    snapshot: PricingTable.Snapshot
) throws {
    var byAccount: [String: ProjectRollupValues] = [:]
    for sample in samples {
        let key = sample.accountId ?? AccountDailyAggregate.unattributedKey
        var values = byAccount[key] ?? ProjectRollupValues()
        values.add(sample, mode: mode, snapshot: snapshot)
        byAccount[key] = values
    }

    let existing = try context.fetch(
        FetchDescriptor<AccountProjectDailyAggregate>(
            predicate: #Predicate<AccountProjectDailyAggregate> {
                $0.projectPath == projectPath && $0.date == date
            }
        )
    )
    var rows: [String: AccountProjectDailyAggregate] = [:]
    for row in existing { rows[row.accountId] = row }

    for (accountId, values) in byAccount {
        if let row = rows.removeValue(forKey: accountId) {
            row.inputTokens = values.inputTokens
            row.outputTokens = values.outputTokens
            row.cacheReadTokens = values.cacheReadTokens
            row.cacheCreation5mTokens = values.cacheCreation5mTokens
            row.cacheCreation1hTokens = values.cacheCreation1hTokens
            row.totalCostUSD = values.totalCostUSD
            row.sessionCount = values.sessionCount
            row.modelCount = values.modelCount
            row.lastActive = values.lastActive
            row.sessionIdsJSON = values.sessionIdsJSON
            row.modelTokensJSON = values.modelTokensJSON
            row.modelCostJSON = values.modelCostJSON
        } else {
            context.insert(AccountProjectDailyAggregate(
                accountId: accountId, projectPath: projectPath, date: date,
                inputTokens: values.inputTokens,
                outputTokens: values.outputTokens,
                cacheReadTokens: values.cacheReadTokens,
                cacheCreation5mTokens: values.cacheCreation5mTokens,
                cacheCreation1hTokens: values.cacheCreation1hTokens,
                totalCostUSD: values.totalCostUSD,
                sessionCount: values.sessionCount,
                modelCount: values.modelCount,
                lastActive: values.lastActive,
                sessionIdsJSON: values.sessionIdsJSON,
                modelTokensJSON: values.modelTokensJSON,
                modelCostJSON: values.modelCostJSON
            ))
        }
    }
    for orphan in rows.values { context.delete(orphan) }
}

/// Off-main bulk recompute path. Owns its own `ModelContext` via
/// `@ModelActor`, fetches every TokenSample once, groups by
/// `(project, date)`, upserts each dirty pair, then saves. SwiftData
/// fans the committed changes out to MainActor `@Query` subscribers
/// so Projects/ProjectDetail refresh once the worker finishes.
@ModelActor
actor ProjectAggregateBulkWorker {

    private static let yieldInterval = 32

    func bulkRecompute(
        pairs: Set<ProjectDatePair>,
        mode: CostMode,
        snapshot: PricingTable.Snapshot,
        snapshots: SampleSnapshotCache
    ) async throws -> ProjectAggregateRecomputer.Stats {
        var stats = ProjectAggregateRecomputer.Stats(
            pairsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)

        // Shared with the daily and hourly workers — see SampleSnapshot.
        var grouped: [ProjectDatePair: [SampleSnapshot.Row]] = [:]
        for s in try snapshots.snapshot().rows {
            let path = s.projectPath ?? ProjectDailyAggregate.unknownProjectPath
            grouped[ProjectDatePair(projectPath: path, date: s.date), default: []].append(s)
        }
        let existingAll = try modelContext.fetch(FetchDescriptor<ProjectDailyAggregate>())
        var existingByKey: [String: ProjectDailyAggregate] = [:]
        for agg in existingAll { existingByKey[agg.projectDateKey] = agg }

        var processed = 0
        for pair in pairs {
            stats.pairsRecomputed += 1
            let key = ProjectDailyAggregate.makeKey(projectPath: pair.projectPath, date: pair.date)
            let existing = existingByKey[key]
            let samples = grouped[pair] ?? []
            ProjectAggregateRecomputer.applySamples(
                pair: pair,
                samples: samples,
                existing: existing,
                mode: mode,
                snapshot: snapshot,
                insert: { modelContext.insert($0) },
                delete: { modelContext.delete($0) },
                stats: &stats
            )
            try syncAccountProjectRows(
                context: modelContext, projectPath: pair.projectPath,
                date: pair.date, samples: samples, mode: mode, snapshot: snapshot)
            processed += 1
            if processed.isMultiple(of: Self.yieldInterval) {
                await Task.yield()
            }
        }

        try modelContext.save()
        return stats
    }
}
