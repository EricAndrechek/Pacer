import Foundation
import SwiftData

/// Orchestrates one scan cycle and (in `runForever`) keeps cycling on
/// FSEvents triggers. Owns no parsing logic — just glues together the
/// resolver, scanner, persister, recomputer, probe, and watcher.
///
/// **Cursor + persister hoisting:** Each cycle loads per-file byte-offset
/// cursors from the SwiftData store, hands them to the scanner, and
/// persists the updates afterwards. The `SamplePersister` is constructed
/// once per coordinator lifetime — its in-memory dedup Set is the
/// performance-critical state and rebuilding it every cycle (the original
/// design) was loading every `TokenSample` from disk on every FSEvent.
///
/// The full-vs-incremental decision keys off `ClaudeCodeMetaKey.scanVersion`:
/// when the on-disk version doesn't match this binary's
/// `currentScanVersion`, we wipe cursors so every JSONL gets re-read
/// (the persister still rejects existing rows by dedupKey).
@MainActor
public final class ScanCoordinator {

    /// Bump this constant when a parser/aggregation change requires
    /// re-reading historical JSONL. The daemon will detect the version
    /// drift on next launch and wipe cursors so every file is re-read.
    /// Bump when a parsing change should reprocess every JSONL line.
    /// The scan compares this to the stored value in
    /// `ClaudeCodeMeta.scanVersion`; on mismatch it forces a full
    /// re-scan (every cursor reset to byte offset 0) so all samples
    /// re-parse with the new logic.
    ///
    /// History:
    /// - "1" — initial release.
    /// - "2" — `JSONLParser` now runs `cwd` through
    ///         `ProjectPathCanonicalizer` so worktree-spawned agents
    ///         attribute back to the parent project. Forced re-scan
    ///         updates `TokenSample.projectPath` on the existing
    ///         rows, then the cost-recompute pass on the same cycle
    ///         rebuilds `ProjectDailyAggregate` rows under the new
    ///         project keys.
    public static let currentScanVersion = "2"

    /// Bumped when a code change requires recomputing the cost columns
    /// on existing aggregates. ScanCoordinator detects a mismatch on
    /// startup and folds every known sample's (date,model),
    /// (project,date), and sessionId into the persister's dirty set
    /// — the recomputers then rebuild every aggregate row from the
    /// underlying TokenSamples.
    ///
    /// History:
    /// - "1" — initial release.
    /// - "2" — fixed `ProjectAggregateRecomputer` and
    ///         `SessionInfoRecomputer` to honor cost mode + pricing
    ///         (previously they collapsed to `sourceCostUSD ?? 0`
    ///         and showed $0 for every CC line without a stored cost).
    public static let currentCostRecomputeVersion = "2"

    /// Version of the project-path canonicalization rules. Bumped when
    /// a parsing/canonicalization change requires updating in-place
    /// the `projectPath` field on every existing TokenSample row —
    /// because the dedup-skip path during a full re-scan otherwise
    /// never reaches the field. Triggers a one-pass migration on
    /// first cycle of every persister lifetime where the stored
    /// version doesn't match.
    ///
    /// History:
    /// - "1" — strip `/.claude/worktrees/<id>` and `/.worktrees/<id>`
    ///         segments so subagent worktrees attribute back to the
    ///         parent project.
    public static let currentPathCanonicalizationVersion = "1"

    public struct Configuration: Sendable {
        public var costMode: CostMode
        public var watcherMode: JSONLWatcher.Mode
        public var probeStatsCache: Bool
        public var saveBatchSize: Int
        /// Cadence/jitter/backoff knobs for OAuth polling. The poller
        /// only runs when `oauthClient` is non-nil at coordinator
        /// init; passing a configuration here without a client is a
        /// no-op (matches the test default — no network calls).
        public var oauthPolling: OAuthPoller.Configuration

        public init(
            costMode: CostMode = .auto,
            watcherMode: JSONLWatcher.Mode = .live(latencySeconds: 0.5, backstopInterval: 60),
            probeStatsCache: Bool = true,
            saveBatchSize: Int = 1_000,
            oauthPolling: OAuthPoller.Configuration = OAuthPoller.Configuration()
        ) {
            self.costMode = costMode
            self.watcherMode = watcherMode
            self.probeStatsCache = probeStatsCache
            self.saveBatchSize = saveBatchSize
            self.oauthPolling = oauthPolling
        }
    }

    public struct ScanReport: Sendable {
        public let wasFullScan: Bool
        public let scanProgress: JSONLScanner.ScanProgress
        public let persisterStats: SamplePersister.Stats
        public let recomputeStats: AggregateRecomputer.Stats
        public let projectRecomputeStats: ProjectAggregateRecomputer.Stats
        public let sessionRecomputeStats: SessionInfoRecomputer.Stats
        public let probeResult: StatsCacheProbe.ProbeResult?
        public let durationSeconds: Double
    }

    private let container: ModelContainer
    private let context: ModelContext
    private let configuration: Configuration
    private let scanner: JSONLScanner
    private let watcher: JSONLWatcher
    private let resolver: ClaudePathResolver
    private let probe: StatsCacheProbe?
    /// nil disables OAuth polling. Tests leave this nil so no network
    /// or keychain access happens; the app constructs a default
    /// `OAuthClient()` to enable Tier 3 rate-limit windowing.
    private let oauthPoller: OAuthPoller?

    private var resolvedRoots: [ClaudePathResolver.ResolvedRoot] = []
    private var scanInFlight = false
    /// Long-lived persister so its in-memory dedup Set is built once.
    /// Lazily constructed on the first scan cycle so tests that never
    /// scan don't pay the preload cost.
    private var persister: SamplePersister?
    /// Last time we emitted a routine "incremental scan" log line.
    /// Used to throttle logging — without it, a chatty Claude Code
    /// session generates ~1 log entry per second, multi-MB log files
    /// per day. Unusual scans (slow, with dups, with errors) bypass
    /// this throttle and always log.
    private var lastRoutineLogAt: Date?
    /// Minimum gap between routine log lines. Unusual scans always
    /// log regardless.
    private static let routineLogInterval: TimeInterval = 60

    public init(
        container: ModelContainer,
        configuration: Configuration = Configuration(),
        statsCacheURL: URL? = nil,
        resolver: ClaudePathResolver = ClaudePathResolver(),
        oauthClient: OAuthClient? = nil
    ) {
        self.container = container
        self.context = ModelContext(container)
        self.configuration = configuration
        self.scanner = JSONLScanner()
        self.watcher = JSONLWatcher(mode: configuration.watcherMode)
        self.resolver = resolver
        if configuration.probeStatsCache {
            self.probe = StatsCacheProbe(fileURL: statsCacheURL ?? StatsCacheProbe.defaultLocation())
        } else {
            self.probe = nil
        }
        if let oauthClient {
            self.oauthPoller = OAuthPoller(
                client: oauthClient,
                container: container,
                configuration: configuration.oauthPolling
            )
        } else {
            self.oauthPoller = nil
        }
    }

    /// Resolve paths, run one scan, recompute, probe. Used by tests
    /// and the once-and-exit CLI mode.
    @discardableResult
    public func runOnce() async throws -> ScanReport {
        if resolvedRoots.isEmpty {
            resolvedRoots = try resolver.resolve()
        }
        return try await runScanCycle()
    }

    /// Runs the initial scan, then blocks watching for change events.
    /// Returns when the watcher stream ends (typically on `stop()`).
    public func runForever() async throws {
        resolvedRoots = try resolver.resolve()
        let stream = await watcher.triggers()
        // Initial scan first, BEFORE we install the watcher. That way
        // the first FSEvent doesn't race the historical scan and we
        // can't double-process the same files.
        do {
            let report = try await runScanCycle()
            log("startup: \(formatReport(report))")
        } catch {
            log("startup scan failed: \(error)")
        }
        await watcher.start(roots: resolvedRoots)

        // OAuth poller runs independently from the JSONL watcher loop.
        // Each subsystem owns its own cadence; if the network is down
        // the JSONL pipeline keeps working, and if the user has no
        // Claude Code login the poller silently sleeps without
        // disturbing scans. Both shut down via `stop()`.
        if let oauthPoller {
            await oauthPoller.start()
            log("oauth poller started")
        }

        for await _ in stream {
            // Skip if a scan is already underway. The watcher fires
            // both on FSEvents (debounced 500ms) and the 60s backstop
            // — they CAN overlap during a long scan. Skipping is
            // correct: anything new since the in-flight scan started
            // will be picked up by the next trigger.
            if scanInFlight {
                continue
            }
            do {
                let report = try await runScanCycle()
                logIfInteresting(report)
            } catch {
                log("incremental scan failed: \(error)")
            }
        }
    }

    public func stop() async {
        await watcher.stop()
        if let oauthPoller {
            await oauthPoller.stop()
        }
    }

    // MARK: - Internal

    private func runScanCycle() async throws -> ScanReport {
        scanInFlight = true
        defer { scanInFlight = false }
        let started = Date()

        let lastVersion = try fetchMeta(ClaudeCodeMetaKey.scanVersion)
        let isFullScan = (lastVersion != Self.currentScanVersion)

        // On a full re-scan we wipe all cursors so every JSONL is
        // read from offset 0. The hoisted persister still rejects
        // pre-existing rows by dedupKey, so the DB ends up
        // effectively re-validated without inflating row counts.
        let cursors: [String: JSONLScanner.CursorState]
        if isFullScan {
            try deleteAllCursors()
            cursors = [:]
        } else {
            cursors = try loadCursors()
        }

        let activePersister = try persister ?? makePersister()
        if persister == nil { persister = activePersister }
        // Each cycle starts with a clean dirty-pairs slate so the
        // recomputers only touch buckets the cycle actually changed.
        activePersister.clearDirtyPairs()
        // Integrity recovery: on the first cycle of a persister's
        // lifetime, fold any (date, model) pairs that have TokenSamples
        // but no DailyAggregate into the dirty set. Without this the
        // dedup-skip path during a re-scan would never mark these pairs
        // dirty (every entry hits seenDedupKeys), so missing aggregates
        // would stay missing forever. Subsequent cycles get an empty
        // set back.
        let recoveryPairs = activePersister.consumeMissingAggregatePairs()
        if !recoveryPairs.isEmpty {
            activePersister.addDirtyPairs(recoveryPairs)
            log("integrity: \(recoveryPairs.count) (date,model) bucket(s) missing aggregates - rebuilding")
        }
        // Same recovery path for ProjectDailyAggregate. This is what
        // backfills the new project rollup table for users upgrading
        // from a build that didn't have it: every existing
        // (project, date) bucket lands in the dirty set on first scan,
        // recomputed once, and from then on incremental scans only
        // touch the buckets they actually wrote into.
        let recoveryProjectPairs = activePersister.consumeMissingProjectAggregatePairs()
        if !recoveryProjectPairs.isEmpty {
            activePersister.addDirtyProjectDates(recoveryProjectPairs)
            log("integrity: \(recoveryProjectPairs.count) (project,date) bucket(s) missing project aggregates - rebuilding")
        }
        // Same recovery path for SessionInfo. Bootstraps the rollup
        // table for users upgrading from a build that didn't maintain
        // it; afterwards incremental scans only touch the sessions
        // they actually wrote into.
        let recoverySessionIds = activePersister.consumeMissingSessionIds()
        if !recoverySessionIds.isEmpty {
            activePersister.addDirtySessionIds(recoverySessionIds)
            log("integrity: \(recoverySessionIds.count) session(s) missing SessionInfo rows - rebuilding")
        }
        // Cost-recompute version bump: existing aggregate rows are
        // present but were computed with a buggy cost path. Mark every
        // sample-driven aggregate dirty so the recomputers rebuild
        // them. After the cycle's terminal save we write the new
        // version to ClaudeCodeMeta so this only fires once per bump.
        let needsCostRebuild = (
            try fetchMeta(ClaudeCodeMetaKey.costRecomputeVersion)
            != Self.currentCostRecomputeVersion
        )
        if needsCostRebuild {
            try activePersister.markEverySampleDirty()
            log("integrity: cost recompute version bumped to \(Self.currentCostRecomputeVersion) — rebuilding every aggregate")
        }

        // Path-canonicalization migration. Walks every TokenSample,
        // re-applies the worktree-stripping canonicalizer in place,
        // and folds both the old and new (project, date) pairs into
        // dirtyProjectDates so the project-aggregate recomputer
        // moves the rollup over. We need this in addition to the
        // scanVersion-driven full re-scan because the scan's
        // dedup-skip path bypasses field updates on existing rows.
        let needsPathMigration = (
            try fetchMeta(ClaudeCodeMetaKey.pathCanonicalizationVersion)
            != Self.currentPathCanonicalizationVersion
        )
        if needsPathMigration {
            let changed = try activePersister.canonicalizeProjectPaths()
            if changed > 0 {
                log("integrity: canonicalized \(changed) sample(s) — worktree paths now attribute to parent projects")
            }
        }
        let beforeStats = activePersister.stats

        // The scanner's emit closure is @Sendable but we need to hop
        // back into MainActor land to touch SwiftData. The InsertSink
        // wraps this hop and surfaces the first error so we don't
        // silently swallow disk-full / migration-failed conditions.
        let sink = InsertSink(persister: activePersister)
        let result = try await scanner.scan(
            roots: resolvedRoots,
            cursors: cursors,
            emit: { entry in await sink.consume(entry) }
        )
        try sink.throwIfError()
        try activePersister.flush()
        try saveCursors(result.updatedCursors)

        let cycleStats = SamplePersister.Stats(
            inserted: activePersister.stats.inserted - beforeStats.inserted,
            skippedAsDuplicate: activePersister.stats.skippedAsDuplicate - beforeStats.skippedAsDuplicate
        )

        let recomputer = AggregateRecomputer(
            container: container, context: context, mode: configuration.costMode)
        let recomputeStats = try await recomputer.recompute(pairs: activePersister.dirtyPairs)

        // Both recomputers below previously ignored cost mode entirely
        // — they summed `sample.sourceCostUSD ?? 0`, which silently
        // recorded $0 for every Claude Code line that didn't carry a
        // stored cost. Threading the same cost mode + pricing table
        // that AggregateRecomputer uses fixes the Projects view's
        // $0.00 columns and the LiveActivity card's last-hour cost.
        let projectRecomputer = ProjectAggregateRecomputer(
            container: container,
            context: context,
            mode: configuration.costMode
        )
        let projectRecomputeStats = try await projectRecomputer.recompute(pairs: activePersister.dirtyProjectDates)

        let sessionRecomputer = SessionInfoRecomputer(
            container: container,
            context: context,
            mode: configuration.costMode
        )
        let sessionRecomputeStats = try await sessionRecomputer.recompute(sessionIds: activePersister.dirtySessionIds)

        var probeResult: StatsCacheProbe.ProbeResult?
        if let probe {
            do {
                probeResult = try probe.probeAndStore(in: context)
            } catch StatsCacheProbe.ProbeError.fileMissing {
                // Not an error — fresh installs and Claude Code 1.x
                // stats-cache absence both land here.
            } catch {
                log("stats-cache probe failed: \(error)")
            }
        }

        // Bookkeeping. Always write incremental cursor (even on full
        // scan, so the next run is incremental). scanVersion gates
        // future full re-scans on parser changes.
        try writeMeta(ClaudeCodeMetaKey.scanVersion, value: Self.currentScanVersion)
        try writeMeta(
            ClaudeCodeMetaKey.costRecomputeVersion,
            value: Self.currentCostRecomputeVersion
        )
        try writeMeta(
            ClaudeCodeMetaKey.pathCanonicalizationVersion,
            value: Self.currentPathCanonicalizationVersion
        )
        try writeMeta(
            ClaudeCodeMetaKey.lastIncrementalScanAt,
            value: ISO8601DateFormatter.shared.string(from: started)
        )
        if isFullScan {
            try writeMeta(
                ClaudeCodeMetaKey.lastFullScanAt,
                value: ISO8601DateFormatter.shared.string(from: started)
            )
        }
        try context.save()

        return ScanReport(
            wasFullScan: isFullScan,
            scanProgress: result.progress,
            persisterStats: cycleStats,
            recomputeStats: recomputeStats,
            projectRecomputeStats: projectRecomputeStats,
            sessionRecomputeStats: sessionRecomputeStats,
            probeResult: probeResult,
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    private func makePersister() throws -> SamplePersister {
        try SamplePersister(context: context, saveBatchSize: configuration.saveBatchSize)
    }

    private func loadCursors() throws -> [String: JSONLScanner.CursorState] {
        let descriptor = FetchDescriptor<JSONLFileCursor>()
        let rows = try context.fetch(descriptor)
        var out: [String: JSONLScanner.CursorState] = [:]
        out.reserveCapacity(rows.count)
        for row in rows {
            out[row.path] = JSONLScanner.CursorState(
                byteOffset: row.byteOffset,
                lastSeenMtime: row.lastSeenMtime
            )
        }
        return out
    }

    private func saveCursors(_ updates: [String: JSONLScanner.CursorState]) throws {
        guard !updates.isEmpty else { return }
        let descriptor = FetchDescriptor<JSONLFileCursor>()
        let existingRows = try context.fetch(descriptor)
        var byPath: [String: JSONLFileCursor] = [:]
        byPath.reserveCapacity(existingRows.count)
        for row in existingRows {
            byPath[row.path] = row
        }
        for (path, state) in updates {
            if let row = byPath[path] {
                row.byteOffset = state.byteOffset
                row.lastSeenMtime = state.lastSeenMtime
            } else {
                context.insert(JSONLFileCursor(
                    path: path,
                    byteOffset: state.byteOffset,
                    lastSeenMtime: state.lastSeenMtime
                ))
            }
        }
    }

    private func deleteAllCursors() throws {
        let descriptor = FetchDescriptor<JSONLFileCursor>()
        let rows = try context.fetch(descriptor)
        for row in rows {
            context.delete(row)
        }
    }

    private func fetchMeta(_ key: String) throws -> String? {
        let descriptor = FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
        return try context.fetch(descriptor).first?.value
    }

    private func writeMeta(_ key: String, value: String) throws {
        let descriptor = FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
        if let existing = try context.fetch(descriptor).first {
            existing.value = value
        } else {
            context.insert(ClaudeCodeMeta(key: key, value: value))
        }
    }

    private func log(_ message: String) {
        Log.write("ScanCoordinator", message)
    }

    /// Emit a log line for "interesting" scans only:
    /// - any scan with dups > 0 (potential cross-file dedup activity)
    /// - any scan slower than 1 second (unusual; pre-cursor scans were ~10s)
    /// - the first scan after each `routineLogInterval` window (so the
    ///   log shows the daemon is alive without spamming)
    /// Routine fast scans with no dups stay silent.
    private func logIfInteresting(_ report: ScanReport) {
        let now = Date()
        let isSlow = report.durationSeconds > 1.0
        let hasDups = report.persisterStats.skippedAsDuplicate > 0
        let hasInserts = report.persisterStats.inserted > 0
        let throttleExpired: Bool = {
            guard let last = lastRoutineLogAt else { return true }
            return now.timeIntervalSince(last) >= Self.routineLogInterval
        }()

        if isSlow || hasDups {
            log("scan: \(formatReport(report))")
            lastRoutineLogAt = now
        } else if hasInserts && throttleExpired {
            log("scan: \(formatReport(report))")
            lastRoutineLogAt = now
        }
    }

    /// Compact one-line summary for the daemon log. Caller adds the
    /// "scan: " or "startup: " prefix; we don't include the kind here
    /// twice (duplication was a cosmetic bug in earlier versions).
    private func formatReport(_ r: ScanReport) -> String {
        let kind = r.wasFullScan ? "full" : "incremental"
        return "\(kind) files=\(r.scanProgress.filesScanned) skipped=\(r.scanProgress.filesSkipped) parsed=\(r.scanProgress.entriesParsed) inserted=\(r.persisterStats.inserted) dups=\(r.persisterStats.skippedAsDuplicate) aggs=\(r.recomputeStats.aggregatesUpserted) projAggs=\(r.projectRecomputeStats.aggregatesUpserted) sess=\(r.sessionRecomputeStats.sessionsUpserted) ms=\(Int(r.durationSeconds * 1000))"
    }
}

/// Bridges scanner emit (`@Sendable async`) into MainActor-isolated
/// SwiftData inserts. Captures the first error so the caller can
/// re-throw after the scan completes — silent-swallow would hide disk
/// failures and bad-state migrations.
@MainActor
private final class InsertSink {
    private let persister: SamplePersister
    private var firstError: Error?

    init(persister: SamplePersister) {
        self.persister = persister
    }

    func consume(_ entry: ParsedUsageEntry) {
        if firstError != nil { return }
        do {
            _ = try persister.insert(entry)
        } catch {
            firstError = error
        }
    }

    func throwIfError() throws {
        if let firstError { throw firstError }
    }
}

/// Shared ISO-8601 formatter for ClaudeCodeMeta date round-trips. Apple
/// documents `.string(from:)` and `.date(from:)` as thread-safe so a
/// single shared instance is fine.
extension ISO8601DateFormatter {
    nonisolated(unsafe) fileprivate static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
