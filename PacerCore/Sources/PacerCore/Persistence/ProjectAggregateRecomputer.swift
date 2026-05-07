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

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public struct Stats: Sendable {
        public var pairsRecomputed: Int
        public var aggregatesUpserted: Int
        public var aggregatesDeleted: Int
    }

    /// Above this many dirty pairs we switch from per-pair fetches to a
    /// single full-table sweep + in-memory grouping. The crossover
    /// roughly matches when 2700 small SQLite calls become slower than
    /// one ~30k-row fetch + a hashmap pass; chosen conservatively so
    /// backfill (always thousands of pairs) takes the bulk path while
    /// normal incremental scans (≤ a couple dozen pairs) stay on the
    /// per-pair path.
    private static let bulkRecomputeThreshold = 64
    /// How often the bulk path yields back to the run loop. The work
    /// stays on MainActor so it can touch SwiftData; yielding every
    /// few dozen pairs lets SwiftUI service draw ticks and click events
    /// during the first-install backfill instead of freezing the UI
    /// until the whole 345-bucket pass finishes.
    private static let yieldInterval = 32

    @discardableResult
    public func recompute(pairs: Set<ProjectDatePair>) async throws -> Stats {
        var stats = Stats(pairsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)
        if pairs.isEmpty { return stats }
        if pairs.count >= Self.bulkRecomputeThreshold {
            try await recomputeBulk(pairs: pairs, stats: &stats)
        } else {
            for pair in pairs {
                stats.pairsRecomputed += 1
                try recomputeOne(pair: pair, stats: &stats)
            }
        }
        // No save here — see comment in `AggregateRecomputer.recompute`.
        // The cycle's terminal save in `ScanCoordinator.runScanCycle`
        // commits every recomputer's changes in one shot.
        return stats
    }

    /// Backfill / large-batch path: one fetch of every TokenSample,
    /// one fetch of every ProjectDailyAggregate, group both into
    /// dictionaries, then update each dirty pair from in-memory data.
    /// Avoids the 2700-small-fetches storm that the per-pair path
    /// would do on first install.
    private func recomputeBulk(pairs: Set<ProjectDatePair>, stats: inout Stats) async throws {
        let allSamples = try context.fetch(FetchDescriptor<TokenSample>())
        var grouped: [ProjectDatePair: [TokenSample]] = [:]
        for s in allSamples {
            let path = s.projectPath ?? ProjectDailyAggregate.unknownProjectPath
            grouped[ProjectDatePair(projectPath: path, date: s.date), default: []].append(s)
        }
        let existingAll = try context.fetch(FetchDescriptor<ProjectDailyAggregate>())
        var existingByKey: [String: ProjectDailyAggregate] = [:]
        for agg in existingAll {
            existingByKey[agg.projectDateKey] = agg
        }
        var processed = 0
        for pair in pairs {
            stats.pairsRecomputed += 1
            let key = ProjectDailyAggregate.makeKey(projectPath: pair.projectPath, date: pair.date)
            let existing = existingByKey[key]
            let samples = grouped[pair] ?? []
            applySamples(pair: pair, samples: samples, existing: existing, stats: &stats)
            processed += 1
            if processed.isMultiple(of: Self.yieldInterval) {
                await Task.yield()
            }
        }
    }

    private func recomputeOne(pair: ProjectDatePair, stats: inout Stats) throws {
        let dateString = pair.date
        let path = pair.projectPath
        // Match samples both for the explicit-path case and the
        // missing-path "(unknown)" bucket. Doing the predicate match in
        // one pass is cheaper than two queries.
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

        applySamples(pair: pair, samples: samples, existing: existing, stats: &stats)
    }

    /// Shared upsert/delete logic used by both the per-pair and bulk
    /// recompute paths. `samples` may be empty — in that case the
    /// existing aggregate row (if any) is deleted.
    private func applySamples(
        pair: ProjectDatePair,
        samples: [TokenSample],
        existing: ProjectDailyAggregate?,
        stats: inout Stats
    ) {
        let path = pair.projectPath
        let dateString = pair.date
        if samples.isEmpty {
            if let existing {
                context.delete(existing)
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
            let cost = s.sourceCostUSD ?? 0
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
            context.insert(ProjectDailyAggregate(
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
