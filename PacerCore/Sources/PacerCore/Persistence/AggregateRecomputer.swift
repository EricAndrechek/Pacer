import Foundation
import SwiftData

/// Materializes `DailyAggregate` rows from the underlying `TokenSample`
/// table. Recomputes per `(date, model)` bucket — never the whole
/// table. The `SamplePersister` tracks which buckets got dirtied during
/// a scan and the coordinator hands that set here.
///
/// **Why per-entry cost summation, not (sum-tokens then price-once)**:
///
/// 1. `CostMode.auto` semantics: the per-entry `costUSD` is preferred
///    when present, computed-from-tokens is the fallback. That's a
///    per-entry decision; collapsing to a sum first would erase the
///    storedCost path entirely and silently use computed-cost for
///    every row, including ones Claude Code already priced.
/// 2. Tiered pricing applies the 200k boundary **per API call**, not
///    per day. Summing tokens across entries first and then applying
///    `tieredCost` would mis-attribute the boundary — e.g. ten 100k
///    calls would look like one 1M call. ccusage iterates entries the
///    same way (`data-loader.ts:638-678`).
@MainActor
public final class AggregateRecomputer {

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
    /// Backfill on first install or after a parser-version bump can
    /// produce hundreds of pairs; normal incremental scans produce a
    /// handful and stay on the main context where the per-pair
    /// fetches are cheap and visibility of in-flight inserts is free.
    private static let bulkRecomputeThreshold = 64

    /// Recompute all dirty buckets and upsert their `DailyAggregate`
    /// rows. A bucket with zero remaining samples (shouldn't happen
    /// during a scan, but possible if an external delete intervened)
    /// has its `DailyAggregate` row removed.
    @discardableResult
    public func recompute(pairs: Set<DateModelPair>) async throws -> Stats {
        if pairs.isEmpty {
            return Stats(pairsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)
        }
        if pairs.count >= Self.bulkRecomputeThreshold {
            // Commit any pending main-context inserts before the bulk
            // worker (separate context) reads. Cheap if nothing's
            // pending — which is the common case here, since the bulk
            // path mostly fires on the missing-pair recovery flow
            // where samples are already on disk.
            try context.save()
            if mode == .calculate {
                try? await pricingTable.ensureLoaded()
            }
            let worker = AggregateBulkWorker(modelContainer: container)
            return try await worker.bulkRecompute(
                pairs: pairs,
                mode: mode,
                pricingTable: pricingTable
            )
        }

        var stats = Stats(pairsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)
        if mode == .calculate {
            try? await pricingTable.ensureLoaded()
        }
        for pair in pairs {
            stats.pairsRecomputed += 1
            try await recomputeOne(pair: pair, stats: &stats)
        }
        // No save here — `ScanCoordinator.runScanCycle` does one
        // terminal save per cycle that commits this recomputer's
        // changes alongside the project recomputer's, the session
        // recomputer's, the cursor updates, and the meta writes.
        return stats
    }

    private func recomputeOne(pair: DateModelPair, stats: inout Stats) async throws {
        let dateString = pair.date
        let modelString = pair.model
        let sampleDescriptor = FetchDescriptor<TokenSample>(
            predicate: #Predicate<TokenSample> {
                $0.date == dateString && $0.model == modelString
            }
        )
        let samples = try context.fetch(sampleDescriptor)

        let aggKey = DailyAggregate.makeKey(date: dateString, model: modelString)
        let existing = try context.fetch(
            FetchDescriptor<DailyAggregate>(
                predicate: #Predicate<DailyAggregate> { $0.dateModelKey == aggKey }
            )
        ).first

        if samples.isEmpty {
            if let existing {
                context.delete(existing)
                stats.aggregatesDeleted += 1
            }
            return
        }

        var sum = TokenBreakdown()
        var totalCost: Double = 0
        var pricing: LiteLLMModelPricing?
        var pricingLoaded = false

        for sample in samples {
            let breakdown = TokenBreakdown(
                inputTokens: sample.inputTokens,
                outputTokens: sample.outputTokens,
                cacheReadTokens: sample.cacheReadTokens,
                cacheCreation5mTokens: sample.cacheCreation5mTokens,
                cacheCreation1hTokens: sample.cacheCreation1hTokens
            )
            sum.add(breakdown)

            switch mode {
            case .display:
                totalCost += sample.sourceCostUSD ?? 0
            case .auto:
                if let stored = sample.sourceCostUSD {
                    totalCost += stored
                } else {
                    if !pricingLoaded {
                        try? await pricingTable.ensureLoaded()
                        pricing = await pricingTable.pricing(for: modelString)
                        pricingLoaded = true
                    }
                    if let pricing {
                        totalCost += CostCalculator.cost(breakdown: breakdown, pricing: pricing)
                    }
                }
            case .calculate:
                if !pricingLoaded {
                    pricing = await pricingTable.pricing(for: modelString)
                    pricingLoaded = true
                }
                if let pricing {
                    totalCost += CostCalculator.cost(breakdown: breakdown, pricing: pricing)
                }
            }
        }

        if let existing {
            existing.inputTokens = sum.inputTokens
            existing.outputTokens = sum.outputTokens
            existing.cacheReadTokens = sum.cacheReadTokens
            existing.cacheCreation5mTokens = sum.cacheCreation5mTokens
            existing.cacheCreation1hTokens = sum.cacheCreation1hTokens
            existing.totalCostUSD = totalCost
        } else {
            context.insert(DailyAggregate(
                date: dateString,
                model: modelString,
                inputTokens: sum.inputTokens,
                outputTokens: sum.outputTokens,
                cacheReadTokens: sum.cacheReadTokens,
                cacheCreation5mTokens: sum.cacheCreation5mTokens,
                cacheCreation1hTokens: sum.cacheCreation1hTokens,
                totalCostUSD: totalCost
            ))
        }
        stats.aggregatesUpserted += 1
    }
}

/// Background recompute worker for the bulk path of
/// `AggregateRecomputer`. Owns its own `ModelContext` (provided by
/// `@ModelActor`) so the heavy fetch + iterate runs off the main
/// thread and saves through a separate context. SwiftData fans the
/// committed changes out to other contexts on the same container, so
/// MainActor `@Query` subscribers refresh once the worker saves.
@ModelActor
actor AggregateBulkWorker {

    /// Yield to the run loop every N pairs while we're working — the
    /// actor is on a background thread, but yields still help when
    /// the system is busy.
    private static let yieldInterval = 32

    func bulkRecompute(
        pairs: Set<DateModelPair>,
        mode: CostMode,
        pricingTable: PricingTable
    ) async throws -> AggregateRecomputer.Stats {
        var stats = AggregateRecomputer.Stats(
            pairsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)

        // One fetch of all samples, grouped by (date, model).
        let allSamples = try modelContext.fetch(FetchDescriptor<TokenSample>())
        var grouped: [DateModelPair: [TokenSample]] = [:]
        for s in allSamples {
            grouped[DateModelPair(date: s.date, model: s.model), default: []].append(s)
        }
        let existingAll = try modelContext.fetch(FetchDescriptor<DailyAggregate>())
        var existingByKey: [String: DailyAggregate] = [:]
        for agg in existingAll { existingByKey[agg.dateModelKey] = agg }

        var pricingCache: [String: LiteLLMModelPricing?] = [:]
        var processed = 0
        for pair in pairs {
            stats.pairsRecomputed += 1
            let key = DailyAggregate.makeKey(date: pair.date, model: pair.model)
            let existing = existingByKey[key]
            let samples = grouped[pair] ?? []

            if samples.isEmpty {
                if let existing {
                    modelContext.delete(existing)
                    stats.aggregatesDeleted += 1
                }
                continue
            }

            var sum = TokenBreakdown()
            var totalCost: Double = 0
            for sample in samples {
                let breakdown = TokenBreakdown(
                    inputTokens: sample.inputTokens,
                    outputTokens: sample.outputTokens,
                    cacheReadTokens: sample.cacheReadTokens,
                    cacheCreation5mTokens: sample.cacheCreation5mTokens,
                    cacheCreation1hTokens: sample.cacheCreation1hTokens
                )
                sum.add(breakdown)

                switch mode {
                case .display:
                    totalCost += sample.sourceCostUSD ?? 0
                case .auto:
                    if let stored = sample.sourceCostUSD {
                        totalCost += stored
                    } else {
                        let pricing = try await pricing(for: pair.model, cache: &pricingCache, pricingTable: pricingTable)
                        if let pricing {
                            totalCost += CostCalculator.cost(breakdown: breakdown, pricing: pricing)
                        }
                    }
                case .calculate:
                    let pricing = try await pricing(for: pair.model, cache: &pricingCache, pricingTable: pricingTable)
                    if let pricing {
                        totalCost += CostCalculator.cost(breakdown: breakdown, pricing: pricing)
                    }
                }
            }

            if let existing {
                existing.inputTokens = sum.inputTokens
                existing.outputTokens = sum.outputTokens
                existing.cacheReadTokens = sum.cacheReadTokens
                existing.cacheCreation5mTokens = sum.cacheCreation5mTokens
                existing.cacheCreation1hTokens = sum.cacheCreation1hTokens
                existing.totalCostUSD = totalCost
            } else {
                modelContext.insert(DailyAggregate(
                    date: pair.date,
                    model: pair.model,
                    inputTokens: sum.inputTokens,
                    outputTokens: sum.outputTokens,
                    cacheReadTokens: sum.cacheReadTokens,
                    cacheCreation5mTokens: sum.cacheCreation5mTokens,
                    cacheCreation1hTokens: sum.cacheCreation1hTokens,
                    totalCostUSD: totalCost
                ))
            }
            stats.aggregatesUpserted += 1
            processed += 1
            if processed.isMultiple(of: Self.yieldInterval) {
                await Task.yield()
            }
        }

        try modelContext.save()
        return stats
    }

    /// Per-model pricing lookup with a small in-actor cache so we
    /// only consult `PricingTable` once per model across all the
    /// dirty pairs of one bulk run.
    private func pricing(
        for model: String,
        cache: inout [String: LiteLLMModelPricing?],
        pricingTable: PricingTable
    ) async throws -> LiteLLMModelPricing? {
        if let cached = cache[model] { return cached }
        let resolved = await pricingTable.pricing(for: model)
        cache[model] = resolved
        return resolved
    }
}
