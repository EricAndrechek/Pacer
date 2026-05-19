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
    /// Session ids touched this session. Drives `SessionInfoRecomputer`.
    /// Only entries with a non-nil `sessionId` mark this set —
    /// session-less entries (older Claude Code lines) don't get a
    /// SessionInfo row.
    public private(set) var dirtySessionIds: Set<String>
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
    /// Session ids with TokenSamples but no matching `SessionInfo` row
    /// at persister-init time. Same one-shot recovery path as the other
    /// missing-* sets. Bootstrap for users upgrading from a build that
    /// didn't maintain `SessionInfo`.
    private var missingSessionIds: Set<String>
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
        self.dirtySessionIds = []
        self.missingAggregatePairs = []
        self.missingProjectAggregatePairs = []
        self.missingSessionIds = []
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
        if let sid = sample.sessionId, !sid.isEmpty {
            dirtySessionIds.insert(sid)
        }
        pendingInsertCount += 1
        stats.inserted += 1
        if pendingInsertCount >= saveBatchSize {
            try context.save()
            pendingInsertCount = 0
        }
        return true
    }

    /// Reset the batching counter. The coordinator calls this after the
    /// scan loop emits its last entry — it's the signal that pending
    /// inserts will be committed by the cycle's terminal save (or by
    /// the recomputer pass that follows). Within a single ModelContext,
    /// fetches already see uncommitted inserts, so the recomputers
    /// don't need a save here to read them.
    ///
    /// Without the reset, `pendingInsertCount` would accumulate across
    /// cycles (the terminal save lives in the coordinator, not here)
    /// and start tripping the saveBatchSize threshold mid-insert on
    /// every cycle, defeating the "one save per cycle" goal.
    public func flush() throws {
        pendingInsertCount = 0
    }

    /// Reset the dirty-pair tracking after a recompute pass. Doesn't
    /// touch `seenDedupKeys` — those persist across the persister's
    /// lifetime so subsequent inserts in the same session stay
    /// idempotent.
    public func clearDirtyPairs() {
        dirtyPairs.removeAll()
        dirtyProjectDates.removeAll()
        dirtySessionIds.removeAll()
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

    /// Drain and return session ids with TokenSamples but no
    /// `SessionInfo` row at persister-init time. Same one-shot semantics
    /// as the other missing-* drains. The non-empty case fires on first
    /// scan after the SessionInfo recomputer is wired in; subsequent
    /// scans see no gaps and return empty.
    public func consumeMissingSessionIds() -> Set<String> {
        let ids = missingSessionIds
        missingSessionIds.removeAll()
        return ids
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

    /// Merge external session ids into the dirty set. Symmetric to
    /// `addDirtyPairs(_:)` for the SessionInfo rollup path.
    public func addDirtySessionIds(_ ids: Set<String>) {
        dirtySessionIds.formUnion(ids)
    }

    /// Mark every sample-driven aggregate as needing recompute.
    /// Used on startup when ScanCoordinator detects a `costRecomputeVersion`
    /// mismatch — the on-disk aggregates are correct topologically but
    /// were computed with the buggy `sourceCostUSD ?? 0` path, so we
    /// have to rebuild every (date, model), (project, date), and
    /// session bucket from the underlying TokenSamples. Re-uses the
    /// same one-pass scan we already do at preload, just without
    /// subtracting the existing aggregate set.
    public func markEverySampleDirty() throws {
        var descriptor = FetchDescriptor<TokenSample>()
        descriptor.propertiesToFetch = [\.date, \.model, \.projectPath, \.sessionId]
        let samples = try context.fetch(descriptor)
        for sample in samples {
            dirtyPairs.insert(DateModelPair(date: sample.date, model: sample.model))
            let path = sample.projectPath ?? ProjectDailyAggregate.unknownProjectPath
            dirtyProjectDates.insert(ProjectDatePair(projectPath: path, date: sample.date))
            if let sid = sample.sessionId, !sid.isEmpty {
                dirtySessionIds.insert(sid)
            }
        }
    }

    /// Migration: re-canonicalize every existing TokenSample's
    /// `projectPath`. Used on startup when ScanCoordinator detects a
    /// `pathCanonicalizationVersion` mismatch.
    ///
    /// Why this is needed even after a full re-scan: SamplePersister.
    /// insert() de-dupes on `dedupKey` and never updates existing rows
    /// — so a parse-time canonicalizer change doesn't reach
    /// already-stored samples through the normal scan path. We have
    /// to mutate in place.
    ///
    /// Both the OLD and the NEW projectPath are added to dirty
    /// project-date pairs so the recomputer can deletes the old
    /// `agent-…` rollup row and inserts under the canonicalized
    /// parent path. Caller is responsible for triggering the
    /// recomputer.
    @discardableResult
    public func canonicalizeProjectPaths(aliases: [String: String] = [:]) throws -> Int {
        let samples = try context.fetch(FetchDescriptor<TokenSample>())
        var changedCount = 0
        for sample in samples {
            guard let pre = sample.projectPath else { continue }
            // Backfill `originalProjectPath` whenever it's nil. The
            // pre-migration `projectPath` is the best historical
            // value we have for this row — for samples inserted
            // before the field existed it IS the original cwd
            // (because canonicalization wasn't applied yet, or was
            // applied identically), and for samples that have
            // already been canonicalized it's the canonical form,
            // which is at least correct as a fallback the
            // drill-down can group by.
            if sample.originalProjectPath == nil {
                sample.originalProjectPath = pre
            }
            let canonical = ProjectPathCanonicalizer.canonicalize(pre, aliases: aliases)
            guard canonical != pre else { continue }
            sample.projectPath = canonical
            // Both ends of the change need recompute: the old bucket
            // emptied (so the recomputer deletes it) and the new
            // bucket gets the migrated samples.
            dirtyProjectDates.insert(ProjectDatePair(
                projectPath: pre, date: sample.date))
            dirtyProjectDates.insert(ProjectDatePair(
                projectPath: canonical, date: sample.date))
            if let sid = sample.sessionId, !sid.isEmpty {
                dirtySessionIds.insert(sid)
            }
            changedCount += 1
        }
        return changedCount
    }

    /// Scoped variant of `canonicalizeProjectPaths` — only touches
    /// samples whose current `projectPath` matches one of the
    /// alias source paths.
    ///
    /// Why both exist: the full walk is needed on
    /// `pathCanonicalizationVersion` bumps (the canonicalizer code
    /// itself changed; every sample needs re-evaluation). For an
    /// alias-fingerprint mismatch driven by a user merge or the
    /// auto-aliaser, only the new sources' samples can have
    /// changed mapping — fetching by predicate on the indexed
    /// `projectPath` column is orders of magnitude faster than
    /// materializing every TokenSample row.
    ///
    /// Does NOT backfill `originalProjectPath` — that's a one-shot
    /// migration handled by the full walk on the version bump.
    @discardableResult
    public func canonicalizeAffectedSamples(aliases: [String: String]) throws -> Int {
        guard !aliases.isEmpty else { return 0 }
        // The aliases dict is keyed by post-worktree-strip source
        // paths. Samples whose `projectPath` matches one of those
        // strings exactly are the only ones that could resolve to a
        // new canonical now.
        //
        // We fetch per-source instead of a single `IN`. SwiftData's
        // SQL generator rejects `sources.contains(sample.projectPath ?? "")`
        // as `bad LHS` — it wraps the optional column in TERNARY and
        // can't put TERNARY on the left of IN. The per-source shape
        // `$0.projectPath == source` is the same predicate used in
        // `ProjectAggregateRecomputer` and uses the projectPath
        // index; with typical alias-dict sizes (dozens of entries)
        // the round-trip cost is negligible.
        var samples: [TokenSample] = []
        for source in aliases.keys {
            let s = source
            let descriptor = FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> { $0.projectPath == s }
            )
            samples.append(contentsOf: try context.fetch(descriptor))
        }
        var changedCount = 0
        for sample in samples {
            guard let pre = sample.projectPath else { continue }
            let canonical = ProjectPathCanonicalizer.canonicalize(pre, aliases: aliases)
            guard canonical != pre else { continue }
            sample.projectPath = canonical
            dirtyProjectDates.insert(ProjectDatePair(
                projectPath: pre, date: sample.date))
            dirtyProjectDates.insert(ProjectDatePair(
                projectPath: canonical, date: sample.date))
            if let sid = sample.sessionId, !sid.isEmpty {
                dirtySessionIds.insert(sid)
            }
            changedCount += 1
        }
        return changedCount
    }

    /// Mirror of `canonicalizeProjectPaths` for SessionInfo rows.
    /// SessionInfo carries its own `projectPath` column (denormalized
    /// for fast queries) and the recomputer can rebuild it from
    /// underlying samples — but only if the session ids are dirty.
    /// When an alias mutates only `TokenSample.projectPath`, the
    /// SessionInfo recomputer will pick up the new path automatically
    /// once we mark the affected session ids dirty. This helper does
    /// the marking; the recomputer handles the actual rewrite.
    public func markSessionsDirtyForAliasChange() throws {
        var descriptor = FetchDescriptor<TokenSample>()
        descriptor.propertiesToFetch = [\.sessionId]
        let samples = try context.fetch(descriptor)
        for sample in samples {
            if let sid = sample.sessionId, !sid.isEmpty {
                dirtySessionIds.insert(sid)
            }
        }
    }

    private func preloadFromStore() throws {
        // SwiftData materializes every row in a `FetchDescriptor`
        // result as a full `@Model` object by default. With ~500K
        // TokenSample rows on a power user's DB, that's 500K object
        // allocations + 500K Foundation/Core-Data property
        // resolutions just to read five attributes — the dominant
        // cost of the first scan cycle's setup. macOS 14+'s
        // `propertiesToFetch` tells SwiftData to faulting-skip all
        // attributes EXCEPT the listed ones, so reading the un-fetched
        // ones triggers a fault (none of the loops below touch any
        // unlisted attribute).
        //
        // We collect (date, model) and (projectPath, date) pairs in
        // the same pass — free given we already have the row in hand,
        // and it lets us detect missing-aggregate gaps for both
        // rollup tables below.
        var sampleDescriptor = FetchDescriptor<TokenSample>()
        sampleDescriptor.propertiesToFetch = [
            \.dedupKey, \.date, \.model, \.projectPath, \.sessionId
        ]
        let samples = try context.fetch(sampleDescriptor)
        var samplePairs: Set<DateModelPair> = []
        var sampleProjectPairs: Set<ProjectDatePair> = []
        var sampleSessionIds: Set<String> = []
        for sample in samples {
            if let key = sample.dedupKey {
                seenDedupKeys.insert(key)
            }
            samplePairs.insert(DateModelPair(date: sample.date, model: sample.model))
            let path = sample.projectPath ?? ProjectDailyAggregate.unknownProjectPath
            sampleProjectPairs.insert(ProjectDatePair(projectPath: path, date: sample.date))
            if let sid = sample.sessionId, !sid.isEmpty {
                sampleSessionIds.insert(sid)
            }
        }

        // Pairs that have aggregate rows already are *not* gaps; only
        // the difference needs recompute. Aggregate counts are small
        // (per (date, model) and per (project, date)) but still slim
        // the fetch — `DailyAggregate` carries 10+ numeric columns
        // we don't need here.
        var aggDesc = FetchDescriptor<DailyAggregate>()
        aggDesc.propertiesToFetch = [\.date, \.model]
        var aggregatePairs: Set<DateModelPair> = []
        for agg in try context.fetch(aggDesc) {
            aggregatePairs.insert(DateModelPair(date: agg.date, model: agg.model))
        }
        missingAggregatePairs = samplePairs.subtracting(aggregatePairs)

        var projAggDesc = FetchDescriptor<ProjectDailyAggregate>()
        projAggDesc.propertiesToFetch = [\.projectPath, \.date]
        var projectAggregatePairs: Set<ProjectDatePair> = []
        for agg in try context.fetch(projAggDesc) {
            projectAggregatePairs.insert(ProjectDatePair(projectPath: agg.projectPath, date: agg.date))
        }
        missingProjectAggregatePairs = sampleProjectPairs.subtracting(projectAggregatePairs)

        var sessDesc = FetchDescriptor<SessionInfo>()
        sessDesc.propertiesToFetch = [\.sessionId]
        var sessionRowIds: Set<String> = []
        for s in try context.fetch(sessDesc) { sessionRowIds.insert(s.sessionId) }
        missingSessionIds = sampleSessionIds.subtracting(sessionRowIds)
    }
}
