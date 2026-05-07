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
    public static let currentScanVersion = "1"

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
        public let probeResult: StatsCacheProbe.ProbeResult?
        public let durationSeconds: Double
    }

    private let context: ModelContext
    private let configuration: Configuration
    private let scanner: JSONLScanner
    private let watcher: JSONLWatcher
    private let resolver: ClaudePathResolver
    private let probe: StatsCacheProbe?
    /// nil disables OAuth polling. Tests leave this nil so no network
    /// or keychain access happens; the daemon constructs a default
    /// `OAuthClient()` to enable Tier 3 rate-limit windowing.
    private let oauthPoller: OAuthPoller?

    private var resolvedRoots: [ClaudePathResolver.ResolvedRoot] = []
    private var scanInFlight = false
    /// Long-lived persister so its in-memory dedup Set is built once.
    /// Lazily constructed on the first scan cycle so tests that never
    /// scan don't pay the preload cost.
    private var persister: SamplePersister?

    public init(
        container: ModelContainer,
        configuration: Configuration = Configuration(),
        statsCacheURL: URL? = nil,
        resolver: ClaudePathResolver = ClaudePathResolver(),
        oauthClient: OAuthClient? = nil
    ) {
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
            log("startup scan complete: \(formatReport(report))")
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
                if report.persisterStats.inserted > 0 {
                    log("incremental scan: \(formatReport(report))")
                }
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
        // recomputer only touches buckets the cycle actually changed.
        activePersister.clearDirtyPairs()
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

        let recomputer = AggregateRecomputer(context: context, mode: configuration.costMode)
        let recomputeStats = try await recomputer.recompute(pairs: activePersister.dirtyPairs)

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
        FileHandle.standardError.write(Data("[ScanCoordinator] \(message)\n".utf8))
    }

    private func formatReport(_ r: ScanReport) -> String {
        let kind = r.wasFullScan ? "full" : "incremental"
        return "\(kind) | files=\(r.scanProgress.filesScanned) skipped=\(r.scanProgress.filesSkipped) parsed=\(r.scanProgress.entriesParsed) inserted=\(r.persisterStats.inserted) dups=\(r.persisterStats.skippedAsDuplicate) aggs=\(r.recomputeStats.aggregatesUpserted) ms=\(Int(r.durationSeconds * 1000))"
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
