import Foundation
import SwiftData

/// Orchestrates one scan cycle and (in `runForever`) keeps cycling on
/// FSEvents triggers. Owns no parsing logic — just glues together the
/// resolver, scanner, persister, recomputer, probe, and watcher.
///
/// The full-vs-incremental decision keys off `ClaudeCodeMetaKey.scanVersion`:
/// when the on-disk version doesn't match this binary's
/// `currentScanVersion`, every JSONL gets re-read so a parser change
/// (e.g. we start tracking a new field) re-classifies historical data.
/// Otherwise the scanner uses the previous scan's start time as an
/// `mtimeAfter` cutoff so files that haven't been touched aren't
/// reopened.
@MainActor
public final class ScanCoordinator {

    /// Bump this constant when a parser/aggregation change requires
    /// re-reading historical JSONL. The daemon will detect the version
    /// drift on next launch and do a full historical scan.
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
            // will be picked up by the next trigger (the watcher fires
            // on every modification batch), or at the latest by the
            // next 60s backstop.
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
        let cutoff: Date? = isFullScan ? nil : try fetchMetaDate(ClaudeCodeMetaKey.lastIncrementalScanAt)

        let persister = try SamplePersister(context: context, saveBatchSize: configuration.saveBatchSize)

        // The scanner's emit closure is @Sendable but we need to hop
        // back into MainActor land to touch SwiftData. The InsertSink
        // wraps this hop and surfaces the first error so we don't
        // silently swallow disk-full / migration-failed conditions.
        let sink = InsertSink(persister: persister)
        let progress = try await scanner.scan(
            roots: resolvedRoots,
            mtimeAfter: cutoff,
            emit: { entry in await sink.consume(entry) }
        )
        try sink.throwIfError()
        try persister.flush()

        let recomputer = AggregateRecomputer(context: context, mode: configuration.costMode)
        let recomputeStats = try await recomputer.recompute(pairs: persister.dirtyPairs)

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
            scanProgress: progress,
            persisterStats: persister.stats,
            recomputeStats: recomputeStats,
            probeResult: probeResult,
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    private func fetchMeta(_ key: String) throws -> String? {
        let descriptor = FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
        return try context.fetch(descriptor).first?.value
    }

    private func fetchMetaDate(_ key: String) throws -> Date? {
        guard let raw = try fetchMeta(key) else { return nil }
        return ISO8601DateFormatter.shared.date(from: raw)
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
        return "\(kind) | files=\(r.scanProgress.filesScanned) parsed=\(r.scanProgress.entriesParsed) inserted=\(r.persisterStats.inserted) dups=\(r.persisterStats.skippedAsDuplicate) aggs=\(r.recomputeStats.aggregatesUpserted) ms=\(Int(r.durationSeconds * 1000))"
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
