import Foundation
import SwiftData

/// Materializes `HourlyAggregate` rows from underlying `TokenSample`
/// rows. Recomputes per `(date, hour, model)` bucket — never the
/// whole table. The `SamplePersister` tracks which hour buckets got
/// dirtied during a scan and `ScanCoordinator` hands that set here.
///
/// Mirrors `AggregateRecomputer` exactly, just with an extra hour
/// dimension. Same cost-mode semantics (per-entry decision, ccusage
/// parity on tier boundaries — see that file for the why), same
/// per-pair / bulk-actor split keyed off `bulkRecomputeThreshold`.
@ScanActor
public final class HourlyAggregateRecomputer {

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
        public var bucketsRecomputed: Int
        public var aggregatesUpserted: Int
        public var aggregatesDeleted: Int
        /// Mirror of `AggregateRecomputer.Stats.fastPathApplied` — see
        /// that doc for the diagnostic intent.
        public var fastPathApplied: Int = 0
    }

    /// Same threshold as the sister recomputers — keeps incremental
    /// scans (a few buckets per cycle) on the main context where
    /// in-flight inserts are visible, and routes backfill (thousands of
    /// buckets on bootstrap or cost-recompute bumps) to the bulk path.
    private static let bulkRecomputeThreshold = 64

    /// Recompute dirty hour buckets and upsert their `HourlyAggregate`
    /// rows. `pending` and `polluted` opt into the incremental fast
    /// path — see `AggregateRecomputer.recompute` for the design
    /// rationale; this method mirrors it exactly. Empty defaults
    /// preserve the legacy "always full-recompute" behavior.
    @discardableResult
    public func recompute(
        buckets: Set<DateHourModelTriple>,
        pending: [DateHourModelTriple: [TokenSample]] = [:],
        polluted: Set<DateHourModelTriple> = [],
        snapshots: SampleSnapshotCache? = nil
    ) async throws -> Stats {
        if buckets.isEmpty {
            return Stats(bucketsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)
        }
        if buckets.count >= Self.bulkRecomputeThreshold {
            // Commit pending main-context inserts before the bulk
            // worker's separate context reads — same coordination
            // dance as the other recomputers.
            try context.save()
            if mode == .calculate {
                try? await pricingTable.ensureLoaded()
            }
            let worker = HourlyAggregateBulkWorker(modelContainer: container)
            return try await worker.bulkRecompute(
                buckets: buckets,
                mode: mode,
                pricingTable: pricingTable,
                snapshots: snapshots ?? SampleSnapshotCache(container: container)
            )
        }

        var stats = Stats(bucketsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)
        // Pricing snapshot via `SampleCostCache.current()` (sync,
        // nonisolated) — see the same comment in
        // `AggregateRecomputer.recompute` for why we don't `await`
        // `PricingTable.shared` here.
        let pricingSnapshot: PricingTable.Snapshot = (mode == .display)
            ? PricingTable.Snapshot(pricingByModel: [:])
            : SampleCostCache.current()
        for bucket in buckets {
            stats.bucketsRecomputed += 1
            let pendingForBucket = pending[bucket] ?? []
            let isPolluted = polluted.contains(bucket)
            if !isPolluted, !pendingForBucket.isEmpty,
               try fastPathApply(bucket: bucket, pending: pendingForBucket,
                                 snapshot: pricingSnapshot, stats: &stats) {
                continue
            }
            try await recomputeOne(bucket: bucket, stats: &stats)
        }
        // No save here — `ScanCoordinator.runScanCycle` does one
        // terminal save per cycle that commits this recomputer's
        // changes alongside the others'.
        return stats
    }

    /// Incremental fast path. Mirrors
    /// `AggregateRecomputer.fastPathApply` — returns `true` when the
    /// existing aggregate row was updated in place, `false` when no
    /// row exists yet and the caller should fall through to the full
    /// recompute. Per-sample cost (no sum-then-price) preserves the
    /// 200k-tier-per-call semantics; `sampleCount` adds the pending
    /// count because the existing row already counted prior samples.
    private func fastPathApply(
        bucket: DateHourModelTriple,
        pending: [TokenSample],
        snapshot: PricingTable.Snapshot,
        stats: inout Stats
    ) throws -> Bool {
        let aggKey = HourlyAggregate.makeKey(
            date: bucket.date, hour: bucket.hour, model: bucket.model)
        let existing = try context.fetch(
            FetchDescriptor<HourlyAggregate>(
                predicate: #Predicate<HourlyAggregate> { $0.dateHourModelKey == aggKey }
            )
        ).first
        guard let existing else { return false }

        var perAccount: [String: (sum: TokenBreakdown, cost: Double)] = [:]
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
            let sampleCost = CostCalculator.cost(
                storedCostUSD: sample.sourceCostUSD,
                model: sample.model,
                breakdown: breakdown,
                mode: mode,
                snapshot: snapshot
            )
            existing.totalCostUSD += sampleCost

            // Accumulated and written once per account below. The daily
            // rollup learned this the expensive way: writing per sample cost
            // a fetch each time, and a fetch against a context full of
            // uncommitted inserts has to merge them — a cost charged to
            // whoever fetches next, not to the code that caused it.
            let accountKey = sample.accountId ?? AccountDailyAggregate.unattributedKey
            var acc = perAccount[accountKey] ?? (TokenBreakdown(), 0)
            acc.sum.add(breakdown)
            acc.cost += sampleCost
            perAccount[accountKey] = acc
        }
        for (accountId, acc) in perAccount {
            try addToAccountHourlyRow(
                context: context, accountId: accountId, date: bucket.date,
                hour: bucket.hour, model: bucket.model,
                breakdown: acc.sum, cost: acc.cost)
        }
        existing.sampleCount += pending.count
        stats.aggregatesUpserted += 1
        stats.fastPathApplied += 1
        return true
    }

    private func recomputeOne(bucket: DateHourModelTriple, stats: inout Stats) async throws {
        let dateString = bucket.date
        let modelString = bucket.model
        // Predicating on `sampledAt` would force a range scan; instead
        // we predicate on `(date, model)` (covered by the existing
        // index) and filter the resulting bundle by local hour in
        // memory. A day's worth of samples for one model is small
        // — a few hundred rows even on a heavy session — so the
        // in-memory hour filter is negligible vs the saving of not
        // running a separate sampledAt-range predicate per hour.
        //
        // UPDATE: the hour is now STORED, so it belongs in the predicate. The
        // note above assumed "a few hundred rows" per (day, model); on a real
        // store it is ~3,000, and rebuilding a couple of hour buckets was
        // materializing ~18,000 rows and costing 1.4 s of a 4.5 s cycle.
        //
        // `localHour < 0` is still admitted because rows written before the
        // field existed carry -1 and must not silently drop out of their
        // bucket. That set only shrinks — the integrity walk backfills it —
        // so this converges on fetching just the bucket.
        let targetHour = bucket.hour
        let sampleDescriptor = FetchDescriptor<TokenSample>(
            predicate: #Predicate<TokenSample> {
                $0.date == dateString && $0.model == modelString
                    && ($0.localHour == targetHour || $0.localHour < 0)
            }
        )
        let allDayModelSamples = try context.fetch(sampleDescriptor)
        let samples = allDayModelSamples.filter { sample in
            // The STORED hour, falling back to derivation only for rows
            // written before the field existed. Deriving here would put this
            // per-bucket path back on the drifting definition the bulk path
            // just moved off — same bug, different code path.
            let hour = sample.localHour >= 0
                ? sample.localHour
                : Calendar.current.component(.hour, from: sample.sampledAt)
            return hour == targetHour
        }

        let aggKey = HourlyAggregate.makeKey(
            date: dateString, hour: targetHour, model: modelString)
        let existing = try context.fetch(
            FetchDescriptor<HourlyAggregate>(
                predicate: #Predicate<HourlyAggregate> { $0.dateHourModelKey == aggKey }
            )
        ).first

        if samples.isEmpty {
            if let existing {
                context.delete(existing)
                stats.aggregatesDeleted += 1
            }
            try syncAccountHourlyRows(
                context: context, date: dateString, hour: targetHour,
                model: modelString, perAccount: [:])
            return
        }

        var sum = TokenBreakdown()
        var totalCost: Double = 0
        var pricing: LiteLLMModelPricing?
        var pricingLoaded = false
        var perAccount: [String: (sum: TokenBreakdown, cost: Double)] = [:]

        for sample in samples {
            let breakdown = TokenBreakdown(
                inputTokens: sample.inputTokens,
                outputTokens: sample.outputTokens,
                cacheReadTokens: sample.cacheReadTokens,
                cacheCreation5mTokens: sample.cacheCreation5mTokens,
                cacheCreation1hTokens: sample.cacheCreation1hTokens
            )
            sum.add(breakdown)

            let sampleCost: Double
            switch mode {
            case .display:
                sampleCost = sample.sourceCostUSD ?? 0
            case .auto:
                if let stored = sample.sourceCostUSD {
                    sampleCost = stored
                } else {
                    if !pricingLoaded {
                        try? await pricingTable.ensureLoaded()
                        pricing = await pricingTable.pricing(for: modelString)
                        pricingLoaded = true
                    }
                    sampleCost = pricing.map {
                        CostCalculator.cost(breakdown: breakdown, pricing: $0)
                    } ?? 0
                }
            case .calculate:
                if !pricingLoaded {
                    pricing = await pricingTable.pricing(for: modelString)
                    pricingLoaded = true
                }
                sampleCost = pricing.map {
                    CostCalculator.cost(breakdown: breakdown, pricing: $0)
                } ?? 0
            }
            totalCost += sampleCost

            let accountKey = sample.accountId ?? AccountDailyAggregate.unattributedKey
            var acc = perAccount[accountKey] ?? (TokenBreakdown(), 0)
            acc.sum.add(breakdown)
            acc.cost += sampleCost
            perAccount[accountKey] = acc
        }

        try syncAccountHourlyRows(
            context: context, date: dateString, hour: targetHour,
            model: modelString, perAccount: perAccount)

        if let existing {
            existing.inputTokens = sum.inputTokens
            existing.outputTokens = sum.outputTokens
            existing.cacheReadTokens = sum.cacheReadTokens
            existing.cacheCreation5mTokens = sum.cacheCreation5mTokens
            existing.cacheCreation1hTokens = sum.cacheCreation1hTokens
            existing.totalCostUSD = totalCost
            existing.sampleCount = samples.count
        } else {
            context.insert(HourlyAggregate(
                date: dateString,
                hour: targetHour,
                model: modelString,
                inputTokens: sum.inputTokens,
                outputTokens: sum.outputTokens,
                cacheReadTokens: sum.cacheReadTokens,
                cacheCreation5mTokens: sum.cacheCreation5mTokens,
                cacheCreation1hTokens: sum.cacheCreation1hTokens,
                totalCostUSD: totalCost,
                sampleCount: samples.count
            ))
        }
        stats.aggregatesUpserted += 1
    }
}

/// Background bulk path for `HourlyAggregateRecomputer`. Same shape
/// as `AggregateBulkWorker` / `ProjectAggregateBulkWorker`: own
/// `ModelContext`, one full TokenSample fetch, in-memory grouping by
/// the rollup's key, upsert per dirty bucket, save once.
@ModelActor
actor HourlyAggregateBulkWorker {

    private static let yieldInterval = 32

    func bulkRecompute(
        buckets: Set<DateHourModelTriple>,
        mode: CostMode,
        pricingTable: PricingTable,
        snapshots: SampleSnapshotCache
    ) async throws -> HourlyAggregateRecomputer.Stats {
        var stats = HourlyAggregateRecomputer.Stats(
            bucketsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)

        // One fetch of all samples; group by (date, hour, model) in
        // memory. Hour is the user-local calendar component, same
        // semantics the per-pair path and `SamplePersister.localHour`
        // use everywhere else.
        // Shared with the daily and project workers — see SampleSnapshot.
        var grouped: [DateHourModelTriple: [SampleSnapshot.Row]] = [:]
        for s in try snapshots.snapshot().rows {
            // The STORED hour, not a fresh derivation — re-deriving is what
            // let historical buckets drift across a DST/timezone change.
            let h = s.localHour
            grouped[DateHourModelTriple(date: s.date, hour: h, model: s.model),
                    default: []].append(s)
        }
        let existingAll = try modelContext.fetch(FetchDescriptor<HourlyAggregate>())
        var existingByKey: [String: HourlyAggregate] = [:]
        for agg in existingAll { existingByKey[agg.dateHourModelKey] = agg }

        var pricingCache: [String: LiteLLMModelPricing?] = [:]
        var processed = 0
        for bucket in buckets {
            stats.bucketsRecomputed += 1
            let key = HourlyAggregate.makeKey(
                date: bucket.date, hour: bucket.hour, model: bucket.model)
            let existing = existingByKey[key]
            let samples = grouped[bucket] ?? []

            if samples.isEmpty {
                if let existing {
                    modelContext.delete(existing)
                    stats.aggregatesDeleted += 1
                }
                try syncAccountHourlyRows(
                    context: modelContext, date: bucket.date, hour: bucket.hour,
                    model: bucket.model, perAccount: [:])
                continue
            }

            var sum = TokenBreakdown()
            var totalCost: Double = 0
            var perAccount: [String: (sum: TokenBreakdown, cost: Double)] = [:]
            for sample in samples {
                let breakdown = sample.breakdown
                sum.add(breakdown)

                let sampleCost: Double
                switch mode {
                case .display:
                    sampleCost = sample.sourceCostUSD ?? 0
                case .auto:
                    if let stored = sample.sourceCostUSD {
                        sampleCost = stored
                    } else {
                        let pricing = try await pricing(
                            for: bucket.model, cache: &pricingCache, pricingTable: pricingTable)
                        sampleCost = pricing.map {
                            CostCalculator.cost(breakdown: breakdown, pricing: $0)
                        } ?? 0
                    }
                case .calculate:
                    let pricing = try await pricing(
                        for: bucket.model, cache: &pricingCache, pricingTable: pricingTable)
                    sampleCost = pricing.map {
                        CostCalculator.cost(breakdown: breakdown, pricing: $0)
                    } ?? 0
                }
                totalCost += sampleCost

                let accountKey = sample.accountId ?? AccountDailyAggregate.unattributedKey
                var acc = perAccount[accountKey] ?? (TokenBreakdown(), 0)
                acc.sum.add(breakdown)
                acc.cost += sampleCost
                perAccount[accountKey] = acc
            }

            try syncAccountHourlyRows(
                context: modelContext, date: bucket.date, hour: bucket.hour,
                model: bucket.model, perAccount: perAccount)

            if let existing {
                existing.inputTokens = sum.inputTokens
                existing.outputTokens = sum.outputTokens
                existing.cacheReadTokens = sum.cacheReadTokens
                existing.cacheCreation5mTokens = sum.cacheCreation5mTokens
                existing.cacheCreation1hTokens = sum.cacheCreation1hTokens
                existing.totalCostUSD = totalCost
                existing.sampleCount = samples.count
            } else {
                modelContext.insert(HourlyAggregate(
                    date: bucket.date,
                    hour: bucket.hour,
                    model: bucket.model,
                    inputTokens: sum.inputTokens,
                    outputTokens: sum.outputTokens,
                    cacheReadTokens: sum.cacheReadTokens,
                    cacheCreation5mTokens: sum.cacheCreation5mTokens,
                    cacheCreation1hTokens: sum.cacheCreation1hTokens,
                    totalCostUSD: totalCost,
                    sampleCount: samples.count
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

/// Bring `AccountHourlyAggregate` for one (date, hour, model) bucket in line
/// with the split just computed.
///
/// A free function for the same reason `syncAccountRows` is: the per-bucket
/// path and the bulk worker live on different actors with different contexts,
/// and a rollup written by two copies of the same logic drifts depending on
/// which one last touched a bucket.
func syncAccountHourlyRows(
    context: ModelContext,
    date: String,
    hour: Int,
    model: String,
    perAccount: [String: (sum: TokenBreakdown, cost: Double)]
) throws {
    let existing = try context.fetch(
        FetchDescriptor<AccountHourlyAggregate>(
            predicate: #Predicate<AccountHourlyAggregate> {
                $0.date == date && $0.hour == hour && $0.model == model
            }
        )
    )
    var byAccount: [String: AccountHourlyAggregate] = [:]
    for row in existing { byAccount[row.accountId] = row }

    for (accountId, bucket) in perAccount {
        if let row = byAccount.removeValue(forKey: accountId) {
            row.inputTokens = bucket.sum.inputTokens
            row.outputTokens = bucket.sum.outputTokens
            row.cacheReadTokens = bucket.sum.cacheReadTokens
            row.cacheCreation5mTokens = bucket.sum.cacheCreation5mTokens
            row.cacheCreation1hTokens = bucket.sum.cacheCreation1hTokens
            row.totalCostUSD = bucket.cost
        } else {
            context.insert(AccountHourlyAggregate(
                accountId: accountId, date: date, hour: hour, model: model,
                inputTokens: bucket.sum.inputTokens,
                outputTokens: bucket.sum.outputTokens,
                cacheReadTokens: bucket.sum.cacheReadTokens,
                cacheCreation5mTokens: bucket.sum.cacheCreation5mTokens,
                cacheCreation1hTokens: bucket.sum.cacheCreation1hTokens,
                totalCostUSD: bucket.cost
            ))
        }
    }
    // Whatever is left had no samples this time round. Re-attributing history
    // moves samples between accounts, so a stale row would keep charging an
    // account that no longer owns the usage.
    for orphan in byAccount.values { context.delete(orphan) }
}

/// Add one account's increment to its `AccountHourlyAggregate`, creating the
/// row when that account has no usage in the bucket yet. The incremental
/// counterpart to `syncAccountHourlyRows`.
func addToAccountHourlyRow(
    context: ModelContext,
    accountId: String,
    date: String,
    hour: Int,
    model: String,
    breakdown: TokenBreakdown,
    cost: Double
) throws {
    let key = AccountHourlyAggregate.makeKey(
        accountId: accountId, date: date, hour: hour, model: model)
    let existing = try context.fetch(
        FetchDescriptor<AccountHourlyAggregate>(
            predicate: #Predicate<AccountHourlyAggregate> {
                $0.accountDateHourModelKey == key
            }
        )
    ).first
    if let existing {
        existing.inputTokens += breakdown.inputTokens
        existing.outputTokens += breakdown.outputTokens
        existing.cacheReadTokens += breakdown.cacheReadTokens
        existing.cacheCreation5mTokens += breakdown.cacheCreation5mTokens
        existing.cacheCreation1hTokens += breakdown.cacheCreation1hTokens
        existing.totalCostUSD += cost
    } else {
        context.insert(AccountHourlyAggregate(
            accountId: accountId, date: date, hour: hour, model: model,
            inputTokens: breakdown.inputTokens,
            outputTokens: breakdown.outputTokens,
            cacheReadTokens: breakdown.cacheReadTokens,
            cacheCreation5mTokens: breakdown.cacheCreation5mTokens,
            cacheCreation1hTokens: breakdown.cacheCreation1hTokens,
            totalCostUSD: cost
        ))
    }
}
