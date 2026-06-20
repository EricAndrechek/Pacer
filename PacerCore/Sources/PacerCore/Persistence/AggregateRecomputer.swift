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
@ScanActor
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
        /// How many pairs took the incremental fast path this call. The
        /// remainder of `pairsRecomputed` went through the legacy
        /// "fetch all samples for the pair + sum" path. Lets the
        /// caller log whether the fast path is engaging — large
        /// `pairsRecomputed - fastPathApplied` gaps mean pollution
        /// (recovery / cost-version bumps / migrations) is forcing the
        /// slow path.
        public var fastPathApplied: Int = 0
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
    ///
    /// `pending` and `polluted` opt the per-pair path into the
    /// incremental fast path: for any pair where `pending[pair]` is
    /// non-empty AND the pair is NOT polluted AND a `DailyAggregate`
    /// row already exists for the pair, the recomputer adds just
    /// those new samples' tokens + per-sample cost to the existing
    /// aggregate — skipping the giant per-pair fetch (the source of
    /// the ~400ms-per-pair scan tick we measured before this change).
    /// Empty defaults preserve the legacy "always full-recompute"
    /// behavior for callers that don't have pending-sample tracking
    /// (tests, the rare manual call).
    @discardableResult
    public func recompute(
        pairs: Set<DateModelPair>,
        pending: [DateModelPair: [TokenSample]] = [:],
        polluted: Set<DateModelPair> = []
    ) async throws -> Stats {
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
        // Pricing snapshot for the per-sample fast-path cost
        // computation. We read from `SampleCostCache` (process-wide,
        // warmed at app launch, nonisolated) rather than awaiting
        // `PricingTable.shared` per cycle — the actor hop was
        // adding ~150 ms per recomputer phase under MainActor
        // contention (every scan cycle was paying it). The cache is
        // updated atomically when the user toggles cost mode or when
        // a pricing refresh completes; recomputer fast-path callers
        // are tolerant of a one-cycle stale snapshot.
        //
        // `.display` mode never consults pricing — skip the read.
        let pricingSnapshot: PricingTable.Snapshot = (mode == .display)
            ? PricingTable.Snapshot(pricingByModel: [:])
            : SampleCostCache.current()
        for pair in pairs {
            stats.pairsRecomputed += 1
            let pendingForPair = pending[pair] ?? []
            let isPolluted = polluted.contains(pair)
            if !isPolluted, !pendingForPair.isEmpty,
               try fastPathApply(pair: pair, pending: pendingForPair,
                                 snapshot: pricingSnapshot, stats: &stats) {
                continue
            }
            try await recomputeOne(pair: pair, stats: &stats)
        }
        // No save here — `ScanCoordinator.runScanCycle` does one
        // terminal save per cycle that commits this recomputer's
        // changes alongside the project recomputer's, the session
        // recomputer's, the cursor updates, and the meta writes.
        return stats
    }

    /// Incremental fast path: if a `DailyAggregate` row already exists
    /// for the pair, add the new samples' tokens + per-sample cost to
    /// it in place. Returns `true` when applied, `false` when the row
    /// didn't exist (brand-new bucket) or another reason makes the
    /// fast path inappropriate — caller falls through to `recomputeOne`.
    ///
    /// Cost is computed per-sample (NOT sum-tokens-then-price): the
    /// 200k-tier boundary on Anthropic's pricing applies per API call,
    /// not per day, so summing first would mis-attribute the
    /// boundary. ccusage applies the same per-entry semantics
    /// (`data-loader.ts:638-678`). This matches what the full
    /// recompute path does in `recomputeOne` below.
    private func fastPathApply(
        pair: DateModelPair,
        pending: [TokenSample],
        snapshot: PricingTable.Snapshot,
        stats: inout Stats
    ) throws -> Bool {
        let aggKey = DailyAggregate.makeKey(date: pair.date, model: pair.model)
        let existing = try context.fetch(
            FetchDescriptor<DailyAggregate>(
                predicate: #Predicate<DailyAggregate> { $0.dateModelKey == aggKey }
            )
        ).first
        guard let existing else { return false }

        for sample in pending {
            existing.inputTokens += sample.inputTokens
            existing.outputTokens += sample.outputTokens
            existing.cacheReadTokens += sample.cacheReadTokens
            existing.cacheCreation5mTokens += sample.cacheCreation5mTokens
            existing.cacheCreation1hTokens += sample.cacheCreation1hTokens
            let breakdown = TokenBreakdown(
                inputTokens: sample.inputTokens,
                outputTokens: sample.outputTokens,
                cacheReadTokens: sample.cacheReadTokens,
                cacheCreation5mTokens: sample.cacheCreation5mTokens,
                cacheCreation1hTokens: sample.cacheCreation1hTokens
            )
            existing.totalCostUSD += CostCalculator.cost(
                storedCostUSD: sample.sourceCostUSD,
                model: sample.model,
                breakdown: breakdown,
                mode: mode,
                snapshot: snapshot
            )
        }
        stats.aggregatesUpserted += 1
        stats.fastPathApplied += 1
        return true
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
