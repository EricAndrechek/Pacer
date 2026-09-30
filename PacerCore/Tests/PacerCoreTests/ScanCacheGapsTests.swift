import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Gaps around `SessionRollupCache` (#144) and the per-rollup fast-path log
/// columns (#146).
@Suite struct ScanCacheGapsTests {

    /// A cached entry is trusted for `maxAge` (± jitter) after it was built
    /// from samples, never longer — whatever the fast path does in between —
    /// and an entry that never came from the full path is never trusted.
    @ScanActor
    @Test func sessionCacheEntriesExpireAfterMaxAge() {
        let cache = SessionRollupCache()
        let values = SessionRollupCache.Values(global: SessionRollupValues(), byAccount: [:])
        let t0 = Date(timeIntervalSince1970: 1_756_800_000)
        let earliest = SessionRollupCache.maxAge - SessionRollupCache.maxAgeJitter
        let latest = SessionRollupCache.maxAge + SessionRollupCache.maxAgeJitter

        cache.store(values, for: "s", rebuiltAt: t0)
        #expect(cache.values(for: "s", now: t0.addingTimeInterval(earliest - 1)) != nil)
        cache.store(values, for: "s")                    // fast path: no extension
        #expect(cache.values(for: "s", now: t0.addingTimeInterval(latest)) == nil)

        cache.store(values, for: "s", rebuiltAt: t0.addingTimeInterval(latest))  // full path
        #expect(cache.values(for: "s", now: t0.addingTimeInterval(latest + earliest - 1)) != nil)

        cache.store(values, for: "never-rebuilt")
        #expect(cache.values(for: "never-rebuilt", now: t0) == nil)

        cache.forget(["s"])
        #expect(cache.values(for: "s", now: t0.addingTimeInterval(latest + 1)) == nil)
    }

    /// Sessions first seen together must not all expire in the same scan.
    @ScanActor
    @Test func sessionCacheExpiriesAreSpread() {
        let cache = SessionRollupCache()
        let values = SessionRollupCache.Values(global: SessionRollupValues(), byAccount: [:])
        let t0 = Date(timeIntervalSince1970: 1_756_800_000)
        for i in 0..<50 { cache.store(values, for: "s\(i)", rebuiltAt: t0) }
        let probe = t0.addingTimeInterval(SessionRollupCache.maxAge)
        let alive = (0..<50).filter { cache.values(for: "s\($0)", now: probe) != nil }.count
        #expect(alive > 0 && alive < 50)
    }

    /// Cached session values bake in the prices they were built under; a
    /// price change must drop them so the next touch rebuilds from samples.
    @ScanActor
    @Test func sessionCacheForgetsEverythingWhenPricingChanges() {
        let cache = SessionRollupCache()
        let values = SessionRollupCache.Values(global: SessionRollupValues(), byAccount: [:])

        // First check records the generation (and clears whatever is there).
        cache.store(values, for: "a")
        #expect(cache.forgetAllIfPricingChanged(generation: 1))
        #expect(cache.count == 0)

        // Same generation: entries survive, every cycle.
        cache.store(values, for: "a")
        cache.store(values, for: "b")
        #expect(!cache.forgetAllIfPricingChanged(generation: 1))
        #expect(!cache.forgetAllIfPricingChanged(generation: 1))
        #expect(cache.count == 2)

        // Prices changed: everything goes, nothing is recomputed here.
        #expect(cache.forgetAllIfPricingChanged(generation: 2))
        #expect(cache.count == 0)
        #expect(cache.values(for: "a") == nil)
    }

    /// `reload()` runs on every cost-mode flip and pricing refresh, usually
    /// with identical prices. Those must not bump the generation, or every
    /// flip would throw away the whole session cache for nothing.
    @MainActor
    @Test func reinstallingIdenticalPricesKeepsTheGeneration() {
        let before = SampleCostCache.generation
        SampleCostCache.install(SampleCostCache.current())
        #expect(SampleCostCache.generation == before)
    }

    /// Every rollup's fast-path ratio is in the scan log line, and the
    /// daily `fast=` token keeps its shape for existing greps.
    @ScanActor
    @Test func scanReportLogsEveryRollupsFastPathRatio() async throws {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let root = try makeGapsFixtureRoot(lines: [
            makeGapsLine(timestamp: stamp.string(from: Date()), messageId: "m1", requestId: "r1")
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeGapsContainer()
        let coordinator = makeCoordinator(container: container, root: root)

        let line = coordinator.formatReport(try await coordinator.runOnce())

        for key in ["fast", "hFast", "pFast", "sFast"] {
            #expect(line.range(of: " \(key)=\\d+/1 ", options: .regularExpression) != nil,
                    "\(key)= missing or malformed: \(line)")
        }
        // Adjacent, daily first: `fast=N/M` is still followed by a space, so
        // a grep anchored on it keeps matching.
        #expect(line.range(of: #" fast=\d+/\d+ hFast=\d+/\d+ pFast=\d+/\d+ sFast=\d+/\d+ sMiss=\d+/\d+/\d+ ms="#,
                           options: .regularExpression) != nil, "\(line)")
    }

    /// `upg=` read 0 whatever happened, because the per-cycle stats never
    /// copied it, and #149 ruled streamed upgrades out on that reading. A
    /// cycle that replaces a partial streamed copy with its finished one has
    /// to say so, and say it polluted the session (#177).
    @ScanActor
    @Test func upgradeIsCountedAndNamedInTheScanLine() async throws {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let when = stamp.string(from: Date())
        let partial = makeGapsLine(timestamp: when, messageId: "m1", requestId: "r1",
                                   outputTokens: 20, stopReason: nil)
        let finished = makeGapsLine(timestamp: when, messageId: "m1", requestId: "r1",
                                    outputTokens: 400, stopReason: "end_turn")
        let root = try makeGapsFixtureRoot(lines: [partial])
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeGapsContainer()
        let coordinator = makeCoordinator(container: container, root: root)
        let first = try await coordinator.runOnce()
        #expect(first.persisterStats.inserted == 1)
        #expect(first.persisterStats.upgradedFromPartial == 0)

        // The finished copy lands in the next cycle, as it does when a scan
        // falls between two writes of one streamed message.
        let file = root.appendingPathComponent("projects/-tmp-fixture/gaps-session.jsonl")
        try ([partial, finished].joined(separator: "\n") + "\n")
            .write(to: file, atomically: false, encoding: .utf8)
        let second = try await coordinator.runOnce()

        #expect(second.persisterStats.upgradedFromPartial == 1)
        #expect(second.persisterStats.sessionPollution == ["upgrade": 1])
        let line = coordinator.formatReport(second)
        #expect(line.contains(" upg=1 "), "\(line)")
        #expect(line.range(of: #" sMiss=\d+/\d+/\d+ sPol=upgrade:1 ms="#,
                           options: .regularExpression) != nil, "\(line)")
    }

    @Test func pollutionTokenIsEmptyWhenNothingWasPolluted() {
        #expect(ScanCoordinator.pollutionToken([:]) == "")
        #expect(ScanCoordinator.pollutionToken(["upgrade": 2, "cap": 1]) == " sPol=cap:1,upgrade:2")
    }
}

// MARK: - Fixtures

@ScanActor
private func makeCoordinator(container: ModelContainer, root: URL) -> ScanCoordinator {
    ScanCoordinator(
        container: container,
        configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
        resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]))
}

private func makeGapsContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Schema(PacerStore.allModelTypes),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

private func makeGapsFixtureRoot(lines: [String]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-gaps-\(UUID().uuidString)")
    let projectsDir = root.appendingPathComponent("projects/-tmp-fixture")
    try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    if !lines.isEmpty {
        try (lines.joined(separator: "\n") + "\n")
            .write(to: projectsDir.appendingPathComponent("gaps-session.jsonl"),
                   atomically: true, encoding: .utf8)
    }
    return root
}

private func makeGapsLine(timestamp: String, messageId: String, requestId: String,
                          outputTokens: Int = 200, stopReason: String? = nil) -> String {
    var message: [String: Any] = [
        "model": "claude-opus-4-8",
        "id": messageId,
        "usage": [
            "input_tokens": 100,
            "output_tokens": outputTokens,
            "cache_read_input_tokens": 0,
            "cache_creation": [
                "ephemeral_5m_input_tokens": 0,
                "ephemeral_1h_input_tokens": 0,
            ],
        ],
    ]
    if let stopReason { message["stop_reason"] = stopReason }
    let fields: [String: Any] = [
        "type": "assistant",
        "timestamp": timestamp,
        "requestId": requestId,
        "sessionId": "gaps-session",
        "cwd": "/tmp/acme",
        "costUSD": 0.25,
        "message": message,
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
}
