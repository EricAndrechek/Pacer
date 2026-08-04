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
@ScanActor
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
    /// - "3" — dedup keeps the *finished* copy of a streamed message
    ///         instead of the first one. Existing stores hold the
    ///         mid-stream snapshot for any message Claude Code wrote
    ///         more than once — on the maintainer's own store that was
    ///         29.5M output tokens, 63% of the output recorded. The
    ///         forced re-read is what repairs them: the persister now
    ///         upgrades a stored row when a larger-output copy arrives
    ///         rather than skipping it as a duplicate, so simply
    ///         re-reading every transcript corrects history in place.
    ///         Rows whose transcripts Claude Code has since rotated
    ///         away keep their old values — we never delete a sample we
    ///         can no longer re-derive.
    public static let currentScanVersion = "3"

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
    /// - "3" — `AnthropicFallbackPricing` added for Fable 5 / Mythos 5
    ///         (LiteLLM had no entries at their 2026-06-09 launch, so
    ///         their samples aggregated at $0) and zero-priced LiteLLM
    ///         placeholder rows are now dropped at decode. Rebuild so
    ///         historical Fable/Mythos usage picks up real pricing.
    /// - "4" — Mythos Preview gained real rates ($25/$125 per MTok,
    ///         previously $0 via LiteLLM's zero placeholder) and
    ///         pricing refresh now gap-fills from models.dev, which
    ///         can price models LiteLLM lacked at earlier scans.
    public static let currentCostRecomputeVersion = "4"

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
    /// - "2" — `ProjectPathCanonicalizer` now consults a user-defined
    ///         `ProjectPathAlias` table after the worktree-strip pass.
    ///         Forced migration re-canonicalizes every existing
    ///         TokenSample with the current alias map and rebuilds
    ///         affected `ProjectDailyAggregate` rows under the new
    ///         keys.
    /// - "3" — `TokenSample.originalProjectPath` added. The migration
    ///         also backfills `originalProjectPath` for every row
    ///         where it's nil (copies from `projectPath`) so the
    ///         sub-project drill-down has SOMETHING to bucket on
    ///         even for historical rows. New rows after this set the
    ///         field at insert time, with the true pre-canonical cwd.
    /// - "4" — Sibling-worktree merge now prefers the **main** worktree
    ///         (`.git/` is a directory) over secondary worktrees
    ///         (`.git` is a file pointing at
    ///         `<main>/.git/worktrees/<name>`), regardless of which
    ///         worktree the user touched most recently. The previous
    ///         "most-recently-active wins" rule was producing the
    ///         wrong direction for layouts like
    ///         `~/Code/repo` + `~/Code/repo.issue-160` (the main repo
    ///         got aliased into the worktree, so Projects showed the
    ///         feature-branch name instead of the repo name). The
    ///         migration calls `ProjectGitRootAutoAliaser.
    ///         reconcileSiblingMergeAliases()` once on this bump to
    ///         delete existing aliases that point at a non-main
    ///         sibling; the regular `run()` then re-creates them in
    ///         the corrected direction.
    public static let currentPathCanonicalizationVersion = "4"

    /// Bumped to run the one-time alias origin-classification backfill —
    /// see `ClaudeCodeMetaKey.aliasOriginClassificationVersion` and
    /// `ProjectGitRootAutoAliaser.backfillOriginClassification`. "1" is
    /// the initial pass that classifies pre-existing aliases (written
    /// before the `isAutoGenerated` field) as auto vs manual.
    public static let currentAliasOriginClassificationVersion = "1"

    /// Bumped to backfill a stable `ProjectMeta.colorSeed` for every
    /// existing project (donut/legend colors are derived from it). "1" is
    /// the initial pass.
    public static let currentColorSeedVersion = "1"

    /// Meta key for the aliases-table fingerprint. The fingerprint is
    /// `sha-of(sourcePath→canonicalPath rows, sorted)`; on mismatch
    /// the next scan re-canonicalizes every TokenSample with the new
    /// alias map. This is what makes "user adds/removes an alias"
    /// trigger an automatic data migration on the next scan cycle —
    /// `pathCanonicalizationVersion` only covers code-driven changes.
    private static let aliasesFingerprintMetaKey = "aliases_fingerprint"

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
        /// Optional faster path for **full** scans only — first launch and
        /// parser-version re-derivations. `nil` (the default, and what the
        /// widget extension and tests use) keeps every scan on
        /// `JSONLScanner`. See `BulkTranscriptImporter`.
        public var bulkImporter: BulkTranscriptImporter?

        public init(
            costMode: CostMode = .auto,
            watcherMode: JSONLWatcher.Mode = .live(latencySeconds: 0.5, backstopInterval: 60),
            probeStatsCache: Bool = true,
            saveBatchSize: Int = 1_000,
            oauthPolling: OAuthPoller.Configuration = OAuthPoller.Configuration(),
            bulkImporter: BulkTranscriptImporter? = nil
        ) {
            self.costMode = costMode
            self.watcherMode = watcherMode
            self.probeStatsCache = probeStatsCache
            self.saveBatchSize = saveBatchSize
            self.oauthPolling = oauthPolling
            self.bulkImporter = bulkImporter
        }
    }

    public struct ScanReport: Sendable {
        public let wasFullScan: Bool
        public let scanProgress: JSONLScanner.ScanProgress
        public let persisterStats: SamplePersister.Stats
        public let recomputeStats: AggregateRecomputer.Stats
        public let hourlyRecomputeStats: HourlyAggregateRecomputer.Stats
        public let projectRecomputeStats: ProjectAggregateRecomputer.Stats
        public let sessionRecomputeStats: SessionInfoRecomputer.Stats
        public let probeResult: StatsCacheProbe.ProbeResult?
        public let durationSeconds: Double
        public let phaseTimings: PhaseTimings
    }

    /// Per-phase wall-clock breakdown of one scan cycle. Captured by
    /// `runScanCycle`; logged inline so a `scan: ...` line in the log
    /// shows exactly which sub-step ate the cycle's budget.
    ///
    /// All values are milliseconds (Double for sub-ms precision in
    /// tests/CI; the log line rounds to Int). Phases are recorded in
    /// the order they execute inside `runScanCycle` — keep the
    /// `formatReport` ordering aligned so the log line reads top-to-
    /// bottom through the cycle.
    public struct PhaseTimings: Sendable {
        /// Auto-aliaser pass: probe distinct project paths for nearby
        /// `.git`, write aliases. Includes optional sibling-merge
        /// reconciliation that fires on a `pathCanonicalizationVersion`
        /// bump. Cheap in steady state (most paths already probed).
        public var autoAliasMs: Double = 0
        /// Alias + meta + cursor setup: `loadAliases`, the four
        /// `fetchMeta(...)` reads (scanVersion, costRecomputeVersion,
        /// pathCanonicalizationVersion, aliasesFingerprint),
        /// `loadCursors`/`deleteAllCursors`, persister construction +
        /// `clearDirtyPairs`, and the four `consumeMissing*` recovery
        /// drains. Cheap on a warm DB; first scan after a schema bump
        /// can be 100s of ms because `markEverySampleDirty` walks
        /// every TokenSample.
        public var metaPrepMs: Double = 0
        /// In-place path canonicalization migration: only non-zero when
        /// the code-level `pathCanonicalizationVersion` or the user's
        /// alias-table fingerprint changed. Walks every TokenSample so
        /// can be significant on a large store.
        public var migrationMs: Double = 0
        /// JSONL file walk: stat every known cursor file, open + read
        /// from cursor offset on changed files, parse each new line,
        /// emit to the InsertSink. On steady-state writes this is the
        /// `887-file stat sweep + 1-line parse` cost.
        public var scanMs: Double = 0
        /// `await watcher.consumeChangedPaths()` — drain the FSEvents
        /// path hints buffered on the watcher actor since the last
        /// cycle. Separated from `scanMs` because the cost is an actor
        /// hop, not file I/O — if this number is high while `scanMs`
        /// stays small, the watcher actor is contended (typically by
        /// FSEvents bursts during heavy Claude Code writes).
        public var consumeChangedPathsMs: Double = 0
        /// `SamplePersister.flush` — currently O(1) (just resets the
        /// pending-insert counter). Kept separate so a future change
        /// that adds work here is visible.
        public var flushMs: Double = 0
        /// `saveCursors`: update or insert one `JSONLFileCursor` row
        /// per file changed this cycle. No save here — the terminal
        /// `context.save()` commits them.
        public var saveCursorsMs: Double = 0
        /// `AggregateRecomputer.recompute` — daily (date, model) rollup.
        /// Per-pair fetch + upsert on the main context for ≤64 pairs,
        /// background `@ModelActor` worker above that threshold.
        public var dailyRecomputeMs: Double = 0
        /// `HourlyAggregateRecomputer.recompute` — (date, hour, model)
        /// rollup. Same dispatch shape as `dailyRecomputeMs`.
        public var hourlyRecomputeMs: Double = 0
        /// `ProjectAggregateRecomputer.recompute` — (projectPath, date)
        /// rollup. Same dispatch shape as `dailyRecomputeMs`.
        public var projectRecomputeMs: Double = 0
        /// `SessionInfoRecomputer.recompute` — per-session rollup. Same
        /// dispatch shape as `dailyRecomputeMs`.
        public var sessionRecomputeMs: Double = 0
        /// `StatsCacheProbe.probeAndStore`: reads `~/.claude/stats-cache.json`
        /// and stashes the result. Cheap; nil-probe path is zero.
        public var probeMs: Double = 0
        /// Terminal commit: the five `writeMeta(...)` updates (only
        /// when `cycleDidWork || isFullScan`) plus the one
        /// `context.save()`. The save is the @Query-fanout
        /// trigger — every visible card refetches when this commits.
        public var saveMs: Double = 0
        /// `postScanCycleSummary`: NotificationCenter post for widgets
        /// + other out-of-process consumers. Sub-ms.
        public var notifMs: Double = 0
    }

    private let container: ModelContainer
    /// Scan-loop context, lazily created on first `@ScanActor` access.
    /// `ModelContext` is thread-affine, so it must be born on the same
    /// executor that uses it — deferring creation past the (nonisolated)
    /// init guarantees it's created on `ScanActor`, not on whatever
    /// thread happened to call the initializer.
    private var _context: ModelContext?
    private var context: ModelContext {
        if let _context { return _context }
        let c = ModelContext(container)
        _context = c
        return c
    }
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

    /// Last time we ran `StatsCacheProbe`. Used to throttle the probe
    /// to once per `statsCacheProbeInterval` instead of every cycle —
    /// the probe is a debug-view-only sanity check (never feeds
    /// user-facing aggregates per StatsCacheProbe.swift's doc), and on
    /// the live machine it's occasionally taken 278 ms when the
    /// stats-cache.json was being written concurrently by Claude
    /// Code. No reason to pay that cost every scan.
    private var lastStatsCacheProbeAt: Date?

    /// Minimum gap between StatsCacheProbe runs. 60 s matches the
    /// other periodic-not-time-critical bookkeeping. Probe file
    /// updates are lazy in Claude Code (lags by hours per its own
    /// doc) so daily-granularity freshness is more than enough.
    private static let statsCacheProbeInterval: TimeInterval = 60

    /// In-memory cache of `JSONLFileCursor` state, keyed by path.
    /// Populated lazily on first cycle via `loadCursorsCached()`, kept
    /// up-to-date by `saveCursors` (which writes through to disk).
    /// Eliminates the per-cycle full-table fetch (~1 K rows on a
    /// populated install) that `prep` phase was paying every cycle.
    /// Cleared on full re-scan (`deleteAllCursors`) so the next cycle
    /// re-reads from a fresh disk state.
    private var cursorsCache: [String: JSONLScanner.CursorState]?

    /// Last time we ran the auto-aliaser pass. Under heavy Claude
    /// Code activity the per-cycle SwiftData fetches inside
    /// `ProjectGitRootAutoAliaser.run` started landing in 1500-2000ms
    /// territory because MainActor was contended by view refreshes
    /// (autoA's own fetches queue behind the @Query refresh storm
    /// each save triggers). Auto-aliasing isn't time-critical — a
    /// newly-seen project picks up its alias within a minute either
    /// way — so we throttle to a periodic pass instead of every cycle.
    /// First scan after launch always runs (cache empty).
    private var lastAutoAliasAt: Date?
    /// Hash of the candidate-path set last fed to the auto-aliaser.
    /// If a cycle's candidate set differs from this, we run
    /// auto-aliaser immediately regardless of `lastAutoAliasAt` —
    /// otherwise a fresh project path could wait up to the throttle
    /// interval before getting an alias entry. FNV-1a, stable, sub-µs.
    private var lastAutoAliasCandidateHash: String?
    /// Minimum gap between auto-aliaser runs when the candidate set
    /// is unchanged. 60 s matches the routine-log throttle and the
    /// backstop scan interval.
    private static let autoAliasInterval: TimeInterval = 60

    /// Nonisolated so the driver (`AppBackgroundService`, on MainActor)
    /// can construct the coordinator without an `await` hop. The
    /// `ModelContext` is intentionally NOT created here — it's lazily
    /// born on `ScanActor` on first use (see `context`).
    public nonisolated init(
        container: ModelContainer,
        configuration: Configuration = Configuration(),
        statsCacheURL: URL? = nil,
        resolver: ClaudePathResolver = ClaudePathResolver(),
        oauthClient: OAuthClient? = nil,
        oauthPoolStore: TokenPoolStoring = EphemeralTokenPoolStore()
    ) {
        self.container = container
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
                configuration: configuration.oauthPolling,
                poolStore: oauthPoolStore
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

    /// Outcome summary for `runAliasMigrationOnly`. Smaller than the
    /// full `ScanReport` because the fast-path doesn't touch JSONLs
    /// or the cost-recompute meta — just alias-driven re-attribution.
    public struct AliasMigrationReport: Sendable {
        public let aliasesChanged: Bool
        public let samplesRecanonicalized: Int
        public let projectAggregatesUpserted: Int
        public let sessionsUpserted: Int
        public let durationSeconds: TimeInterval
    }

    /// Fast-path migration triggered by a user merge action (the
    /// `.pacerRequestImmediateScan` notification). Re-runs the
    /// alias-fingerprint check, re-canonicalizes only the affected
    /// samples (via `SamplePersister.canonicalizeAffectedSamples`),
    /// and recomputes the dirty project / session rollups.
    ///
    /// **Doesn't** scan JSONLs, walk FSEvents, or do auto-aliasing.
    /// Those happen on the next regular cycle. The trade-off: any
    /// brand-new JSONL lines written between the merge and the next
    /// cycle won't be visible until that cycle, but the user's
    /// merge becomes visible immediately without the multi-second
    /// scan-cycle block we used to pay.
    @discardableResult
    public func runAliasMigrationOnly() async throws -> AliasMigrationReport {
        let started = Date()
        let aliases = try loadAliases()
        let aliasesFingerprint = Self.fingerprint(aliases: aliases)
        let storedAliasFingerprint = try fetchMeta(Self.aliasesFingerprintMetaKey)
        guard storedAliasFingerprint != aliasesFingerprint else {
            // Nothing actually changed — possible if the user did
            // multiple notification-posters in quick succession.
            return AliasMigrationReport(
                aliasesChanged: false,
                samplesRecanonicalized: 0,
                projectAggregatesUpserted: 0,
                sessionsUpserted: 0,
                durationSeconds: Date().timeIntervalSince(started)
            )
        }
        let activePersister = try persister ?? makePersister()
        if persister == nil { persister = activePersister }
        activePersister.clearDirtyPairs()
        let changed = try activePersister.canonicalizeAffectedSamples(aliases: aliases)
        // `canonicalizeAffectedSamples` already folds every re-mapped
        // sample's session id into `dirtySessionIds`, so the SessionInfo
        // rollup below recomputes exactly the sessions that moved. The
        // previous `markSessionsDirtyForAliasChange()` marked *every*
        // session dirty — an O(all-sessions) rebuild (~6 s for ~450
        // sessions on a live store) to "catch" sessions whose samples
        // never changed, which by definition don't need rebuilding.
        let projectRecomputer = ProjectAggregateRecomputer(
            container: container, context: context, mode: configuration.costMode)
        let projectStats = try await projectRecomputer.recompute(
            pairs: activePersister.dirtyProjectDates)
        let sessionRecomputer = SessionInfoRecomputer(
            container: container, context: context, mode: configuration.costMode)
        let sessionStats = try await sessionRecomputer.recompute(
            sessionIds: activePersister.dirtySessionIds)
        try writeMeta(Self.aliasesFingerprintMetaKey, value: aliasesFingerprint)
        if context.hasChanges {
            try context.save()
        }
        // Project-attribution shifted (samples re-bucketed under new
        // project paths) — kick widgets whose display keys off project
        // (TopProjects, LiveSession's project name). No new samples,
        // so `samplesChanged` stays false; widgets that key off totals
        // / sessions still re-pull via `projectAttributionChanged`.
        if changed > 0 {
            // Fire-and-forget onto main: the post must run on the main
            // thread (observers register on `.main`), but the scan cycle
            // shouldn't block waiting for a free main-thread moment just
            // to hand off a UI-refresh hint.
            let summary = ScanCycleSummary(projectAttributionChanged: true)
            Task { @MainActor in postScanCycleSummary(summary) }
        }
        let report = AliasMigrationReport(
            aliasesChanged: true,
            samplesRecanonicalized: changed,
            projectAggregatesUpserted: projectStats.aggregatesUpserted,
            sessionsUpserted: sessionStats.sessionsUpserted,
            durationSeconds: Date().timeIntervalSince(started)
        )
        log("alias-migration: changed=\(changed) proj=\(projectStats.aggregatesUpserted) sess=\(sessionStats.sessionsUpserted) in \(String(format: "%.0f", report.durationSeconds * 1000))ms")
        return report
    }

    /// Runs the initial scan, then blocks watching for change events.
    /// Returns when the watcher stream ends (typically on `stop()`).
    public func runForever() async throws {
        resolvedRoots = try resolver.resolve()
        let stream = await watcher.triggers()
        // One-shot stale-cursor prune: walk the JSONLFileCursor table
        // and drop rows whose paths no longer exist on disk. On the
        // live machine the table had drifted to 1072 cursors vs ~900
        // real JSONL files — 170+ stale rows that the cache (kept
        // hot per-cycle) was paying memory + iteration cost on. Disk
        // failures (e.g. transient network home dir) won't drop
        // active cursors because Claude Code's `~/.claude` is a local
        // path; the next genuine FSEvent for a path we deleted will
        // simply re-create the cursor at offset 0 (correct: we'd be
        // seeing a new file).
        do {
            let pruned = try pruneStaleCursors()
            if pruned > 0 {
                log("startup: pruned \(pruned) stale JSONLFileCursor row(s)")
            }
        } catch {
            log("startup: stale-cursor prune failed: \(error)")
        }
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
        // Apply whatever visibility state we already have at startup —
        // a login-at-launch invocation has no window, so this widens
        // the watcher's FSEvent latency immediately and saves wakeups
        // until the user actually opens the dashboard.
        let initialVisible = await MainActor.run { PacerWindowVisibility.shared.isMainWindowVisible }
        applyVisibilityCadence(visible: initialVisible)
        installVisibilityObserver()

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
        visibilityObservationTask?.cancel()
        visibilityObservationTask = nil
    }

    // MARK: - Visibility-aware cadence

    /// Tracks `PacerWindowVisibility.shared.isMainWindowVisible` and
    /// drives the watcher's latency + backstop knobs accordingly.
    /// Cancelled in `stop()`.
    private var visibilityObservationTask: Task<Void, Never>?

    /// FSEvent latency (live coalesce) and backstop interval applied
    /// when the user has a main window open. 2 s coalesce is the
    /// trade-off point where bursty Claude Code activity stops
    /// thrashing SwiftData saves: a typical assistant turn writes
    /// 3-8 JSONL lines within a 1-2 s window, and bundling them
    /// into one scan + one save was measured (sample(1) on a busy
    /// machine) to cut SwiftData background-thread CPU
    /// proportionally — each save triggers a chain of
    /// `NSPersistentStoreCoordinator` work, WAL writes, and
    /// `@Query` refresh fan-out that no single 100-200 ms scan
    /// cycle can amortize. The user-visible cost is ≤2 s lag on
    /// dashboard updates, which is well within "live usage tracker"
    /// expectations.
    ///
    /// Backstop widened from 60 s to 300 s after p50 cycle-latency
    /// analysis showed ~70 % of cycles during a 30-min idle window
    /// were `files=0 skipped=928 scan~1000 ms` — 928-file full walks
    /// for zero new data. The shouldSkipBackstop gate handles active
    /// FSEvents periods (skips when an `.jsonl` event fired within
    /// the backstop window), but quiet stretches >backstop expire
    /// the gate and fire the safety walk. Modern macOS FSEvents is
    /// reliable enough that 5-min safety-net cadence is sufficient;
    /// in the rare case FSEvents drops an event, the user sees the
    /// data appear within 5 min of the drop.
    private static let visibleLatency: CFTimeInterval = 2.0
    private static let visibleBackstop: TimeInterval = 300

    /// Same knobs when there's no visible main window. Latency widens
    /// so burst writes during an active Claude Code session don't wake
    /// the scan loop every half-second; backstop widens to a 5-minute
    /// sweep that's enough to keep aggregates fresh-ish for the
    /// menu-bar item without spinning the CPU.
    ///
    /// Menu-bar chips (today cost, 5h%, 7d%, active model) update on
    /// scan completion, so at 5-minute cadence they may lag by up to
    /// 5 minutes when no window is open — acceptable for a glance
    /// summary, and the moment the user re-opens the dashboard we
    /// snap back to live cadence and re-render.
    private static let hiddenLatency: CFTimeInterval = 5.0
    private static let hiddenBackstop: TimeInterval = 300

    private func installVisibilityObserver() {
        // Observation framework's `withObservationTracking` re-fires
        // once per write; we wrap in a loop so the observation
        // persists across changes. The body reads
        // `isMainWindowVisible` to register the dependency.
        visibilityObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let visible = withObservationTracking {
                    PacerWindowVisibility.shared.isMainWindowVisible
                } onChange: {
                    // No body — the loop re-enters and re-reads.
                }
                await self?.applyVisibilityCadence(visible: visible)
                // Suspend until the next change. We use a small
                // continuation-style park by awaiting a one-shot Task
                // that completes when the observation onChange fires.
                // Simpler approach: poll on a short Task.sleep — but
                // that defeats the purpose. Instead, recreate the
                // observation: `withObservationTracking` registers
                // once and onChange fires once. We need a primitive
                // that yields the next value; use AsyncStream.
                await Self.nextVisibilityChange()
            }
        }
    }

    /// Bridges the `Observation` API's one-shot `onChange` into an
    /// awaitable. Returns when the next mutation to
    /// `isMainWindowVisible` lands.
    @MainActor
    private static func nextVisibilityChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = PacerWindowVisibility.shared.isMainWindowVisible
            } onChange: {
                continuation.resume()
            }
        }
    }

    private func applyVisibilityCadence(visible: Bool) {
        let latency = visible ? Self.visibleLatency : Self.hiddenLatency
        let backstop = visible ? Self.visibleBackstop : Self.hiddenBackstop
        Task { [watcher] in
            await watcher.updateLiveCadence(
                latencySeconds: latency,
                backstopInterval: backstop
            )
        }
        log("watcher cadence: window \(visible ? "visible" : "hidden") → latency=\(latency)s backstop=\(Int(backstop))s")
    }

    // MARK: - Internal

    private func runScanCycle() async throws -> ScanReport {
        scanInFlight = true
        defer { scanInFlight = false }
        let started = Date()
        var phase = PhaseTimings()
        // Mutable so the closure can advance it after each phase.
        // `Date()` is the same clock the cycle's `durationSeconds` uses,
        // so the phase sum and the total agree within rounding.
        var lastTick = started
        func tickMs() -> Double {
            let now = Date()
            let delta = now.timeIntervalSince(lastTick) * 1000
            lastTick = now
            return delta
        }

        // Auto-aliasing pass: walk up from each known project path
        // looking for the nearest `.git`, and write the resulting
        // `path → repoRoot` rows into the alias table. The
        // `ProjectPathProbe` table tracks "already considered" so we
        // don't re-walk on every cycle, and user deletions of
        // auto-generated aliases stick across launches. Runs BEFORE
        // alias loading so the new rows participate in the
        // fingerprint check (and the migration that follows).
        let autoAliaser = ProjectGitRootAutoAliaser(context: context)

        // One-shot reconciliation when the canonicalization rule has
        // changed. Today's "4" bump flips the sibling-merge canonical
        // selector from "most-recently-active" to "main worktree
        // first" — see `currentPathCanonicalizationVersion` history.
        // Without this pass, aliases already written under the old
        // rule survive forever because the regular sibling-merge pass
        // filters out already-aliased paths.
        //
        // Cheap on a fresh DB (no aliases to walk). On an upgraded DB
        // it walks the alias table once, deletes the wrong-direction
        // rows, and lets `run()` below re-create them under the new
        // rule. Sample re-attribution happens later in the same cycle
        // when `canonicalizeProjectPaths` notices the alias
        // fingerprint changed.
        let storedPathVersionPreRun = try fetchMeta(ClaudeCodeMetaKey.pathCanonicalizationVersion)
        if storedPathVersionPreRun != Self.currentPathCanonicalizationVersion {
            let reconciled = try autoAliaser.reconcileSiblingMergeAliases()
            if reconciled > 0 {
                log("auto-alias: reconciled \(reconciled) sibling-merge alias(es) under rule v\(Self.currentPathCanonicalizationVersion)")
            }
        }

        // One-time backfill: classify pre-existing aliases (written
        // before the `isAutoGenerated` flag) as auto vs manual from probe
        // data, so the Projects-tab alias manager can fold the
        // auto-detected ones behind a disclosure. Runs before `run()` so
        // rows it creates this cycle are written already-classified. The
        // version write is immediate (not deferred to the terminal meta
        // block) because the backfill only touches a UI flag — it doesn't
        // bump the alias fingerprint, so it wouldn't otherwise mark the
        // cycle as "did work" and the gate would re-fire every cycle.
        let storedAliasOriginVersion = try fetchMeta(ClaudeCodeMetaKey.aliasOriginClassificationVersion)
        if storedAliasOriginVersion != Self.currentAliasOriginClassificationVersion {
            let classified = try autoAliaser.backfillOriginClassification()
            if classified > 0 {
                log("auto-alias: classified \(classified) pre-existing alias(es) as auto/manual")
            }
            try writeMeta(
                ClaudeCodeMetaKey.aliasOriginClassificationVersion,
                value: Self.currentAliasOriginClassificationVersion
            )
        }

        // Throttle the auto-aliaser unless the candidate set changed
        // since we last ran it — see `lastAutoAliasAt` for the why.
        // The hash is over distinct project paths; new projects bypass
        // the timer gate (we want their alias detection to be fresh,
        // not 60 s stale), while unchanged sets fall through.
        let candidatePaths = try fetchDistinctProjectPaths()
        let candidateHash = Self.fnv1aHex(candidatePaths.sorted().joined(separator: "\u{001F}"))
        let now = Date()
        let candidatesChanged = lastAutoAliasCandidateHash != candidateHash
        let throttleExpired: Bool = {
            guard let last = lastAutoAliasAt else { return true }
            return now.timeIntervalSince(last) >= Self.autoAliasInterval
        }()
        if candidatesChanged || throttleExpired {
            let autoAliasResult = try await autoAliaser.run(candidatePaths: candidatePaths)
            if autoAliasResult.aliasesAdded > 0 {
                log("auto-alias: probed \(autoAliasResult.pathsProbed) path(s), added \(autoAliasResult.aliasesAdded) alias(es)")
            }
            lastAutoAliasAt = now
            lastAutoAliasCandidateHash = candidateHash
        }
        phase.autoAliasMs = tickMs()

        // Load user-defined project-path aliases once per cycle. Cheap
        // (small table, ~tens of rows max), and folding the load into
        // the cycle keeps the canonicalizer stateless. The fingerprint
        // is checked further down against the on-disk value to decide
        // whether to trigger a migration pass.
        let aliases = try loadAliases()
        let aliasesFingerprint = Self.fingerprint(aliases: aliases)

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
            cursors = try loadCursorsCached()
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
        // Same recovery path for HourlyAggregate. Bootstraps the hourly
        // rollup for users upgrading from a build that didn't have it
        // (`TodayTimelineCard` and `NowStrip` migrated off raw
        // TokenSample walks onto this rollup). Empty after the first
        // post-upgrade cycle.
        let recoveryHourBuckets = activePersister.consumeMissingHourBuckets()
        if !recoveryHourBuckets.isEmpty {
            activePersister.addDirtyHourBuckets(recoveryHourBuckets)
            log("integrity: \(recoveryHourBuckets.count) (date,hour,model) bucket(s) missing hourly aggregates - rebuilding")
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
        // re-applies the worktree-stripping canonicalizer (plus the
        // user's current alias map) in place, and folds both the old
        // and new (project, date) pairs into dirtyProjectDates so the
        // project-aggregate recomputer moves the rollup over. We need
        // this in addition to the scanVersion-driven full re-scan
        // because the scan's dedup-skip path bypasses field updates on
        // existing rows.
        //
        // Two triggers fire this pass:
        //   1. Code-driven canonicalization rule change
        //      (`pathCanonicalizationVersion` mismatch).
        //   2. User-driven alias change (`aliasesFingerprint`
        //      mismatch). The fingerprint check is what makes
        //      add/edit/delete an alias re-attribute existing samples
        //      on the next scan without any per-row UI plumbing.
        let storedPathVersion = try fetchMeta(ClaudeCodeMetaKey.pathCanonicalizationVersion)
        let storedAliasFingerprint = try fetchMeta(Self.aliasesFingerprintMetaKey)
        let needsPathMigration = (
            storedPathVersion != Self.currentPathCanonicalizationVersion
            || storedAliasFingerprint != aliasesFingerprint
        )
        // metaPrep covers loadAliases + 4 fetchMeta reads + cursor
        // load + persister setup + recovery drains + the cost-rebuild
        // markEverySampleDirty walk. The migration timing below
        // separates the (usually-zero) canonicalization pass so the
        // metaPrep number is a steady-state floor we can target.
        phase.metaPrepMs = tickMs()

        if needsPathMigration {
            let changed: Int
            if storedPathVersion != Self.currentPathCanonicalizationVersion {
                // Code-level canonicalization rule changed: every
                // TokenSample must be re-evaluated, and the full walk
                // also backfills `originalProjectPath`. This fires once
                // per version bump, so the all-rows cost is acceptable.
                changed = try activePersister.canonicalizeProjectPaths(aliases: aliases)
            } else {
                // Alias-fingerprint-only change — the steady-state case,
                // fired every time the auto-aliaser adds a row (and on
                // any alias edit that didn't route through
                // `runAliasMigrationOnly`). Only samples currently under
                // an alias *source* can re-map, so fetch those by the
                // indexed `projectPath` column instead of materializing
                // every TokenSample. This is what turns the recurring
                // "auto-alias added 1 row" cycle from a ~12 s full-table
                // walk — a multi-second MainActor freeze the user sees as
                // a scroll beachball — into a handful of indexed lookups.
                changed = try activePersister.canonicalizeAffectedSamples(aliases: aliases)
            }
            if changed > 0 {
                log("integrity: canonicalized \(changed) sample(s) — worktree+alias mapping updated")
            }
            // Both canonicalize passes fold every re-mapped sample's
            // session id into `dirtySessionIds`, so the SessionInfo
            // rollup catches up for exactly the sessions that moved. The
            // previous belt-and-braces `markSessionsDirtyForAliasChange()`
            // marked *every* session dirty — an O(all-sessions) rebuild
            // (~6 s for ~450 sessions on MainActor) to catch sessions
            // whose samples never changed, which by definition don't need
            // rebuilding.

            // Path-keyed USER rows (ProjectMeta color seed, ProjectBudget)
            // aren't rebuilt from samples like aggregates are, so an alias
            // merge would orphan them at the pre-merge path. Re-key them
            // through the same canonicalizer. Also closes a pre-existing
            // bug: a merged project's budget was silently orphaned.
            try reattributeUserRows(aliases: aliases)
            // Commit the re-keying now so the later color-seed pass sees
            // the moved rows — SwiftData's fetch doesn't reflect a pending
            // unique-key change within the same cycle, which would
            // otherwise let the color pass insert a duplicate that
            // collides on the terminal save. Migration cycles are rare
            // (only on an alias change), so the extra save is cheap.
            if context.hasChanges { try context.save() }
        }
        phase.migrationMs = tickMs()
        let beforeStats = activePersister.stats

        // The scanner's emit closure is @Sendable but we need to hop
        // back into MainActor land to touch SwiftData. The InsertSink
        // wraps this hop and surfaces the first error so we don't
        // silently swallow disk-full / migration-failed conditions.
        let sink = InsertSink(persister: activePersister)
        // Drain the watcher's per-cycle changed-path set BEFORE we
        // start scanning. FSEvents writes paths in here as they
        // arrive; on a cycle driven by a debounced FSEvent burst the
        // set contains exactly the JSONLs that changed, and the
        // scanner stats just those (single-digit ms) instead of
        // walking all 800+ cursored files (~300ms floor). Empty set
        // means a backstop tick, the first cycle after startup, or
        // a manual trigger — scanner falls back to the full walk so
        // we never miss a file FSEvents didn't tell us about.
        //
        // On a full re-scan (parser version bump → `isFullScan`) we
        // ignore the hint and force a full walk: cursor wipes only
        // help if we actually visit every file, and a hint from one
        // recent write would otherwise leave the other 700+ files
        // unscanned until their next individual FSEvent.
        let hintedPaths: Set<String>?
        if isFullScan {
            _ = watcher.consumeChangedPaths()  // drain anyway
            hintedPaths = nil
        } else {
            let paths = watcher.consumeChangedPaths()
            hintedPaths = paths.isEmpty ? nil : paths
        }
        let consumeMs = tickMs()
        // A full scan means "read every transcript from byte zero" — a first
        // launch, or a `currentScanVersion` bump re-deriving history under
        // new parsing rules. That's the one shape a bulk importer is better
        // at (74.8 s → 12.4 s on a 1,697-file corpus), and the one time
        // re-reading whole files costs nothing extra, since we were going to
        // read them all anyway.
        //
        // Incremental cycles never come here: they resume from byte offsets
        // and touch only what changed, which no bulk reader can match.
        var bulkResult: JSONLScanner.ScanResult?
        if isFullScan, let importer = configuration.bulkImporter {
            do {
                bulkResult = try bulkScan(importer: importer,
                                          roots: resolvedRoots.map(\.projectsDirectory),
                                          aliases: aliases, sink: sink)
            } catch {
                // Degrade to slow, never to broken: the line parser is always
                // able to do this job, so an importer failure costs time and
                // a log line rather than a launch.
                log("bulk import failed (\(error)) — falling back to the line parser")
            }
        }
        let result: JSONLScanner.ScanResult
        if let bulkResult {
            result = bulkResult
        } else {
            result = try await scanner.scan(
                roots: resolvedRoots,
                cursors: cursors,
                aliases: aliases,
                hintedPaths: hintedPaths,
                emit: { entry in sink.consume(entry) }
            )
        }
        // Bulk-insert everything the scanner collected. One MainActor
        // pass over the entries; see `InsertSink` doc for the rationale.
        try sink.flush()
        // scanMs is the inner work (scanner actor + file I/O + emit
        // hops). consumeMs is the watcher-actor hop to drain hinted
        // paths. The two are reported separately in PhaseTimings but
        // tickMs() advances `lastTick` either way, so the sum is the
        // total wall-clock budget of the JSONL pipeline this cycle.
        phase.consumeChangedPathsMs = consumeMs
        phase.scanMs = tickMs()
        try activePersister.flush()
        phase.flushMs = tickMs()
        try saveCursors(result.updatedCursors)
        phase.saveCursorsMs = tickMs()

        let cycleStats = SamplePersister.Stats(
            inserted: activePersister.stats.inserted - beforeStats.inserted,
            skippedAsDuplicate: activePersister.stats.skippedAsDuplicate - beforeStats.skippedAsDuplicate
        )

        let recomputer = AggregateRecomputer(
            container: container, context: context, mode: configuration.costMode)
        // Pass the persister's cycle-local pending-sample dicts so the
        // recomputer can take the incremental fast path on un-polluted
        // pairs whose `DailyAggregate` row already exists. Brand-new
        // pairs (no existing row) AND polluted pairs (recovery /
        // markEverySampleDirty / canonicalize) fall through to the
        // full recompute path — same code as before this change.
        // One projection of the sample table for every rollup this cycle.
        // Each bulk worker used to fetch the whole table into its own context;
        // on a cold start all three fire and that was ~3 s apiece re-reading
        // rows the previous worker had just read. Built lazily, so a normal
        // incremental cycle — every worker on its fast path — never touches it.
        let sampleSnapshots = SampleSnapshotCache(container: container)
        let recomputeStats = try await recomputer.recompute(
            pairs: activePersister.dirtyPairs,
            pending: activePersister.pendingPairSamples,
            polluted: activePersister.pollutedDailyPairs,
            snapshots: sampleSnapshots
        )
        phase.dailyRecomputeMs = tickMs()

        // Hourly rollup feeds TodayTimelineCard (24-bar hour-of-day
        // chart) and NowStrip (last-hour burn rate). Order
        // doesn't matter relative to the daily/project/session
        // recomputers — they all read from the same TokenSample
        // snapshot, the dirty sets don't overlap, and the cycle's
        // terminal save commits them together.
        let hourlyRecomputer = HourlyAggregateRecomputer(
            container: container,
            context: context,
            mode: configuration.costMode
        )
        let hourlyRecomputeStats = try await hourlyRecomputer.recompute(
            buckets: activePersister.dirtyHourBuckets,
            pending: activePersister.pendingHourSamples,
            polluted: activePersister.pollutedHourBuckets,
            snapshots: sampleSnapshots
        )
        phase.hourlyRecomputeMs = tickMs()

        // Both recomputers below previously ignored cost mode entirely
        // — they summed `sample.sourceCostUSD ?? 0`, which silently
        // recorded $0 for every Claude Code line that didn't carry a
        // stored cost. Threading the same cost mode + pricing table
        // that AggregateRecomputer uses fixes the Projects view's
        // $0.00 columns and the LiveActivity card's last-hour cost.
        // Capture the project paths touched THIS cycle before the
        // recompute consumes the persister's dirty set — a brand-new
        // project's aggregate isn't queryable in this context yet, so this
        // is how the color pass learns about first-scan projects.
        let dirtyProjectPathsThisCycle = Set(
            activePersister.dirtyProjectDates.map(\.projectPath)
        )
        let projectRecomputer = ProjectAggregateRecomputer(
            container: container,
            context: context,
            mode: configuration.costMode
        )
        let projectRecomputeStats = try await projectRecomputer.recompute(
            pairs: activePersister.dirtyProjectDates,
            pending: activePersister.pendingProjectSamples,
            polluted: activePersister.pollutedProjectPairs,
            snapshots: sampleSnapshots
        )
        phase.projectRecomputeMs = tickMs()

        // Record a stable color seed per project (git remote else path),
        // frozen in ProjectMeta so donut/legend colors survive renames and
        // rank shuffles. Idempotent (only seeds projects without one); runs
        // on a version-bump backfill, when new project aggregates landed,
        // or after an alias migration re-keyed rows.
        let storedColorSeedVersion = try fetchMeta(ClaudeCodeMetaKey.colorSeedVersion)
        let didAssignColors: Bool
        if storedColorSeedVersion != Self.currentColorSeedVersion
            || projectRecomputeStats.aggregatesUpserted > 0
            || needsPathMigration {
            // Committed rollups plus this cycle's freshly-seen project
            // paths (a brand-new project's aggregate isn't queryable in
            // this context until the terminal save). Canonicalize the whole
            // set through the current aliases: the committed rollup and the
            // dirty set both still carry the *pre*-merge path for anything
            // being aliased away this cycle (their rollup delete isn't
            // committed mid-cycle), which must not be re-seeded.
            var rawPaths = Set(try fetchDistinctProjectPaths())
            rawPaths.formUnion(dirtyProjectPathsThisCycle)
            var seedPaths = Set(
                rawPaths.map { ProjectPathCanonicalizer.canonicalize($0, aliases: aliases) }
            )
            seedPaths.remove(ProjectDailyAggregate.unknownProjectPath)
            didAssignColors = try assignProjectColorSeeds(paths: Array(seedPaths))
        } else {
            didAssignColors = false
        }

        let sessionRecomputer = SessionInfoRecomputer(
            container: container,
            context: context,
            mode: configuration.costMode
        )
        let sessionRecomputeStats = try await sessionRecomputer.recompute(
            sessionIds: activePersister.dirtySessionIds,
            snapshots: sampleSnapshots,
            pending: activePersister.pendingSessionSamples,
            polluted: activePersister.pollutedSessionIds
        )
        phase.sessionRecomputeMs = tickMs()

        var probeResult: StatsCacheProbe.ProbeResult?
        let probeNow = Date()
        let probeThrottleExpired: Bool = {
            guard let last = lastStatsCacheProbeAt else { return true }
            return probeNow.timeIntervalSince(last) >= Self.statsCacheProbeInterval
        }()
        if let probe, probeThrottleExpired {
            do {
                probeResult = try probe.probeAndStore(in: context)
                lastStatsCacheProbeAt = probeNow
            } catch StatsCacheProbe.ProbeError.fileMissing {
                // Not an error — fresh installs and Claude Code 1.x
                // stats-cache absence both land here. Mark as
                // attempted so we don't spin retries on every cycle.
                lastStatsCacheProbeAt = probeNow
            } catch {
                log("stats-cache probe failed: \(error)")
                lastStatsCacheProbeAt = probeNow
            }
        }
        phase.probeMs = tickMs()

        // Bookkeeping. Always write incremental cursor (even on full
        // scan, so the next run is incremental). scanVersion gates
        // future full re-scans on parser changes.
        //
        // **Save-skip optimization** — if nothing in this cycle
        // actually mutated user data (no inserts, no recomputed
        // aggregates, no recomputed sessions, no migration), skip the
        // meta-writes-and-save entirely. Each `context.save()` fires
        // SwiftData change notifications which cause every visible
        // `@Query` to refetch — even when there's nothing new to
        // show. Backstop ticks during idle periods were the worst
        // offenders here: a 60s backstop with zero file changes still
        // triggered a full chart refresh storm.
        //
        // `wroteMeta` is set only when we actually wrote something
        // user-visible; cursor updates are persisted unconditionally
        // because they're bounded (one file = one cursor row) and
        // never trigger view refetches (no view binds to
        // `JSONLFileCursor`).
        let cycleDidWork =
            cycleStats.inserted > 0
            || recomputeStats.aggregatesUpserted > 0
            || hourlyRecomputeStats.aggregatesUpserted > 0
            || projectRecomputeStats.aggregatesUpserted > 0
            || sessionRecomputeStats.sessionsUpserted > 0
            || needsCostRebuild
            || needsPathMigration
            || didAssignColors
        if cycleDidWork || isFullScan {
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
                Self.aliasesFingerprintMetaKey,
                value: aliasesFingerprint
            )
            try writeMeta(
                ClaudeCodeMetaKey.colorSeedVersion,
                value: Self.currentColorSeedVersion
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
        }
        // SwiftData's save still fires notifications even when we
        // didn't write any meta keys (cursor updates also dirty the
        // context). Skip when nothing's pending so views bound to
        // anything in the schema don't get woken up.
        if context.hasChanges {
            try context.save()
        }
        // saveMs covers the (up to five) `writeMeta` upserts plus the
        // terminal `context.save()`. The save is what fans @Query
        // refreshes out to every visible view — when this number is
        // big AND `cycleDidWork == true`, the UI is paying for it.
        phase.saveMs = tickMs()

        // Tell out-of-process consumers (WidgetKit, mainly — it doesn't
        // observe SwiftData @Query) that user-visible data shifted.
        // Gated on `cycleDidWork` so cursor-only saves don't burn the
        // widget reload budget, and on `needsPathMigration` so an
        // alias-driven re-attribution refreshes the project columns
        // even when no new TokenSamples landed.
        if cycleDidWork {
            // Fire-and-forget onto main (see `runAliasMigrationOnly`):
            // the post must run on main, but the cycle shouldn't wait on
            // main-thread availability to deliver a refresh hint.
            let summary = ScanCycleSummary(
                samplesChanged: true,
                projectAttributionChanged: needsPathMigration
            )
            Task { @MainActor in postScanCycleSummary(summary) }
            // Poll-on-wake: fresh Claude usage just landed, so nudge the
            // OAuth poller to re-evaluate its cadence — an idle→active
            // transition polls promptly instead of waiting out the idle
            // interval. The scheduler still enforces the per-token floor,
            // so this can never cause an over-poll.
            if let oauthPoller {
                Task { await oauthPoller.notifyActivity() }
            }
        }
        phase.notifMs = tickMs()

        return ScanReport(
            wasFullScan: isFullScan,
            scanProgress: result.progress,
            persisterStats: cycleStats,
            recomputeStats: recomputeStats,
            hourlyRecomputeStats: hourlyRecomputeStats,
            projectRecomputeStats: projectRecomputeStats,
            sessionRecomputeStats: sessionRecomputeStats,
            probeResult: probeResult,
            durationSeconds: Date().timeIntervalSince(started),
            phaseTimings: phase
        )
    }

    private func makePersister() throws -> SamplePersister {
        try SamplePersister(context: context, saveBatchSize: configuration.saveBatchSize)
    }

    /// Run a full scan through the injected bulk importer, shaped as a
    /// `JSONLScanner.ScanResult` so everything downstream — the sink, the
    /// persister, cursor saving, the phase log — behaves identically to the
    /// line parser's path.
    ///
    /// Cursors are seeded from the size/mtime the importer observed, so the
    /// next incremental cycle resumes at the end of what was imported rather
    /// than re-reading it. A file that grew in between is harmless: its mtime
    /// won't match the saved cursor, so the next scan re-opens it and reads
    /// the tail.
    private func bulkScan(
        importer: BulkTranscriptImporter,
        roots: [URL],
        aliases: [String: String],
        sink: InsertSink
    ) throws -> JSONLScanner.ScanResult {
        let imported = try importer.importAll(roots: roots, aliases: aliases)
        for entry in imported.entries { sink.consume(entry) }
        log(String(format: "bulk import: %d entries from %d files in %.1fs",
                   imported.entries.count, imported.fileMarks.count, imported.seconds))
        return JSONLScanner.ScanResult(
            progress: JSONLScanner.ScanProgress(
                filesScanned: imported.fileMarks.count,
                filesSkipped: 0,
                entriesParsed: imported.entries.count,
                entriesAccepted: imported.entries.count,
                // The importer deduplicates in SQL, so whatever it dropped is
                // already gone before we see it — reporting a number here
                // would be inventing one.
                duplicatesDropped: 0),
            updatedCursors: imported.fileMarks.mapValues {
                JSONLScanner.CursorState(byteOffset: $0.size, lastSeenMtime: $0.mtime)
            })
    }

    /// Return the cached cursor map, loading from disk on first call.
    /// Subsequent cycles reuse the cache — `saveCursors` mutates it
    /// in lock-step with the disk writes so the two never drift.
    private func loadCursorsCached() throws -> [String: JSONLScanner.CursorState] {
        if let cached = cursorsCache { return cached }
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
        cursorsCache = out
        return out
    }

    /// Persist cursor updates to disk and mirror them into the cache.
    /// Per-path fetch (one indexed lookup against `JSONLFileCursor.path
    /// @Attribute(.unique)`) replaces the previous full-table fetch —
    /// for a typical 1-3 updates per cycle that's a 1000× reduction
    /// in rows pulled from SwiftData per scan.
    private func saveCursors(_ updates: [String: JSONLScanner.CursorState]) throws {
        guard !updates.isEmpty else { return }
        for (path, state) in updates {
            let pathLocal = path
            let descriptor = FetchDescriptor<JSONLFileCursor>(
                predicate: #Predicate<JSONLFileCursor> { $0.path == pathLocal }
            )
            if let existing = try context.fetch(descriptor).first {
                existing.byteOffset = state.byteOffset
                existing.lastSeenMtime = state.lastSeenMtime
            } else {
                context.insert(JSONLFileCursor(
                    path: pathLocal,
                    byteOffset: state.byteOffset,
                    lastSeenMtime: state.lastSeenMtime
                ))
            }
            // Mirror into cache so the next cycle's `loadCursorsCached`
            // sees the same state. If we ever skip this update path
            // (early-return etc.), the cache would drift — keep the
            // mirror in lockstep with the disk write.
            cursorsCache?[pathLocal] = state
        }
    }

    /// Walk every `JSONLFileCursor` row, delete the ones whose path no
    /// longer exists on disk. Called once on startup from
    /// `runForever`. Returns the count deleted so the log line can
    /// report it. ~1 ms per stat × ~1000 cursors = ~300 ms one-shot
    /// startup cost; cleanup is permanent until new stale paths
    /// accumulate. Mirrors deletions into the in-memory cache if it's
    /// populated (it won't be on the very first startup call, but the
    /// guard is cheap and protects against future call-order
    /// reshuffling).
    private func pruneStaleCursors() throws -> Int {
        let descriptor = FetchDescriptor<JSONLFileCursor>()
        let rows = try context.fetch(descriptor)
        let fm = FileManager.default
        var deletedPaths: [String] = []
        for row in rows where !fm.fileExists(atPath: row.path) {
            deletedPaths.append(row.path)
            context.delete(row)
        }
        if cursorsCache != nil {
            for path in deletedPaths {
                cursorsCache?[path] = nil
            }
        }
        // Commit the prune so the table stays small even if the
        // startup scan errors out before its own save.
        if context.hasChanges {
            try context.save()
        }
        return deletedPaths.count
    }

    private func deleteAllCursors() throws {
        let descriptor = FetchDescriptor<JSONLFileCursor>()
        let rows = try context.fetch(descriptor)
        for row in rows {
            context.delete(row)
        }
        // Wipe the cache so the next cycle starts from an empty
        // cursor state (which then re-populates from disk —
        // empty until new scans write rows).
        cursorsCache = [:]
    }

    private func loadAliases() throws -> [String: String] {
        let descriptor = FetchDescriptor<ProjectPathAlias>()
        let rows = try context.fetch(descriptor)
        var out: [String: String] = [:]
        out.reserveCapacity(rows.count)
        for row in rows {
            out[row.sourcePath] = row.canonicalPath
        }
        return out
    }

    /// Distinct project paths Pacer has seen so far. Sourced from
    /// the `ProjectDailyAggregate` rollup (smaller than walking
    /// `TokenSample`) and used as the candidate set for
    /// auto-aliasing. Filters out the synthetic "(unknown)" bucket
    /// so we don't try to walk a non-path.
    private func fetchDistinctProjectPaths() throws -> [String] {
        var descriptor = FetchDescriptor<ProjectDailyAggregate>()
        descriptor.propertiesToFetch = [\.projectPath]
        let rows = try context.fetch(descriptor)
        var set: Set<String> = []
        set.reserveCapacity(rows.count)
        for row in rows where row.projectPath != ProjectDailyAggregate.unknownProjectPath {
            set.insert(row.projectPath)
        }
        return Array(set)
    }

    /// Re-key path-keyed *user* rows (ProjectMeta color seeds, ProjectBudget
    /// caps) through the canonicalizer after an alias change. Unlike
    /// aggregates, these aren't rebuilt from samples, so a merge would
    /// leave them stranded at the pre-merge path. On a unique-key collision
    /// (the canonical path already has a row) the canonical row wins and the
    /// source row is deleted.
    private func reattributeUserRows(aliases: [String: String]) throws {
        guard !aliases.isEmpty else { return }

        // Delete-old + insert-new rather than mutating the projectPath in
        // place: SwiftData doesn't reliably persist an in-place change to a
        // `@Attribute(.unique)` key.
        let metas = try context.fetch(FetchDescriptor<ProjectMeta>())
        var metaPaths = Set(metas.map(\.projectPath))
        for row in metas {
            let canon = ProjectPathCanonicalizer.canonicalize(row.projectPath, aliases: aliases)
            guard canon != row.projectPath else { continue }
            if !metaPaths.contains(canon) {
                context.insert(ProjectMeta(
                    projectPath: canon,
                    colorSeed: row.colorSeed,
                    colorHex: row.colorHex,
                    updatedAt: row.updatedAt
                ))
                metaPaths.insert(canon)
            }
            context.delete(row)
            metaPaths.remove(row.projectPath)
        }

        let budgets = try context.fetch(FetchDescriptor<ProjectBudget>())
        var budgetPaths = Set(budgets.map(\.projectPath))
        for row in budgets {
            let canon = ProjectPathCanonicalizer.canonicalize(row.projectPath, aliases: aliases)
            guard canon != row.projectPath else { continue }
            if !budgetPaths.contains(canon) {
                context.insert(ProjectBudget(
                    projectPath: canon,
                    dailyLimitUSD: row.dailyLimitUSD,
                    weeklyLimitUSD: row.weeklyLimitUSD,
                    enabled: row.enabled,
                    updatedAt: row.updatedAt
                ))
                budgetPaths.insert(canon)
            }
            context.delete(row)
            budgetPaths.remove(row.projectPath)
        }
    }

    /// Record a stable `ProjectMeta.colorSeed` — the git remote origin URL
    /// when the project has one, else its canonical path — for every project
    /// that lacks one. Frozen once so the derived donut/legend color
    /// survives folder renames, remote changes, and rank reshuffles.
    /// Idempotent; returns true if it created or updated any row. `paths`
    /// is the current canonical project set (committed rollups ∪ this
    /// cycle's freshly-seen paths — the latter aren't in the queryable
    /// aggregate table yet on a first scan).
    private func assignProjectColorSeeds(paths: [String]) throws -> Bool {
        guard !paths.isEmpty else { return false }
        let metas = try context.fetch(FetchDescriptor<ProjectMeta>())
        var metaByPath = Dictionary(metas.map { ($0.projectPath, $0) }, uniquingKeysWith: { a, _ in a })
        let probes = try context.fetch(FetchDescriptor<ProjectPathProbe>())
        var originByPath: [String: String] = [:]
        for p in probes {
            if let origin = p.originURL, !origin.isEmpty { originByPath[p.path] = origin }
        }
        var changed = false
        for path in paths {
            let seed = originByPath[path] ?? path
            if let existing = metaByPath[path] {
                if existing.colorSeed == nil {
                    existing.colorSeed = seed
                    changed = true
                }
            } else {
                let meta = ProjectMeta(projectPath: path, colorSeed: seed)
                context.insert(meta)
                metaByPath[path] = meta
                changed = true
            }
        }
        return changed
    }

    /// Deterministic fingerprint of an alias dictionary. Stable across
    /// process restarts; changes whenever any key/value differs. Used
    /// to detect "user changed an alias" between scans without
    /// requiring the UI to flip a meta flag.
    nonisolated static func fingerprint(aliases: [String: String]) -> String {
        if aliases.isEmpty { return "empty" }
        // Sort the pairs so insertion order doesn't matter.
        let sorted = aliases.sorted { $0.key < $1.key }
        let joined = sorted.map { "\($0.key)\u{001F}\($0.value)" }.joined(separator: "\u{001E}")
        // Simple stable hash. Cryptographic strength not required — we
        // only care that two equal alias maps produce equal strings
        // and unequal ones don't. `String.hashValue` would do but
        // Swift's hash is randomized per-process; this stays stable
        // across restarts.
        return Self.fnv1aHex(joined)
    }

    /// FNV-1a 64-bit hash of the joined string, rendered as hex. Tiny,
    /// stable across processes, no external dependency.
    nonisolated private static func fnv1aHex(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
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
    ///
    /// Format:
    ///   `<kind> files=N skipped=N parsed=N inserted=N dups=N
    ///    aggs=N hourAggs=N projAggs=N sess=N ms=N
    ///    [autoA=N prep=N mig=N scan=N flush=N curs=N
    ///     dailyR=N hourR=N projR=N sessR=N probe=N save=N notif=N]`
    ///
    /// The bracketed phase tail is what makes "the 1500ms cycle"
    /// debuggable post-hoc — without it the log only tells you the
    /// total. Phases are in execution order so reading left-to-right
    /// follows the cycle.
    private func formatReport(_ r: ScanReport) -> String {
        let kind = r.wasFullScan ? "full" : "incremental"
        // `fast=N/M` shows fast-path-applied / pairs-recomputed for the
        // daily rollup. The same ratio holds approximately for hourly
        // (most active hour buckets have the same dirtying pattern as
        // their parent (date, model) pair) so one column is enough.
        let dailyFast = r.recomputeStats.fastPathApplied
        let dailyPairs = r.recomputeStats.pairsRecomputed
        let base = "\(kind) files=\(r.scanProgress.filesScanned) skipped=\(r.scanProgress.filesSkipped) parsed=\(r.scanProgress.entriesParsed) inserted=\(r.persisterStats.inserted) dups=\(r.persisterStats.skippedAsDuplicate) aggs=\(r.recomputeStats.aggregatesUpserted) hourAggs=\(r.hourlyRecomputeStats.aggregatesUpserted) projAggs=\(r.projectRecomputeStats.aggregatesUpserted) sess=\(r.sessionRecomputeStats.sessionsUpserted) fast=\(dailyFast)/\(dailyPairs) ms=\(Int(r.durationSeconds * 1000))"
        let p = r.phaseTimings
        let phases = "[autoA=\(Self.fmtMs(p.autoAliasMs)) prep=\(Self.fmtMs(p.metaPrepMs)) mig=\(Self.fmtMs(p.migrationMs)) consume=\(Self.fmtMs(p.consumeChangedPathsMs)) scan=\(Self.fmtMs(p.scanMs)) flush=\(Self.fmtMs(p.flushMs)) curs=\(Self.fmtMs(p.saveCursorsMs)) dailyR=\(Self.fmtMs(p.dailyRecomputeMs)) hourR=\(Self.fmtMs(p.hourlyRecomputeMs)) projR=\(Self.fmtMs(p.projectRecomputeMs)) sessR=\(Self.fmtMs(p.sessionRecomputeMs)) probe=\(Self.fmtMs(p.probeMs)) save=\(Self.fmtMs(p.saveMs)) notif=\(Self.fmtMs(p.notifMs))]"
        return "\(base) \(phases)"
    }

    /// Round to int milliseconds for the log line — every phase emits
    /// hundreds of values per minute on an active machine, sub-ms
    /// precision adds noise without signal. Tests can still read the
    /// raw `Double` off `PhaseTimings`.
    private static func fmtMs(_ ms: Double) -> String {
        String(Int(ms.rounded()))
    }
}

/// Bridges scanner emit (off-actor, sync) into MainActor-isolated
/// SwiftData inserts. The scanner runs on its own actor and used to
/// `await sink.consume(entry)` per parsed line — which under MainActor
/// pressure was ~100 ms of suspend/resume PER ENTRY. We now collect
/// all parsed entries into a Sendable array (lock-protected) during
/// the scan, then `flush()` them all on MainActor in one shot. That
/// turns N MainActor hops into 1, regardless of cycle entry count.
///
/// `@unchecked Sendable` because the lock is what makes this safe to
/// cross queues; Swift can't see through the lock to verify.
private final class InsertSink: @unchecked Sendable {
    private let persister: SamplePersister
    private let lock = NSLock()
    /// Entries collected by `consume` during scan, drained by `flush`.
    /// `nonisolated(unsafe)` because the lock is the synchronization
    /// primitive — nothing else may touch this field.
    private var collected: [ParsedUsageEntry] = []
    private var firstError: Error?

    init(persister: SamplePersister) {
        self.persister = persister
    }

    /// Called by the scanner actor on each parsed line. Sync — no
    /// MainActor hop. Just appends to the collected list.
    func consume(_ entry: ParsedUsageEntry) {
        lock.lock()
        collected.append(entry)
        lock.unlock()
    }

    /// MainActor pass that inserts every collected entry into the
    /// persister and surfaces the first error. Called by ScanCoordinator
    /// once after `scanner.scan` returns. One MainActor pass instead of
    /// one-hop-per-entry is the entire point of this design.
    @ScanActor
    func flush() throws {
        lock.lock()
        let toInsert = collected
        collected.removeAll(keepingCapacity: true)
        lock.unlock()
        for entry in toInsert {
            do {
                _ = try persister.insert(entry)
            } catch {
                firstError = error
                break
            }
        }
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
