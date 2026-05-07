import Foundation
import SwiftData

/// One `(date, model)` bucket whose `DailyAggregate` needs recomputing
/// because its underlying samples changed. Tracked by `SamplePersister`
/// during a scan and handed to `AggregateRecomputer` afterwards so the
/// rollup pass touches only the dirty rows, never the whole table.
public struct DateModelPair: Hashable, Sendable {
    public let date: String
    public let model: String

    public init(date: String, model: String) {
        self.date = date
        self.model = model
    }
}

/// One `(projectPath, date)` bucket whose `ProjectDailyAggregate` needs
/// recomputing. Same dirty-tracking shape as `DateModelPair` but for
/// the project-dimensional rollup. Samples missing a `projectPath` use
/// `ProjectDailyAggregate.unknownProjectPath` so every sample lands in
/// some bucket.
public struct ProjectDatePair: Hashable, Sendable {
    public let projectPath: String
    public let date: String

    public init(projectPath: String, date: String) {
        self.projectPath = projectPath
        self.date = date
    }
}

/// Idempotent inserter for `TokenSample` rows. The hot loop in a full
/// historical scan will call `insert(_:)` ~500K times on the user's
/// dataset, so the dedup check has to be O(1). Pre-loads every
/// existing `dedupKey` into an in-memory Set on init, then never touches
/// the DB for dedup again — strictly in-memory comparison.
///
/// `dedupKey == nil` rows (entries lacking either messageId or
/// requestId) bypass the dedup pass and are always inserted. ccusage
/// makes the same call: no key, no dedup, accept the entry. The cost is
/// duplicate counting on the small fraction of pre-`requestId` lines; we
/// accept it because the alternative (matching on timestamp + token
/// counts) creates false-positive collisions.
@MainActor
public final class SamplePersister {

    private let context: ModelContext
    /// Existing dedupKeys seen in the DB at startup, plus everything
    /// inserted this session. Single source of truth for "have we seen
    /// this already." 500K entries × ~40 bytes = ~20MB — fine in RAM.
    private var seenDedupKeys: Set<String>
    /// Buckets touched this session — the recomputer's input.
    public private(set) var dirtyPairs: Set<DateModelPair>
    /// `(projectPath, date)` buckets touched this session. Drives
    /// `ProjectAggregateRecomputer`. Same shape and semantics as
    /// `dirtyPairs`, just keyed differently.
    public private(set) var dirtyProjectDates: Set<ProjectDatePair>
    /// (date, model) pairs that have TokenSamples in the DB but no
    /// matching DailyAggregate at persister-init time. These are
    /// integrity gaps that the dirty-pair tracking will not catch: a
    /// re-scan of historical JSONL hits dedup on every entry and never
    /// marks the pair dirty, so the recomputer never rebuilds the
    /// missing aggregate. ScanCoordinator drains this set on its first
    /// scan cycle and feeds the pairs to the recomputer, fixing the
    /// gap automatically. One-shot: `consumeMissingAggregatePairs()`
    /// returns and clears.
    private var missingAggregatePairs: Set<DateModelPair>
    /// `(projectPath, date)` pairs with TokenSamples but no matching
    /// `ProjectDailyAggregate` at persister-init time. Same recovery
    /// path as `missingAggregatePairs` — drained once on first scan
    /// after the worker is constructed and folded into
    /// `dirtyProjectDates`. This is the bootstrap for users upgrading
    /// from a build that didn't have `ProjectDailyAggregate`.
    private var missingProjectAggregatePairs: Set<ProjectDatePair>
    /// Inserts since last save. Capped to keep WAL size bounded during
    /// long historical scans.
    private var pendingInsertCount: Int
    private let saveBatchSize: Int

    public struct Stats: Sendable {
        public var inserted: Int
        public var skippedAsDuplicate: Int
    }

    public private(set) var stats: Stats

    public init(context: ModelContext, saveBatchSize: Int = 1_000) throws {
        self.context = context
        self.saveBatchSize = saveBatchSize
        self.seenDedupKeys = []
        self.dirtyPairs = []
        self.dirtyProjectDates = []
        self.missingAggregatePairs = []
        self.missingProjectAggregatePairs = []
        self.pendingInsertCount = 0
        self.stats = Stats(inserted: 0, skippedAsDuplicate: 0)
        try preloadFromStore()
    }

    /// Returns true if the entry was inserted, false if it was a
    /// duplicate. Marks `(date, model)` and `(projectPath, date)` dirty
    /// on insert.
    @discardableResult
    public func insert(_ entry: ParsedUsageEntry) throws -> Bool {
        if let key = entry.dedupKey {
            if seenDedupKeys.contains(key) {
                stats.skippedAsDuplicate += 1
                return false
            }
            seenDedupKeys.insert(key)
        }
        let sample = TokenSample(from: entry)
        context.insert(sample)
        dirtyPairs.insert(DateModelPair(date: sample.date, model: sample.model))
        let path = sample.projectPath ?? ProjectDailyAggregate.unknownProjectPath
        dirtyProjectDates.insert(ProjectDatePair(projectPath: path, date: sample.date))
        pendingInsertCount += 1
        stats.inserted += 1
        if pendingInsertCount >= saveBatchSize {
            try context.save()
            pendingInsertCount = 0
        }
        return true
    }

    /// Flush any pending inserts. Call after the scan completes (and
    /// before the recomputer runs) so the recomputer's fetches see
    /// every row.
    public func flush() throws {
        if pendingInsertCount > 0 {
            try context.save()
            pendingInsertCount = 0
        }
    }

    /// Reset the dirty-pair tracking after a recompute pass. Doesn't
    /// touch `seenDedupKeys` — those persist across the persister's
    /// lifetime so subsequent inserts in the same session stay
    /// idempotent.
    public func clearDirtyPairs() {
        dirtyPairs.removeAll()
        dirtyProjectDates.removeAll()
    }

    /// Drain and return the (date, model) pairs that have TokenSamples
    /// but no DailyAggregate. ScanCoordinator calls this once per
    /// persister lifetime and folds the pairs into `dirtyPairs` so the
    /// recomputer rebuilds them. Subsequent calls return an empty set.
    public func consumeMissingAggregatePairs() -> Set<DateModelPair> {
        let pairs = missingAggregatePairs
        missingAggregatePairs.removeAll()
        return pairs
    }

    /// Drain and return the (project, date) pairs missing
    /// `ProjectDailyAggregate` rows at persister-init time. Same one-
    /// shot semantics as `consumeMissingAggregatePairs()`. The
    /// non-empty case fires on first scan after the schema is
    /// extended; subsequent scans see no gaps and return empty.
    public func consumeMissingProjectAggregatePairs() -> Set<ProjectDatePair> {
        let pairs = missingProjectAggregatePairs
        missingProjectAggregatePairs.removeAll()
        return pairs
    }

    /// Merge external pairs into the dirty set. Only used to fold
    /// `missingAggregatePairs` into `dirtyPairs` from ScanCoordinator;
    /// in normal operation pairs are added by `insert(_:)`.
    public func addDirtyPairs(_ pairs: Set<DateModelPair>) {
        dirtyPairs.formUnion(pairs)
    }

    /// Merge external project-date pairs into the dirty set. Symmetric
    /// to `addDirtyPairs(_:)` for the project rollup path.
    public func addDirtyProjectDates(_ pairs: Set<ProjectDatePair>) {
        dirtyProjectDates.formUnion(pairs)
    }

    private func preloadFromStore() throws {
        // SwiftData doesn't expose partial-attribute fetch (CD's
        // NSDictionaryResultType has no equivalent), so we materialize
        // every TokenSample to read its dedupKey. On a 500K-row store
        // this allocates ~500K @Model objects but they're discarded as
        // soon as we've extracted the key — autoreleasepool keeps peak
        // memory bounded. We also collect the (date, model) and
        // (projectPath, date) pairs in the same pass — it's free
        // given we already have the row in hand, and it lets us detect
        // missing-aggregate gaps for both rollup tables below.
        let samples = try context.fetch(FetchDescriptor<TokenSample>())
        var samplePairs: Set<DateModelPair> = []
        var sampleProjectPairs: Set<ProjectDatePair> = []
        for sample in samples {
            if let key = sample.dedupKey {
                seenDedupKeys.insert(key)
            }
            samplePairs.insert(DateModelPair(date: sample.date, model: sample.model))
            let path = sample.projectPath ?? ProjectDailyAggregate.unknownProjectPath
            sampleProjectPairs.insert(ProjectDatePair(projectPath: path, date: sample.date))
        }

        // Pairs that have aggregate rows already are *not* gaps; only
        // the difference needs recompute. Aggregate counts are small
        // (per (date, model) and per (project, date)).
        let aggregates = try context.fetch(FetchDescriptor<DailyAggregate>())
        var aggregatePairs: Set<DateModelPair> = []
        for agg in aggregates {
            aggregatePairs.insert(DateModelPair(date: agg.date, model: agg.model))
        }
        missingAggregatePairs = samplePairs.subtracting(aggregatePairs)

        let projectAggregates = try context.fetch(FetchDescriptor<ProjectDailyAggregate>())
        var projectAggregatePairs: Set<ProjectDatePair> = []
        for agg in projectAggregates {
            projectAggregatePairs.insert(ProjectDatePair(projectPath: agg.projectPath, date: agg.date))
        }
        missingProjectAggregatePairs = sampleProjectPairs.subtracting(projectAggregatePairs)
    }
}
