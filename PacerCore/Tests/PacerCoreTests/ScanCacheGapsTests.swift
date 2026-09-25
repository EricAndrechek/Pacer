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
        #expect(line.range(of: #" fast=\d+/\d+ hFast=\d+/\d+ pFast=\d+/\d+ sFast=\d+/\d+ ms="#,
                           options: .regularExpression) != nil, "\(line)")
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

private func makeGapsLine(timestamp: String, messageId: String, requestId: String) -> String {
    let fields: [String: Any] = [
        "type": "assistant",
        "timestamp": timestamp,
        "requestId": requestId,
        "sessionId": "gaps-session",
        "cwd": "/tmp/acme",
        "costUSD": 0.25,
        "message": [
            "model": "claude-opus-4-8",
            "id": messageId,
            "usage": [
                "input_tokens": 100,
                "output_tokens": 200,
                "cache_read_input_tokens": 0,
                "cache_creation": [
                    "ephemeral_5m_input_tokens": 0,
                    "ephemeral_1h_input_tokens": 0,
                ],
            ],
        ] as [String: Any],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
}
