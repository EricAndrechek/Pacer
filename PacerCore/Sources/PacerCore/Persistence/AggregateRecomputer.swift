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

    private let context: ModelContext
    private let mode: CostMode
    private let pricingTable: PricingTable

    public init(
        context: ModelContext,
        mode: CostMode = .auto,
        pricingTable: PricingTable = .shared
    ) {
        self.context = context
        self.mode = mode
        self.pricingTable = pricingTable
    }

    public struct Stats: Sendable {
        public var pairsRecomputed: Int
        public var aggregatesUpserted: Int
        public var aggregatesDeleted: Int
    }

    /// Recompute all dirty buckets and upsert their `DailyAggregate`
    /// rows. A bucket with zero remaining samples (shouldn't happen
    /// during a scan, but possible if an external delete intervened)
    /// has its `DailyAggregate` row removed.
    @discardableResult
    public func recompute(pairs: Set<DateModelPair>) async throws -> Stats {
        var stats = Stats(pairsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)
        // Load pricing once if we'll need it (calculate-mode always,
        // auto-mode lazily on the first storedCost-missing entry).
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
        // Collapsing those into a single save halves the @Query
        // refresh fan-out on every scan tick.
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
        // Lazy pricing lookup: auto-mode hits this only when a sample
        // has no storedCostUSD. For models the user only runs in
        // Claude Code (which always emits costUSD), the pricing table
        // never gets touched during recompute.
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
