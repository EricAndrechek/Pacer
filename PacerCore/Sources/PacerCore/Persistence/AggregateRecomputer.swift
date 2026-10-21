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

    public init(
        container: ModelContainer,
        context: ModelContext,
        mode: CostMode = .auto
    ) {
        self.container = container
        self.context = context
        self.mode = mode
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
    /// `snapshots` lets the caller share one projection of the sample table
    /// across every rollup worker in a cycle. The default creates a private
    /// one, which is correct but re-reads the table — the coordinator passes
    /// a shared instance so the three bulk workers read it once between them.
    public func recompute(
        pairs: Set<DateModelPair>,
        pending: [DateModelPair: [TokenSample]] = [:],
        polluted: Set<DateModelPair> = [],
        snapshots: SampleSnapshotCache? = nil
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
            let worker = AggregateBulkWorker(modelContainer: container)
            return try await worker.bulkRecompute(
                pairs: pairs,
                mode: mode,
                pricing: SampleCostCache.current(),
                snapshots: snapshots ?? SampleSnapshotCache(container: container)
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
        // Every path — fast, full and bulk — prices through this one
        // snapshot and `CostCalculator.sampleCost`, so a bucket's cost can't
        // depend on which path last touched it.
        let pricingSnapshot = SampleCostCache.current()
        for pair in pairs {
            stats.pairsRecomputed += 1
            let pendingForPair = pending[pair] ?? []
            let isPolluted = polluted.contains(pair)
            if !isPolluted, !pendingForPair.isEmpty,
               try fastPathApply(pair: pair, pending: pendingForPair,
                                 snapshot: pricingSnapshot, stats: &stats) {
                continue
            }
            try recomputeOne(pair: pair, snapshot: pricingSnapshot, stats: &stats)
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

        var perAccount: [String: AccountBucket] = [:]
        var components = existing.costComponents
        for sample in pending {
            existing.inputTokens += sample.inputTokens
            existing.outputTokens += sample.outputTokens
            existing.cacheReadTokens += sample.cacheReadTokens
            existing.cacheCreation5mTokens += sample.cacheCreation5mTokens
            existing.cacheCreation1hTokens += sample.cacheCreation1hTokens
            let breakdown = sample.breakdown
            let sampleCost = CostCalculator.sampleCost(sample, mode: mode, snapshot: snapshot)
            components += sampleCost.components

            // The account row gets the same increment, from the same cost.
            // Missing this is what made the two rollups drift: this path adds
            // to an existing row rather than rebuilding it, so it never went
            // near `syncAccountRows`, and every incrementally-applied sample
            // landed in the global total and nowhere else.
            //
            // Accumulated here and written once per account below. Writing it
            // per sample cost a fetch each time, and a fetch against a context
            // holding many uncommitted inserts has to merge them — which
            // showed up not here but in the *session* recomputer later in the
            // same cycle, at 36 ms to 1,300 ms. Pending-change churn is
            // charged to whoever fetches next.
            let accountKey = sample.accountId ?? AccountDailyAggregate.unattributedKey
            var bucket = perAccount[accountKey] ?? AccountBucket()
            bucket.sum.add(breakdown)
            bucket.cost += sampleCost.components
            perAccount[accountKey] = bucket
        }
        existing.costComponents = components

        for (accountId, bucket) in perAccount {
            try applyToAccountRow(
                accountId: accountId, date: pair.date, model: pair.model,
                breakdown: bucket.sum, cost: bucket.cost)
        }
        stats.aggregatesUpserted += 1
        stats.fastPathApplied += 1
        return true
    }

    /// Add one sample to its `AccountDailyAggregate`, creating the row if this
    /// account has no usage in the bucket yet.
    private func applyToAccountRow(
        accountId: String, date: String, model: String,
        breakdown: TokenBreakdown, cost: CostComponents
    ) throws {
        let key = AccountDailyAggregate.makeKey(
            accountId: accountId, date: date, model: model)
        let existing = try context.fetch(
            FetchDescriptor<AccountDailyAggregate>(
                predicate: #Predicate<AccountDailyAggregate> {
                    $0.accountDateModelKey == key
                }
            )
        ).first
        if let existing {
            existing.inputTokens += breakdown.inputTokens
            existing.outputTokens += breakdown.outputTokens
            existing.cacheReadTokens += breakdown.cacheReadTokens
            existing.cacheCreation5mTokens += breakdown.cacheCreation5mTokens
            existing.cacheCreation1hTokens += breakdown.cacheCreation1hTokens
            existing.costComponents = existing.costComponents + cost
        } else {
            let row = AccountDailyAggregate(
                accountId: accountId, date: date, model: model,
                inputTokens: breakdown.inputTokens,
                outputTokens: breakdown.outputTokens,
                cacheReadTokens: breakdown.cacheReadTokens,
                cacheCreation5mTokens: breakdown.cacheCreation5mTokens,
                cacheCreation1hTokens: breakdown.cacheCreation1hTokens,
                totalCostUSD: 0
            )
            row.costComponents = cost
            context.insert(row)
        }
    }

    private func recomputeOne(
        pair: DateModelPair, snapshot: PricingTable.Snapshot, stats: inout Stats
    ) throws {
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
            try syncAccountRows(context: context, date: dateString, model: modelString, perAccount: [:])
            return
        }

        let bucket = DailyBucketValues(samples: samples, mode: mode, snapshot: snapshot)
        try syncAccountRows(
            context: context, date: dateString, model: modelString, perAccount: bucket.perAccount)
        if let existing {
            bucket.write(to: existing)
        } else {
            let row = DailyAggregate(date: dateString, model: modelString)
            bucket.write(to: row)
            context.insert(row)
        }
        stats.aggregatesUpserted += 1
    }

}

/// One account's share of a bucket: its tokens and its cost.
struct AccountBucket {
    var sum = TokenBreakdown()
    var cost = CostComponents.zero
}

/// A (date, model) bucket's totals, computed once from its samples.
///
/// Shared by the per-pair path and the bulk worker, which live on different
/// actors: a rollup written by two copies of the same loop drifts depending
/// on which one last touched a bucket. Per-account rows are this bucket's own
/// terms, from the same pass, so within a bucket they cannot drift either.
///
/// Cost is per-sample, never sum-tokens-then-price: tiers apply per request,
/// and `CostMode.auto` decides per entry whether Claude Code's stored cost
/// wins (ccusage iterates entries the same way, `data-loader.ts:638-678`).
struct DailyBucketValues {
    var sum = TokenBreakdown()
    var cost = CostComponents.zero
    var perAccount: [String: AccountBucket] = [:]

    init<S: AggregatableSample>(samples: [S], mode: CostMode, snapshot: PricingTable.Snapshot) {
        for sample in samples {
            let breakdown = sample.breakdown
            sum.add(breakdown)
            let c = CostCalculator.sampleCost(sample, mode: mode, snapshot: snapshot)
            cost += c.components
            let key = sample.accountId ?? AccountDailyAggregate.unattributedKey
            var bucket = perAccount[key] ?? AccountBucket()
            bucket.sum.add(breakdown)
            bucket.cost += c.components
            perAccount[key] = bucket
        }
    }

    func write(to row: DailyAggregate) {
        row.inputTokens = sum.inputTokens
        row.outputTokens = sum.outputTokens
        row.cacheReadTokens = sum.cacheReadTokens
        row.cacheCreation5mTokens = sum.cacheCreation5mTokens
        row.cacheCreation1hTokens = sum.cacheCreation1hTokens
        row.costComponents = cost
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
        pricing: PricingTable.Snapshot,
        snapshots: SampleSnapshotCache
    ) async throws -> AggregateRecomputer.Stats {
        var stats = AggregateRecomputer.Stats(
            pairsRecomputed: 0, aggregatesUpserted: 0, aggregatesDeleted: 0)

        // Samples come from the cycle's shared snapshot rather than a fetch of
        // our own: the hourly and project workers need the identical table and
        // would each re-materialize it in their own context otherwise.
        var grouped: [DateModelPair: [SampleSnapshot.Row]] = [:]
        for s in try snapshots.snapshot().rows {
            grouped[DateModelPair(date: s.date, model: s.model), default: []].append(s)
        }
        let existingAll = try modelContext.fetch(FetchDescriptor<DailyAggregate>())
        var existingByKey: [String: DailyAggregate] = [:]
        for agg in existingAll { existingByKey[agg.dateModelKey] = agg }

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
                try syncAccountRows(
                    context: modelContext, date: pair.date, model: pair.model,
                    perAccount: [:])
                continue
            }

            let bucket = DailyBucketValues(samples: samples, mode: mode, snapshot: pricing)
            try syncAccountRows(
                context: modelContext, date: pair.date, model: pair.model,
                perAccount: bucket.perAccount)
            if let existing {
                bucket.write(to: existing)
            } else {
                let row = DailyAggregate(date: pair.date, model: pair.model)
                bucket.write(to: row)
                modelContext.insert(row)
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
}


/// Bring `AccountDailyAggregate` for one (date, model) bucket in line with the
/// split just computed.
///
/// A free function so the per-bucket path and the bulk worker — which live on
/// different actors with different contexts — call one implementation. The two
/// paths already share cost handling through `AggregatableSample` for exactly
/// this reason: a rollup that is written by two copies of the same logic
/// drifts depending on which one last touched a bucket.
///
/// Deletes rows for accounts the bucket no longer contains, which is not
/// hypothetical: re-attributing history (`make assign-accounts`) moves samples
/// between accounts, and a stale row would keep counting spend against an
/// account that no longer owns it.
func syncAccountRows(
    context: ModelContext,
    date: String,
    model: String,
    perAccount: [String: AccountBucket]
) throws {
    let existing = try context.fetch(
        FetchDescriptor<AccountDailyAggregate>(
            predicate: #Predicate<AccountDailyAggregate> {
                $0.date == date && $0.model == model
            }
        )
    )
    var byAccount: [String: AccountDailyAggregate] = [:]
    for row in existing { byAccount[row.accountId] = row }

    for (accountId, bucket) in perAccount {
        if let row = byAccount.removeValue(forKey: accountId) {
            row.inputTokens = bucket.sum.inputTokens
            row.outputTokens = bucket.sum.outputTokens
            row.cacheReadTokens = bucket.sum.cacheReadTokens
            row.cacheCreation5mTokens = bucket.sum.cacheCreation5mTokens
            row.cacheCreation1hTokens = bucket.sum.cacheCreation1hTokens
            row.costComponents = bucket.cost
        } else {
            let row = AccountDailyAggregate(
                accountId: accountId,
                date: date,
                model: model,
                inputTokens: bucket.sum.inputTokens,
                outputTokens: bucket.sum.outputTokens,
                cacheReadTokens: bucket.sum.cacheReadTokens,
                cacheCreation5mTokens: bucket.sum.cacheCreation5mTokens,
                cacheCreation1hTokens: bucket.sum.cacheCreation1hTokens,
                totalCostUSD: 0
            )
            row.costComponents = bucket.cost
            context.insert(row)
        }
    }
    // Whatever is left had no samples this time round.
    for orphan in byAccount.values { context.delete(orphan) }
}
