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

/// One `(date, hour, model)` bucket whose `HourlyAggregate` needs
/// recomputing. Hour is the user's local-zone 0–23, matching the
/// `date` column's local-zone semantics on `TokenSample`. Drives
/// `HourlyAggregateRecomputer` — sister of `DateModelPair`, with an
/// extra hour dimension.
public struct DateHourModelTriple: Hashable, Sendable {
    public let date: String
    public let hour: Int
    public let model: String

    public init(date: String, hour: Int, model: String) {
        self.date = date
        self.hour = hour
        self.model = model
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
@ScanActor
public final class SamplePersister {

    private let context: ModelContext
    /// dedupKey → the best `outputTokens` recorded for it so far, across
    /// both the DB at startup and everything inserted this session. Single
    /// source of truth for "have we seen this, and is what we stored the
    /// finished version."
    ///
    /// It maps to a value rather than being a plain `Set` because a repeat
    /// sighting is not necessarily a duplicate to discard. Claude Code
    /// appends the same assistant message to the transcript several times
    /// while it streams, and only the last copy carries the real
    /// `output_tokens` — so a later, larger copy must *upgrade* the row we
    /// already wrote. Keeping first-wins silently discarded 29.5M output
    /// tokens on a 1,697-file corpus (63% of the output actually recorded).
    ///
    /// Comparing on output alone is sufficient, not just convenient: across
    /// that corpus there was no key whose finished copy (`stop_reason` set)
    /// had anything other than the maximum output of its copies, and 6.3% of
    /// keys never get a finished copy at all — so "largest output wins"
    /// decides both cases correctly without persisting a completeness flag.
    ///
    /// Keyed by `DedupIndex.Key` (128-bit SHA-256) rather than the ~57-char
    /// string, so the same map can be written to disk and read back next
    /// launch instead of being rebuilt by walking every row.
    private var bestOutputByKey: [DedupIndex.Key: Int64]
    /// Upgrades discovered this cycle, applied together in `flush()`.
    ///
    /// The obvious implementations are both wrong at scale, and both were
    /// tried: a `FetchDescriptor` per upgraded row pinned a core at 98% and
    /// climbed past 2 GB while repairing a real store, and holding the
    /// `TokenSample` for every key instead — so the upgrade is a dictionary
    /// hit — traded that for **751 MB resident**, because a strong reference
    /// per row stops the context from ever releasing any of them.
    ///
    /// Deferring is what makes both go away: nothing is retained beyond the
    /// entries actually superseded this cycle (a handful on a live scan), and
    /// they resolve in one pass instead of one query each.
    private var pendingUpgrades: [String: ParsedUsageEntry]
    /// Buckets touched this session — the recomputer's input.
    public private(set) var dirtyPairs: Set<DateModelPair>
    /// `(projectPath, date)` buckets touched this session. Drives
    /// `ProjectAggregateRecomputer`. Same shape and semantics as
    /// `dirtyPairs`, just keyed differently.
    public private(set) var dirtyProjectDates: Set<ProjectDatePair>
    /// `(date, hour, model)` buckets touched this session. Drives
    /// `HourlyAggregateRecomputer`. Hour is the user's local-zone
    /// 0–23 computed from `sample.sampledAt`.
    public private(set) var dirtyHourBuckets: Set<DateHourModelTriple>
    /// Session ids touched this session. Drives `SessionInfoRecomputer`.
    /// Only entries with a non-nil `sessionId` mark this set —
    /// session-less entries (older Claude Code lines) don't get a
    /// SessionInfo row.
    public private(set) var dirtySessionIds: Set<String>

    /// Samples inserted this cycle, bucketed by `(date, model)`. Drives
    /// `AggregateRecomputer`'s incremental fast path: when the bucket
    /// already has a `DailyAggregate` row on disk AND the only thing
    /// that dirtied the pair this cycle is one of these inserts, the
    /// recomputer can sum the small `pendingPairSamples[pair]` list
    /// and add it to the existing aggregate — instead of fetching
    /// every TokenSample for `(date, model)` (typically 500+ on an
    /// active bucket, the source of the 400ms-per-pair scan tick we
    /// measured before this change). Cleared in `clearDirtyPairs()`.
    /// Capped at `fastPathPendingCap` per pair; past the cap the pair
    /// is `polluted` and the recomputer falls back to full recompute
    /// (the bulk path's amortized one-fetch model is faster than a
    /// thousand-sample in-memory walk).
    public private(set) var pendingPairSamples: [DateModelPair: [TokenSample]]
    /// `(date, hour, model)` equivalent of `pendingPairSamples`. Same
    /// fast-path semantics on `HourlyAggregateRecomputer`.
    public private(set) var pendingHourSamples: [DateHourModelTriple: [TokenSample]]
    /// `(projectPath, date)` equivalent. Drives the project rollup's
    /// fast path. The project rollup carries extra columns (session
    /// ids, model breakdown, JSON aggregates), so its fast path
    /// merges in a slightly heavier per-sample loop than daily/hourly
    /// — still O(pending.count) instead of O(all samples for pair).
    public private(set) var pendingProjectSamples: [ProjectDatePair: [TokenSample]]
    /// `sessionId` equivalent. Drives the SessionInfo rollup's fast
    /// path. SessionInfo's `topModel` field is the tricky bit: it's
    /// the per-model token leader, which can shift if a new sample
    /// arrives under a different model. The recomputer's fast path
    /// only applies when every pending sample's model equals the
    /// existing row's `topModel` — otherwise it falls through to a
    /// full recompute (full re-fetch of the session's samples).
    public private(set) var pendingSessionSamples: [String: [TokenSample]]
    /// `(date, model)` pairs whose pending list overflowed the per-pair
    /// cap, OR that were marked dirty by something other than an
    /// `insert(_:)` call (recovery drain, `markEverySampleDirty`, alias
    /// migration). For these the partial delta can't be trusted as
    /// representative of "samples since last aggregate write," so the
    /// recomputer must full-recompute. Cleared in `clearDirtyPairs()`.
    public private(set) var pollutedDailyPairs: Set<DateModelPair>
    /// `(date, hour, model)` equivalent of `pollutedDailyPairs`.
    public private(set) var pollutedHourBuckets: Set<DateHourModelTriple>
    /// `(projectPath, date)` equivalent of `pollutedDailyPairs`.
    public private(set) var pollutedProjectPairs: Set<ProjectDatePair>
    /// `sessionId` equivalent of `pollutedDailyPairs`. Populated when
    /// a session is dirtied by something other than a same-model
    /// `insert(_:)` — recovery drain, `markEverySampleDirty`, alias
    /// canonicalize, or an insert whose model differs from the
    /// existing row's `topModel`. Session-recomputer fast path checks
    /// this set first.
    public private(set) var pollutedSessionIds: Set<String>
    /// Cap on per-bucket pending list length. Past this, fast-path
    /// gain (skipping the full fetch) is outweighed by the cost of
    /// iterating the pending list in memory — and on a full
    /// historical scan we accumulate thousands of samples per pair
    /// before the cycle's recomputer runs, where the bulk-worker
    /// path's "one fetch grouped in memory" model already wins.
    private static let fastPathPendingCap = 32
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
    /// `(date, hour, model)` triples with TokenSamples but no matching
    /// `HourlyAggregate` at persister-init time. Same recovery path as
    /// the other `missing*` sets — bootstraps the hourly rollup for
    /// users upgrading from a build that didn't have it. The
    /// `consumeMissingHourBuckets()` drain is one-shot per persister
    /// lifetime; subsequent scans see no gaps and return empty.
    private var missingHourBuckets: Set<DateHourModelTriple>
    /// `HourlyAggregate` rows whose `(date, hour, model)` no longer matches
    /// any sample — see where this is populated. Drained once per persister
    /// lifetime like the `missing*` sets, but it drives deletion rather than
    /// recompute.
    private var strandedHourBuckets: Set<DateHourModelTriple>
    /// Session ids with TokenSamples but no matching `SessionInfo` row
    /// at persister-init time. Same one-shot recovery path as the other
    /// missing-* sets. Bootstrap for users upgrading from a build that
    /// didn't maintain `SessionInfo`.
    private var missingSessionIds: Set<String>
    /// Inserts since last save. Capped to keep WAL size bounded during
    /// long historical scans.
    private var pendingInsertCount: Int
    private let saveBatchSize: Int
    /// Where the on-disk dedup index lives, or nil to disable it (tests and
    /// in-memory stores, which have no container to write into).
    private let indexURL: URL?
    /// Set when the in-memory map has moved past what's on disk.
    private var indexNeedsWrite = false

    public struct Stats: Sendable {
        public var inserted: Int
        public var skippedAsDuplicate: Int
        /// Rows rewritten because a later copy of the same message carried
        /// its finished token counts. Distinct from `skippedAsDuplicate`
        /// (a genuine replay we correctly ignored) — this one changed
        /// stored numbers, so it's worth seeing in the scan log.
        public var upgradedFromPartial: Int = 0
    }

    public private(set) var stats: Stats

    public init(context: ModelContext, saveBatchSize: Int = 1_000,
                indexURL: URL? = nil) throws {
        self.context = context
        self.saveBatchSize = saveBatchSize
        self.indexURL = indexURL
        self.bestOutputByKey = [:]
        self.pendingUpgrades = [:]
        self.dirtyPairs = []
        self.dirtyProjectDates = []
        self.dirtyHourBuckets = []
        self.dirtySessionIds = []
        self.pendingPairSamples = [:]
        self.pendingHourSamples = [:]
        self.pendingProjectSamples = [:]
        self.pendingSessionSamples = [:]
        self.pollutedDailyPairs = []
        self.pollutedHourBuckets = []
        self.pollutedProjectPairs = []
        self.pollutedSessionIds = []
        self.missingAggregatePairs = []
        self.missingProjectAggregatePairs = []
        self.missingHourBuckets = []
        self.strandedHourBuckets = []
        self.missingSessionIds = []
        self.pendingInsertCount = 0
        self.stats = Stats(inserted: 0, skippedAsDuplicate: 0)
    }

    /// Whether the one-time store walk has run for this persister.
    private var preloaded = false

    /// Run the store walk if it hasn't run yet.
    ///
    /// Deferred rather than done in `init` because the walk costs 9-16 s on a
    /// real store and most launches don't need it: three consecutive startups
    /// in a live log ingested NOTHING and spent 15.4 s, 13.0 s and 9.0 s
    /// respectively finding that out. `insert(_:)` calls this, so the dedup
    /// map is always built before the first row that could need it, and a
    /// cycle with nothing to ingest never pays.
    ///
    /// The walk also seeds the integrity sets (missing aggregates, stranded
    /// hourly rows), which are NOT insert-driven — they look for pre-existing
    /// damage. `ScanCoordinator` forces this on a schedule so that keeps
    /// working; see `integrityWalkInterval`.
    public func ensurePreloaded() throws {
        guard !preloaded else { return }
        preloaded = true
        if try loadDedupIndex() { return }
        try preloadFromStore()
        indexNeedsWrite = true
    }

    /// Seed the dedup map from the on-disk index, or report that we can't.
    ///
    /// Returns false — meaning "walk the store instead" — for a missing file,
    /// an unreadable one, or any index that doesn't account for exactly the
    /// rows the store holds. That strictness is the whole safety argument:
    /// the fallback costs seconds, while trusting a stale index double-counts
    /// turns, and this map is what stands between a resumed session and
    /// 2-3x inflated costs.
    ///
    /// Note this seeds ONLY the dedup map. The integrity sets (missing
    /// aggregates, stranded hourly rows) still require the walk, which is why
    /// `ScanCoordinator` forces one daily regardless.
    private func loadDedupIndex() throws -> Bool {
        guard let indexURL, let index = DedupIndex.load(from: indexURL) else { return false }

        // `fetchCount` is a SQL COUNT — it doesn't materialise anything, so
        // validating is cheap even though the thing it guards is expensive.
        let keyed = FetchDescriptor<TokenSample>(
            predicate: #Predicate<TokenSample> { $0.dedupKey != nil })
        let storeCount = try context.fetchCount(keyed)
        guard index.isValid(againstKeyedRowCount: storeCount) else {
            Log.write("SamplePersister",
                      "dedup index covers \(index.rowCount) rows, store has \(storeCount) — rebuilding")
            return false
        }

        bestOutputByKey = index.entries
        // Rows written after the index was saved are still unaccounted for;
        // pick them up so a merely-behind index is usable rather than binned.
        let since = index.watermark        // predicates can't traverse `index.`
        var tail = FetchDescriptor<TokenSample>(
            predicate: #Predicate<TokenSample> { $0.sampledAt > since })
        tail.propertiesToFetch = [\.dedupKey, \.outputTokens]
        var newest = index.watermark
        var tailCount = 0
        try context.enumerate(tail, batchSize: 5_000) { sample in
            tailCount += 1
            if sample.sampledAt > newest { newest = sample.sampledAt }
            guard let key = sample.dedupKey else { return }
            bestOutputByKey[DedupIndex.Key(key)] = sample.outputTokens
        }
        indexWatermark = newest
        if tailCount > 0 { indexNeedsWrite = true }
        Log.write("SamplePersister",
                  "dedup index: \(index.entries.count) entries + \(tailCount) newer row(s)")
        return true
    }

    /// Newest `sampledAt` the in-memory map accounts for.
    private var indexWatermark = Date(timeIntervalSince1970: 0)

    /// How long to let the index lag before rewriting it.
    ///
    /// The file is rewritten whole, so writing every cycle meant re-emitting
    /// 4.4 MB for one new row — 90 ms on every scan, against a 33-80 ms
    /// budget for the entire cycle. Lagging is explicitly safe: the watermark
    /// makes a behind-but-valid index usable, because rows newer than it are
    /// re-walked on load. Worst case after a hard kill is re-walking a few
    /// minutes of rows.
    private static let indexWriteInterval: TimeInterval = 5 * 60
    private var lastIndexWriteAt: Date?

    /// Persist the dedup map so the next launch skips the walk. Called after a
    /// cycle's writes have landed; failures are logged and ignored, since the
    /// index is only ever an optimisation.
    ///
    /// `force` bypasses the throttle — used on shutdown, where the next write
    /// opportunity may be a long time away.
    public func writeDedupIndexIfNeeded(force: Bool = false) {
        guard indexNeedsWrite, let indexURL, preloaded else { return }
        if !force, let last = lastIndexWriteAt,
           Date().timeIntervalSince(last) < Self.indexWriteInterval { return }
        do {
            let keyed = FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> { $0.dedupKey != nil })
            let index = DedupIndex(entries: bestOutputByKey,
                                   rowCount: try context.fetchCount(keyed),
                                   watermark: indexWatermark)
            try index.write(to: indexURL)
            indexNeedsWrite = false
            lastIndexWriteAt = Date()
        } catch {
            Log.write("SamplePersister", "dedup index write failed (harmless): \(error)")
        }
    }

    /// Returns true if the entry was inserted, false if it was a
    /// duplicate. Marks `(date, model)` and `(projectPath, date)` dirty
    /// on insert.
    @discardableResult
    public func insert(_ entry: ParsedUsageEntry) throws -> Bool {
        // Builds the dedup map on the first row that could need it. No-op
        // afterwards, and free on a cycle that inserts nothing.
        try ensurePreloaded()
        if let key = entry.dedupKey {
            let hashed = DedupIndex.Key(key)
            if let bestSoFar = bestOutputByKey[hashed] {
                // Seen before. Only a *larger* output means this is the
                // finished message and what we stored was a mid-stream
                // snapshot; anything else is a true duplicate.
                guard entry.breakdown.outputTokens > bestSoFar else {
                    stats.skippedAsDuplicate += 1
                    return false
                }
                // Recorded now, applied in `flush()`. `bestOutputByKey`
                // updates immediately so a third copy compares against what
                // we've decided to keep, not against what's still on disk.
                pendingUpgrades[key] = entry
                bestOutputByKey[hashed] = entry.breakdown.outputTokens
                stats.upgradedFromPartial += 1
                return false
            }
            bestOutputByKey[hashed] = entry.breakdown.outputTokens
        }
        let sample = TokenSample(from: entry)
        context.insert(sample)
        if sample.sampledAt > indexWatermark { indexWatermark = sample.sampledAt }
        indexNeedsWrite = true
        let pair = DateModelPair(date: sample.date, model: sample.model)
        dirtyPairs.insert(pair)
        let path = sample.projectPath ?? ProjectDailyAggregate.unknownProjectPath
        let projectPair = ProjectDatePair(projectPath: path, date: sample.date)
        dirtyProjectDates.insert(projectPair)
        // Hour bucket uses the same user-local calendar that
        // `TokenSample.date` was formatted under, so a sample at
        // 23:30 local lands in (today, 23) — and the next half-hour's
        // sample, even though wall-clock has rolled to tomorrow, will
        // land correctly under (tomorrow, 0). `Calendar.current` is
        // safe to call here; we're on MainActor.
        let hour = Self.localHour(of: sample)
        let hourBucket = DateHourModelTriple(
            date: sample.date, hour: hour, model: sample.model)
        dirtyHourBuckets.insert(hourBucket)
        if let sid = sample.sessionId, !sid.isEmpty {
            dirtySessionIds.insert(sid)
        }
        // Track the sample for the recomputers' fast path. We append
        // until the pair crosses the per-bucket cap, then mark the
        // pair polluted and drop the pending list so future inserts
        // for the same pair don't keep growing it. Polluted pairs fall
        // through to the existing full-recompute path on flush.
        if !pollutedDailyPairs.contains(pair) {
            var list = pendingPairSamples[pair, default: []]
            list.append(sample)
            if list.count > Self.fastPathPendingCap {
                pollutedDailyPairs.insert(pair)
                pendingPairSamples[pair] = nil
            } else {
                pendingPairSamples[pair] = list
            }
        }
        if !pollutedHourBuckets.contains(hourBucket) {
            var list = pendingHourSamples[hourBucket, default: []]
            list.append(sample)
            if list.count > Self.fastPathPendingCap {
                pollutedHourBuckets.insert(hourBucket)
                pendingHourSamples[hourBucket] = nil
            } else {
                pendingHourSamples[hourBucket] = list
            }
        }
        if !pollutedProjectPairs.contains(projectPair) {
            var list = pendingProjectSamples[projectPair, default: []]
            list.append(sample)
            if list.count > Self.fastPathPendingCap {
                pollutedProjectPairs.insert(projectPair)
                pendingProjectSamples[projectPair] = nil
            } else {
                pendingProjectSamples[projectPair] = list
            }
        }
        if let sid = sample.sessionId, !sid.isEmpty,
           !pollutedSessionIds.contains(sid) {
            var list = pendingSessionSamples[sid, default: []]
            list.append(sample)
            if list.count > Self.fastPathPendingCap {
                pollutedSessionIds.insert(sid)
                pendingSessionSamples[sid] = nil
            } else {
                pendingSessionSamples[sid] = list
            }
        }
        pendingInsertCount += 1
        stats.inserted += 1
        if pendingInsertCount >= saveBatchSize {
            try context.save()
            pendingInsertCount = 0
        }
        return true
    }

    /// Apply every upgrade collected this cycle in a single pass.
    ///
    /// One fetch, filtered in memory, instead of a query per row — and the
    /// materialized rows are released as soon as this returns, which is the
    /// whole point. `propertiesToFetch` can't help here: applying an upgrade
    /// writes six columns and reads four more for bucket invalidation.
    ///
    /// Every bucket the old numbers fed has to be invalidated too. The rollup
    /// recomputers have a fast path that *adds* pending samples onto the
    /// existing aggregate; that's a delta, and a delta is wrong when a row
    /// already counted changes underneath it. Marking the affected buckets
    /// polluted forces the full-recompute path for exactly those.
    private func applyPendingUpgrades() throws {
        guard !pendingUpgrades.isEmpty else { return }
        let wanted = pendingUpgrades
        var applied = 0
        for sample in try context.fetch(FetchDescriptor<TokenSample>()) {
            guard let key = sample.dedupKey, let entry = wanted[key] else { continue }
            sample.inputTokens = entry.breakdown.inputTokens
            sample.outputTokens = entry.breakdown.outputTokens
            sample.cacheReadTokens = entry.breakdown.cacheReadTokens
            sample.cacheCreation5mTokens = entry.breakdown.cacheCreation5mTokens
            sample.cacheCreation1hTokens = entry.breakdown.cacheCreation1hTokens
            sample.sourceCostUSD = entry.storedCostUSD

            let pair = DateModelPair(date: sample.date, model: sample.model)
            dirtyPairs.insert(pair)
            pollutedDailyPairs.insert(pair)
            pendingPairSamples[pair] = nil

            let path = sample.projectPath ?? ProjectDailyAggregate.unknownProjectPath
            let projectPair = ProjectDatePair(projectPath: path, date: sample.date)
            dirtyProjectDates.insert(projectPair)
            pollutedProjectPairs.insert(projectPair)
            pendingProjectSamples[projectPair] = nil

            let hourBucket = DateHourModelTriple(
                date: sample.date, hour: Self.localHour(of: sample), model: sample.model)
            dirtyHourBuckets.insert(hourBucket)
            pollutedHourBuckets.insert(hourBucket)
            pendingHourSamples[hourBucket] = nil

            if let sid = sample.sessionId, !sid.isEmpty {
                dirtySessionIds.insert(sid)
                pollutedSessionIds.insert(sid)
                pendingSessionSamples[sid] = nil
            }
            applied += 1
            if applied == wanted.count { break }   // nothing left to find
        }
        pendingUpgrades.removeAll(keepingCapacity: false)
    }

    /// Hourly rows with no samples behind them, drained once. The caller
    /// deletes them; leaving them makes every hourly total read high.
    public func consumeStrandedHourBuckets() -> Set<DateHourModelTriple> {
        let out = strandedHourBuckets
        strandedHourBuckets = []
        return out
    }

    /// Delete the given `HourlyAggregate` rows. Returns how many went.
    @discardableResult
    public func deleteHourAggregates(_ buckets: Set<DateHourModelTriple>) throws -> Int {
        guard !buckets.isEmpty else { return 0 }
        var deleted = 0
        for agg in try context.fetch(FetchDescriptor<HourlyAggregate>()) {
            let key = DateHourModelTriple(date: agg.date, hour: agg.hour, model: agg.model)
            guard buckets.contains(key) else { continue }
            context.delete(agg)
            deleted += 1
        }
        return deleted
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
        try applyPendingUpgrades()
        pendingInsertCount = 0
    }

    /// Reset the dirty-pair tracking after a recompute pass. Doesn't
    /// touch `seenDedupKeys` — those persist across the persister's
    /// lifetime so subsequent inserts in the same session stay
    /// idempotent.
    ///
    /// Also clears the per-cycle pending-sample dictionaries + their
    /// polluted-pair shadow sets. The recomputers read these during
    /// the cycle's tail to decide between the incremental fast path
    /// and a full recompute; once the cycle's terminal save lands,
    /// they've served their purpose and a new cycle starts fresh.
    public func clearDirtyPairs() {
        dirtyPairs.removeAll()
        dirtyProjectDates.removeAll()
        dirtyHourBuckets.removeAll()
        dirtySessionIds.removeAll()
        pendingPairSamples.removeAll()
        pendingHourSamples.removeAll()
        pendingProjectSamples.removeAll()
        pendingSessionSamples.removeAll()
        pollutedDailyPairs.removeAll()
        pollutedHourBuckets.removeAll()
        pollutedProjectPairs.removeAll()
        pollutedSessionIds.removeAll()
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

    /// Drain and return the (date, hour, model) triples missing
    /// `HourlyAggregate` rows at persister-init time. Same one-shot
    /// semantics as the other `consumeMissing*` drains. Non-empty on
    /// first scan after the schema is extended (bootstrap of the new
    /// rollup); empty on subsequent scans.
    public func consumeMissingHourBuckets() -> Set<DateHourModelTriple> {
        let triples = missingHourBuckets
        missingHourBuckets.removeAll()
        return triples
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
    ///
    /// Pollutes each pair so the recomputer's incremental fast path
    /// won't apply — these pairs need a full re-aggregation because
    /// either there's no `DailyAggregate` row yet (recovery drain) or
    /// the existing row's cost numbers were computed under buggy logic
    /// (`markEverySampleDirty` after a cost-version bump). The pending
    /// sample list from a co-occurring `insert(_:)` is partial in both
    /// cases and would land the wrong total if added blindly.
    public func addDirtyPairs(_ pairs: Set<DateModelPair>) {
        dirtyPairs.formUnion(pairs)
        pollutedDailyPairs.formUnion(pairs)
    }

    /// Merge external project-date pairs into the dirty set. Symmetric
    /// to `addDirtyPairs(_:)` for the project rollup path. Pollutes
    /// each pair so the project recomputer's fast path won't apply —
    /// same reasoning as `addDirtyPairs(_:)`.
    public func addDirtyProjectDates(_ pairs: Set<ProjectDatePair>) {
        dirtyProjectDates.formUnion(pairs)
        pollutedProjectPairs.formUnion(pairs)
    }

    /// Merge external hour-bucket triples into the dirty set. Symmetric
    /// to `addDirtyPairs(_:)` for the hourly rollup path. Used to fold
    /// `missingHourBuckets` into `dirtyHourBuckets` from ScanCoordinator.
    /// Pollutes each triple — same reasoning as `addDirtyPairs(_:)`.
    public func addDirtyHourBuckets(_ triples: Set<DateHourModelTriple>) {
        dirtyHourBuckets.formUnion(triples)
        pollutedHourBuckets.formUnion(triples)
    }

    /// Merge external session ids into the dirty set. Symmetric to
    /// `addDirtyPairs(_:)` for the SessionInfo rollup path. Pollutes
    /// each session id so the recomputer's fast path won't apply —
    /// the existing `SessionInfo` row's `topModel` / cumulative
    /// columns can't be trusted under recovery semantics.
    public func addDirtySessionIds(_ ids: Set<String>) {
        dirtySessionIds.formUnion(ids)
        pollutedSessionIds.formUnion(ids)
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
        // sampledAt is needed here too — hour bucket derives from it.
        // Cheap to fetch alongside the existing slim columns and worth
        // the cost; without it the hourly rollup would not rebuild on
        // a cost-recompute version bump and every HourlyAggregate
        // would silently keep its pre-bump cost numbers.
        descriptor.propertiesToFetch = [\.date, \.model, \.projectPath, \.sessionId, \.sampledAt, \.localHour]
        // Batched for the same reason the preload is: this walks the whole
        // table, and materializing it all at once is the cost (see
        // `preloadFromStore`).
        try context.enumerate(descriptor, batchSize: 5_000) { sample in
            // Backfill the stored hour while we're walking every row anyway.
            // Rows written before the field existed carry -1 and would keep
            // deriving — and drifting — otherwise.
            if sample.localHour < 0 {
                sample.localHour = Self.localHour(of: sample.sampledAt)
            }
            let pair = DateModelPair(date: sample.date, model: sample.model)
            dirtyPairs.insert(pair)
            // Pollute so any concurrent insert(_:) in the same cycle
            // doesn't trip the recomputer's fast path. The whole reason
            // this method runs is that the existing aggregate rows
            // have wrong cost — incrementally ADDING to them would
            // compound the error. Full recompute is mandatory.
            pollutedDailyPairs.insert(pair)
            let path = sample.projectPath ?? ProjectDailyAggregate.unknownProjectPath
            let projectPair = ProjectDatePair(projectPath: path, date: sample.date)
            dirtyProjectDates.insert(projectPair)
            pollutedProjectPairs.insert(projectPair)
            let hour = Self.localHour(of: sample)
            let hourBucket = DateHourModelTriple(
                date: sample.date, hour: hour, model: sample.model)
            dirtyHourBuckets.insert(hourBucket)
            pollutedHourBuckets.insert(hourBucket)
            if let sid = sample.sessionId, !sid.isEmpty {
                dirtySessionIds.insert(sid)
                pollutedSessionIds.insert(sid)
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
        // Batched — same whole-table shape as the preload.
        var changedCount = 0
        // `continue` becomes `return` — the body is a per-row closure now.
        try context.enumerate(FetchDescriptor<TokenSample>(), batchSize: 5_000) { sample in
            guard let pre = sample.projectPath else { return }
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
            guard canonical != pre else { return }
            sample.projectPath = canonical
            // Both ends of the change need recompute: the old bucket
            // emptied (so the recomputer deletes it) and the new
            // bucket gets the migrated samples. Both also pollute the
            // project pair — the underlying TokenSample rows shifted
            // buckets, so the existing aggregate's totals no longer
            // reflect what's actually in the new bucket.
            let prePair = ProjectDatePair(projectPath: pre, date: sample.date)
            let canonicalPair = ProjectDatePair(projectPath: canonical, date: sample.date)
            dirtyProjectDates.insert(prePair)
            dirtyProjectDates.insert(canonicalPair)
            pollutedProjectPairs.insert(prePair)
            pollutedProjectPairs.insert(canonicalPair)
            if let sid = sample.sessionId, !sid.isEmpty {
                dirtySessionIds.insert(sid)
                pollutedSessionIds.insert(sid)
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
            // Same pollution semantics as the full-walk variant —
            // samples are shifting buckets so neither end's existing
            // aggregate represents the post-migration state.
            let prePair = ProjectDatePair(projectPath: pre, date: sample.date)
            let canonicalPair = ProjectDatePair(projectPath: canonical, date: sample.date)
            dirtyProjectDates.insert(prePair)
            dirtyProjectDates.insert(canonicalPair)
            pollutedProjectPairs.insert(prePair)
            pollutedProjectPairs.insert(canonicalPair)
            if let sid = sample.sessionId, !sid.isEmpty {
                dirtySessionIds.insert(sid)
                pollutedSessionIds.insert(sid)
            }
            changedCount += 1
        }
        return changedCount
    }

    /// User-local 0–23 hour-of-day for a `sampledAt` instant. Matches
    /// the local-zone semantics of `TokenSample.date` so a (date,
    /// hour) pair always agrees with the row it came from.
    /// `Calendar.current` is cheap on MainActor.
    fileprivate static func localHour(of date: Date) -> Int {
        Calendar.current.component(.hour, from: date)
    }

    /// A sample's local hour, preferring the value stored at insert.
    ///
    /// Deriving it fresh is what let historical buckets drift: the derivation
    /// depends on the calendar in effect at read time, so a DST or timezone
    /// change re-buckets old samples. `-1` marks rows written before the field
    /// existed; those still derive, and the `costRecomputeVersion` walk
    /// backfills them.
    fileprivate static func localHour(of sample: TokenSample) -> Int {
        sample.localHour >= 0 ? sample.localHour : localHour(of: sample.sampledAt)
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
        // sampledAt joins the slim column list so we can compute the
        // hour-bucket triple in the same one-pass scan that builds the
        // other dirty/missing sets. Without it the hourly rollup would
        // need a second full fetch — costly during preload for power
        // users with ~500K rows.
        sampleDescriptor.propertiesToFetch = [
            // outputTokens rides along so `bestOutputByKey` knows whether a
            // stored row is a finished message or a mid-stream snapshot
            // that a later scan can still upgrade.
            \.dedupKey, \.date, \.model, \.projectPath, \.sessionId, \.sampledAt, \.outputTokens,
            \.localHour
        ]
        // Fetched through a throwaway context, NOT the persister's own.
        //
        // This walks every TokenSample to build the dedup map and the
        // dirty/missing bucket sets — all plain values. Fetching it through
        // the long-lived context registers all of them there permanently,
        // and SwiftData charges roughly 890 bytes of bookkeeping per row on
        // top of the row itself (backing data, _ModelMetadata, a property
        // snapshot array, an observation registrar, a weak-ref slot). Heap-
        // profiled on a real 189k-row store that was ~500 MB resident at
        // idle, for objects nothing ever reads again.
        //
        // A scratch context frees the lot when it goes out of scope.
        let scratchContext = ModelContext(context.container)
        var samplePairs: Set<DateModelPair> = []
        var sampleProjectPairs: Set<ProjectDatePair> = []
        var sampleHourBuckets: Set<DateHourModelTriple> = []
        var sampleSessionIds: Set<String> = []
        var rowCount = 0
        // The walk covers everything currently stored, so its newest row
        // becomes the index watermark.
        var maxSampledAt = Date(timeIntervalSince1970: 0)
        let tWalk = Date()
        // `enumerate`, not `fetch`. Instrumented on a real 189k-row store, the
        // eager fetch was **11,564 ms of a 12,545 ms startup** — pure
        // materialization; the loop below is only 853 ms of it and the
        // aggregate-gap queries 128 ms. Batching drains each chunk before
        // pulling the next, so the whole table never exists as objects at once.
        try scratchContext.enumerate(sampleDescriptor, batchSize: 5_000) { sample in
            rowCount += 1
            if sample.sampledAt > maxSampledAt { maxSampledAt = sample.sampledAt }
            if let key = sample.dedupKey {
                // Seed with what's stored so a finished copy arriving in a
                // later session can still recognise a partial row and
                // upgrade it, not just skip it as a duplicate.
                bestOutputByKey[DedupIndex.Key(key)] = sample.outputTokens
            }
            samplePairs.insert(DateModelPair(date: sample.date, model: sample.model))
            let path = sample.projectPath ?? ProjectDailyAggregate.unknownProjectPath
            sampleProjectPairs.insert(ProjectDatePair(projectPath: path, date: sample.date))
            let hour = Self.localHour(of: sample)
            sampleHourBuckets.insert(DateHourModelTriple(
                date: sample.date, hour: hour, model: sample.model))
            if let sid = sample.sessionId, !sid.isEmpty {
                sampleSessionIds.insert(sid)
            }
        }

        let walkMs = Date().timeIntervalSince(tWalk) * 1000
        let tGaps = Date()
        defer {
            // Startup's `prep` phase is the largest cost on a warm store;
            // splitting it means the next person tuning this doesn't guess.
            Log.write("SamplePersister", String(
                format: "preload: %d rows — walk %.0fms · gaps %.0fms",
                rowCount, walkMs, Date().timeIntervalSince(tGaps) * 1000))
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

        var hourAggDesc = FetchDescriptor<HourlyAggregate>()
        hourAggDesc.propertiesToFetch = [\.date, \.hour, \.model]
        var hourAggregateTriples: Set<DateHourModelTriple> = []
        for agg in try context.fetch(hourAggDesc) {
            hourAggregateTriples.insert(DateHourModelTriple(
                date: agg.date, hour: agg.hour, model: agg.model))
        }
        missingHourBuckets = sampleHourBuckets.subtracting(hourAggregateTriples)
        // …and the other direction: hourly rows with no samples behind them.
        //
        // Unlike `date`, which `TokenSample` stores at insert, the hour is
        // DERIVED from `sampledAt` through the current calendar. Anything that
        // shifts that derivation by an hour — a DST boundary, a timezone
        // change, an older build computing it differently — re-buckets a
        // sample and strands the row it used to live in. The recomputer can't
        // clean those up: it only deletes a bucket that is in its dirty set,
        // and a bucket with no samples never gets marked dirty by an insert.
        //
        // Found on a real store as 34 stranded rows carrying 1,915,526 output
        // tokens — the hourly rollup reading ~1% high while the daily rollup,
        // which buckets on the stored `date`, matched the samples exactly.
        // Each stranded row held the sample count belonging to the hour after
        // it, which is the one-hour-shift signature.
        //
        // Only the hourly rollup needs this, and the reason is worth keeping:
        // daily buckets on stored `date`+`model` and SessionInfo on stored
        // `sessionId`, none of which can move. The project rollup DOES bucket
        // on a mutable column, but `canonicalizeProjectPaths` folds the old
        // AND new pair into the dirty set on every rewrite, so its emptied
        // bucket gets deleted the normal way. Hourly was the one key derived
        // at read time with nothing tracking the move. Verified on a real
        // store: 0 stranded daily, 0 project, 0 session.
        //
        // Both sets are already in hand here, so detecting them is free.
        strandedHourBuckets = hourAggregateTriples.subtracting(sampleHourBuckets)

        var sessDesc = FetchDescriptor<SessionInfo>()
        sessDesc.propertiesToFetch = [\.sessionId]
        var sessionRowIds: Set<String> = []
        for s in try context.fetch(sessDesc) { sessionRowIds.insert(s.sessionId) }
        missingSessionIds = sampleSessionIds.subtracting(sessionRowIds)
    }
}
