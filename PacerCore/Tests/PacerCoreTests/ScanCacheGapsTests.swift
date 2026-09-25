import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Gaps around `SessionRollupCache` (#144) and the per-rollup fast-path log
/// columns (#146).
@Suite struct ScanCacheGapsTests {

    /// The live rebuild re-derives active sessions, not every session: one
    /// that went quiet hours ago is settled and must not be rebuilt every ten
    /// minutes, while one inside the window is forced onto the full path.
    @ScanActor
    @Test func liveRebuildFoldsInOnlyRecentlyActiveSessions() async throws {
        let container = try makeGapsContainer()
        let context = ModelContext(container)
        let now = Date()
        let calendar = Calendar.current
        let windowStart = try #require(
            calendar.dateInterval(of: .hour, for: now.addingTimeInterval(-3600))).start
        context.insert(SessionInfo(
            sessionId: "quiet", firstSeenAt: now.addingTimeInterval(-6 * 3600),
            lastSeenAt: now.addingTimeInterval(-5 * 3600), projectPath: "/p"))
        context.insert(SessionInfo(
            sessionId: "active", firstSeenAt: now.addingTimeInterval(-3600),
            lastSeenAt: now.addingTimeInterval(-600), projectPath: "/p"))
        context.insert(SessionInfo(
            sessionId: "edge", firstSeenAt: windowStart.addingTimeInterval(-60),
            lastSeenAt: windowStart, projectPath: "/p"))
        context.insert(SessionInfo(
            sessionId: "just-before", firstSeenAt: windowStart.addingTimeInterval(-120),
            lastSeenAt: windowStart.addingTimeInterval(-1), projectPath: "/p"))
        try context.save()

        let root = try makeGapsFixtureRoot(lines: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(container: container, root: root)
        let persister = try SamplePersister(context: context)

        // No DailyAggregate rows at all: sessions must not hide behind the
        // bucket rebuild's "nothing open today" early return.
        try coordinator.rebuildLiveBuckets(persister: persister, now: now)

        #expect(persister.dirtySessionIds == ["active", "edge"])
        #expect(persister.pollutedSessionIds == ["active", "edge"],
                "polluted is what forces the full path and re-seeds the cache")
    }

    /// A burst of sessions can't turn the ten-minute rebuild into a full
    /// session rebuild — the fetch is capped, newest first.
    @ScanActor
    @Test func liveRebuildIsBounded() async throws {
        let container = try makeGapsContainer()
        let context = ModelContext(container)
        let now = Date()
        let limit = ScanCoordinator.liveSessionRebuildLimit
        for i in 0..<(limit + 10) {
            context.insert(SessionInfo(
                sessionId: "s\(i)", firstSeenAt: now.addingTimeInterval(-1800),
                lastSeenAt: now.addingTimeInterval(-Double(i)), projectPath: "/p"))
        }
        try context.save()
        let root = try makeGapsFixtureRoot(lines: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator(container: container, root: root)

        let ids = try coordinator.liveSessionIds(now: now)
        #expect(ids.count == limit)
        #expect(ids.contains("s0"))
        #expect(!ids.contains("s\(limit + 9)"))
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
