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
@MainActor
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
    }

    /// Above this many dirty pairs we hand off to a background
    /// `@ModelActor` worker so the recompute doesn't block MainActor.
    /// Backfill (always thousands of pairs) takes the bulk path; normal
    /// incremental scans (≤ a couple dozen pairs) stay on the per-pair
    /// main-context path where the predicate-filtered fetches are
    /// cheap and visibility of in-flight inserts is free.
    private static let bulkRecomputeThreshold = 64

    @discardableResult
    public func recompute(pairs: Set<ProjectDatePair>) async throws -> Stats {
        var stats = Stats(pairsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)
        if pairs.isEmpty { return stats }
        // Pricing must be loaded before we walk samples — without it
        // every TokenSample whose `sourceCostUSD` is nil contributes
        // $0 to the project rollup, which is exactly the bug the
        // Projects view was hitting before this fix.
        try? await pricingTable.ensureLoaded()
        let snapshot = await pricingTable.snapshot()
        if pairs.count >= Self.bulkRecomputeThreshold {
            // See AggregateRecomputer — commit any pending main-context
            // inserts so the background worker's separate context can
            // see them.
            try context.save()
            let worker = ProjectAggregateBulkWorker(modelContainer: container)
            return try await worker.bulkRecompute(
                pairs: pairs, mode: mode, snapshot: snapshot)
        }
        for pair in pairs {
            stats.pairsRecomputed += 1
            try recomputeOne(pair: pair, snapshot: snapshot, stats: &stats)
        }
        // No save here — see comment in `AggregateRecomputer.recompute`.
        return stats
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
    }

    fileprivate nonisolated static func applySamples(
        pair: ProjectDatePair,
        samples: [TokenSample],
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

        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0
        var cacheCreation5mTokens: Int64 = 0
        var cacheCreation1hTokens: Int64 = 0
        var totalCost: Double = 0
        var sessions: Set<String> = []
        var modelTokens: [String: Int64] = [:]
        var modelCost: [String: Double] = [:]
        var lastActive: Date = .distantPast

        for s in samples {
            inputTokens += s.inputTokens
            outputTokens += s.outputTokens
            cacheReadTokens += s.cacheReadTokens
            cacheCreation5mTokens += s.cacheCreation5mTokens
            cacheCreation1hTokens += s.cacheCreation1hTokens
            // Cost via the same per-sample path AggregateRecomputer
            // uses: prefer Claude Code's stored value when present
            // (auto/display modes), fall back to tokens × pricing.
            // Previously this was just `s.sourceCostUSD ?? 0`, which
            // silently treated every CC line without a stored cost as
            // free — that's why the Projects tab showed $0 across the
            // board for many users.
            let breakdown = TokenBreakdown(
                inputTokens: s.inputTokens,
                outputTokens: s.outputTokens,
                cacheReadTokens: s.cacheReadTokens,
                cacheCreation5mTokens: s.cacheCreation5mTokens,
                cacheCreation1hTokens: s.cacheCreation1hTokens
            )
            let cost = CostCalculator.cost(
                storedCostUSD: s.sourceCostUSD,
                model: s.model,
                breakdown: breakdown,
                mode: mode,
                snapshot: snapshot
            )
            totalCost += cost
            if let sid = s.sessionId, !sid.isEmpty {
                sessions.insert(sid)
            }
            modelTokens[s.model, default: 0] += s.inputTokens + s.outputTokens + s.cacheReadTokens
            modelCost[s.model, default: 0] += cost
            if s.sampledAt > lastActive { lastActive = s.sampledAt }
        }

        let sessionIdsJSON = (try? JSONEncoder().encode(Array(sessions))) ?? Data()
        let modelTokensJSON = (try? JSONEncoder().encode(modelTokens)) ?? Data()
        let modelCostJSON = (try? JSONEncoder().encode(modelCost)) ?? Data()

        if let existing {
            existing.inputTokens = inputTokens
            existing.outputTokens = outputTokens
            existing.cacheReadTokens = cacheReadTokens
            existing.cacheCreation5mTokens = cacheCreation5mTokens
            existing.cacheCreation1hTokens = cacheCreation1hTokens
            existing.totalCostUSD = totalCost
            existing.sessionCount = sessions.count
            existing.modelCount = modelTokens.count
            existing.lastActive = lastActive
            existing.sessionIdsJSON = sessionIdsJSON
            existing.modelTokensJSON = modelTokensJSON
            existing.modelCostJSON = modelCostJSON
        } else {
            insert(ProjectDailyAggregate(
                projectPath: path,
                date: dateString,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreation5mTokens: cacheCreation5mTokens,
                cacheCreation1hTokens: cacheCreation1hTokens,
                totalCostUSD: totalCost,
                sessionCount: sessions.count,
                modelCount: modelTokens.count,
                lastActive: lastActive,
                sessionIdsJSON: sessionIdsJSON,
                modelTokensJSON: modelTokensJSON,
                modelCostJSON: modelCostJSON
            ))
        }
        stats.aggregatesUpserted += 1
    }
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
        snapshot: PricingTable.Snapshot
    ) async throws -> ProjectAggregateRecomputer.Stats {
        var stats = ProjectAggregateRecomputer.Stats(
            pairsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)

        let allSamples = try modelContext.fetch(FetchDescriptor<TokenSample>())
        var grouped: [ProjectDatePair: [TokenSample]] = [:]
        for s in allSamples {
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
            processed += 1
            if processed.isMultiple(of: Self.yieldInterval) {
                await Task.yield()
            }
        }

        try modelContext.save()
        return stats
    }
}
