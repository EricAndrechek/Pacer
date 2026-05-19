import Foundation
import SwiftData
import Testing
@testable import PacerCore

private func makeInMemoryContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: Heartbeat.self,
        TokenSample.self,
        DailyAggregate.self,
        HourlyAggregate.self,
        ProjectDailyAggregate.self,
        RateLimitSample.self,
        SessionInfo.self,
        ClaudeCodeMeta.self,
        ProjectPathAlias.self,
        configurations: config
    )
}

/// Builds a tmpdir mimicking `~/.claude/projects/` shape with a single
/// JSONL file. Returns the tmpdir root (which has a `projects/` subdir,
/// matching what ClaudePathResolver expects via CLAUDE_CONFIG_DIR override).
private func makeFixtureRoot(
    withLines lines: [String],
    sessionId: String = "fixture-session"
) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-fixture-\(UUID().uuidString)")
    let projectsDir = root.appendingPathComponent("projects/-tmp-fixture")
    try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    let jsonlURL = projectsDir.appendingPathComponent("\(sessionId).jsonl")
    let body = lines.joined(separator: "\n") + "\n"
    try body.write(to: jsonlURL, atomically: true, encoding: .utf8)
    return root
}

private func makeAssistantLine(
    timestamp: String,
    model: String = "claude-opus-4-7",
    inputTokens: Int = 100,
    outputTokens: Int = 200,
    cacheRead: Int = 0,
    cache5m: Int = 0,
    cache1h: Int = 0,
    storedCost: Double? = nil,
    messageId: String? = nil,
    requestId: String? = nil,
    cwd: String? = nil,
    sessionId: String? = nil
) -> String {
    var fields: [String: Any] = [
        "type": "assistant",
        "timestamp": timestamp,
        "message": [
            "model": model,
            "id": messageId as Any?,
            "usage": [
                "input_tokens": inputTokens,
                "output_tokens": outputTokens,
                "cache_read_input_tokens": cacheRead,
                "cache_creation": [
                    "ephemeral_5m_input_tokens": cache5m,
                    "ephemeral_1h_input_tokens": cache1h,
                ],
            ],
        ] as [String: Any?]
    ]
    if let storedCost { fields["costUSD"] = storedCost }
    if let requestId { fields["requestId"] = requestId }
    if let cwd { fields["cwd"] = cwd }
    if let sessionId { fields["sessionId"] = sessionId }
    let cleaned = fields.compactMapValues { $0 is NSNull ? nil : $0 }
    return String(data: try! JSONSerialization.data(withJSONObject: cleaned), encoding: .utf8)!
}

@MainActor
@Test func coordinatorRunOnceFullScanInsertsAndAggregates() async throws {
    let line1 = makeAssistantLine(
        timestamp: "2026-04-30T12:00:00.000Z",
        inputTokens: 100, outputTokens: 50,
        storedCost: 0.10,
        messageId: "msg1", requestId: "req1"
    )
    let line2 = makeAssistantLine(
        timestamp: "2026-04-30T12:05:00.000Z",
        inputTokens: 200, outputTokens: 80,
        storedCost: 0.20,
        messageId: "msg2", requestId: "req2"
    )
    let root = try makeFixtureRoot(withLines: [line1, line2])
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])

    let container = try makeInMemoryContainer()
    let coordinator = ScanCoordinator(
        container: container,
        configuration: .init(
            costMode: .display, // avoid network for pricing
            watcherMode: .manual,
            probeStatsCache: false
        ),
        resolver: resolver
    )
    let report = try await coordinator.runOnce()

    #expect(report.wasFullScan == true)
    #expect(report.scanProgress.entriesAccepted == 2)
    #expect(report.persisterStats.inserted == 2)
    #expect(report.recomputeStats.aggregatesUpserted == 1)

    let context = ModelContext(container)
    #expect(try context.fetchCount(FetchDescriptor<TokenSample>()) == 2)

    let aggs = try context.fetch(FetchDescriptor<DailyAggregate>())
    #expect(aggs.count == 1)
    #expect(aggs[0].inputTokens == 300)
    #expect(aggs[0].outputTokens == 130)
    #expect(abs(aggs[0].totalCostUSD - 0.30) < 0.0001)
}

@MainActor
@Test func coordinatorSecondRunIsIncremental() async throws {
    let line = makeAssistantLine(
        timestamp: "2026-04-30T12:00:00.000Z",
        messageId: "msg-only", requestId: "req-only"
    )
    let root = try makeFixtureRoot(withLines: [line])
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])

    let container = try makeInMemoryContainer()
    let coordinator = ScanCoordinator(
        container: container,
        configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
        resolver: resolver
    )

    let first = try await coordinator.runOnce()
    #expect(first.wasFullScan == true)

    // Second invocation: scanVersion key in ClaudeCodeMeta now matches.
    let second = try await coordinator.runOnce()
    #expect(second.wasFullScan == false)
}

@MainActor
@Test func coordinatorDedupesAcrossRuns() async throws {
    // The full scan inserts one row; a second full scan (which would
    // happen after a parser version bump) should NOT duplicate it
    // because SamplePersister pre-loads existing dedupKeys.
    let line = makeAssistantLine(
        timestamp: "2026-04-30T12:00:00.000Z",
        inputTokens: 1, outputTokens: 1,
        messageId: "m", requestId: "r"
    )
    let root = try makeFixtureRoot(withLines: [line])
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])

    let container = try makeInMemoryContainer()
    let coordinator1 = ScanCoordinator(
        container: container,
        configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
        resolver: resolver
    )
    _ = try await coordinator1.runOnce()
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<TokenSample>()) == 1)

    // Force a "full scan" path: clear scanVersion meta and instantiate a
    // fresh coordinator (simulating a binary upgrade with parser bump).
    let context = ModelContext(container)
    if let meta = try context.fetch(
        FetchDescriptor<ClaudeCodeMeta>(predicate: #Predicate { $0.key == "scan_version" })
    ).first {
        context.delete(meta)
        try context.save()
    }

    let coordinator2 = ScanCoordinator(
        container: container,
        configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
        resolver: resolver
    )
    let report = try await coordinator2.runOnce()
    #expect(report.wasFullScan == true)
    #expect(report.persisterStats.skippedAsDuplicate == 1)
    // Critical assertion: still ONE row, not two.
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<TokenSample>()) == 1)
}

@MainActor
@Test func coordinatorWritesScanMetaFields() async throws {
    let line = makeAssistantLine(
        timestamp: "2026-04-30T12:00:00.000Z",
        messageId: "a", requestId: "b"
    )
    let root = try makeFixtureRoot(withLines: [line])
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])

    let container = try makeInMemoryContainer()
    let coordinator = ScanCoordinator(
        container: container,
        configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
        resolver: resolver
    )
    _ = try await coordinator.runOnce()

    let context = ModelContext(container)
    let metas = try context.fetch(FetchDescriptor<ClaudeCodeMeta>())
    let byKey = Dictionary(uniqueKeysWithValues: metas.map { ($0.key, $0.value) })
    #expect(byKey[ClaudeCodeMetaKey.scanVersion] == ScanCoordinator.currentScanVersion)
    #expect(byKey[ClaudeCodeMetaKey.lastFullScanAt] != nil)
    #expect(byKey[ClaudeCodeMetaKey.lastIncrementalScanAt] != nil)
}

@MainActor
@Test func coordinatorSkipsSyntheticAndUnparseable() async throws {
    let assistant = makeAssistantLine(
        timestamp: "2026-04-30T12:00:00.000Z",
        messageId: "ok", requestId: "ok"
    )
    let synthetic = makeAssistantLine(
        timestamp: "2026-04-30T12:00:00.000Z",
        model: "<synthetic>", messageId: "syn", requestId: "syn"
    )
    let garbage = "this is not json at all"
    let root = try makeFixtureRoot(withLines: [assistant, synthetic, garbage])
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])

    let container = try makeInMemoryContainer()
    let coordinator = ScanCoordinator(
        container: container,
        configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
        resolver: resolver
    )
    let report = try await coordinator.runOnce()
    // Only the assistant line landed.
    #expect(report.persisterStats.inserted == 1)
}

@MainActor
@Test func coordinatorRunForeverStartsAndStopsOAuthPoller() async throws {
    // Wire-in test: when an OAuthClient is provided, runForever() should
    // start the poller alongside the watcher and writes will accumulate
    // until stop(). Use .manual watcher so the for-await loop blocks
    // exactly until we call stop.
    let line = makeAssistantLine(
        timestamp: "2026-04-30T12:00:00.000Z",
        messageId: "x", requestId: "x"
    )
    let root = try makeFixtureRoot(withLines: [line])
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])

    // Stub keychain (good token) + transport that returns a known
    // 200 response. Each fetch produces 2 RateLimitSamples.
    let blob = try JSONSerialization.data(withJSONObject: [
        "claudeAiOauth": [
            "accessToken": "stub",
            "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
        ]
    ])
    let kc = KeychainOAuth(rawReader: { .success(blob) })
    let body = #"{"five_hour":{"utilization":11,"resets_at":"2026-05-06T17:00:00Z"},"seven_day":{"utilization":22,"resets_at":"2026-05-13T00:00:00Z"}}"#
    let transport: OAuthClient.Transport = { _ in
        let response = HTTPURLResponse(
            url: OAuthClient.endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (Data(body.utf8), response)
    }
    let client = OAuthClient(keychain: kc, transport: transport)

    let container = try makeInMemoryContainer()
    let coordinator = ScanCoordinator(
        container: container,
        configuration: .init(
            costMode: .display,
            watcherMode: .manual,
            probeStatsCache: false,
            // Tight timing so the poller fires at least once before
            // stop() — but no real sleep because the loop's first
            // cycle runs immediately.
            oauthPolling: .init(baseInterval: 60, jitterSeconds: 0)
        ),
        resolver: resolver,
        oauthClient: client
    )

    let runTask = Task { try await coordinator.runForever() }
    // Yield enough times for the poller's first cycle to complete.
    // The cycle is fully synchronous in test mode (stubbed transport,
    // immediate persistence hop) so a few yields suffice.
    for _ in 0..<10 { await Task.yield() }
    // Give the main-actor persist hop a moment to flush.
    try await Task.sleep(nanoseconds: 50_000_000)

    await coordinator.stop()
    try await runTask.value

    let context = ModelContext(container)
    let count = try context.fetchCount(FetchDescriptor<RateLimitSample>())
    #expect(count >= 2, "expected the poller to insert at least one snapshot's worth of rows")
}

@MainActor
@Test func coordinatorAliasMigrationMovesSamplesAndAggregates() async throws {
    // End-to-end: persist samples under /old/path, add an alias
    // /old/path → /new/path, run another cycle, verify samples and
    // the ProjectDailyAggregate row both live under the new key.
    let line = makeAssistantLine(
        timestamp: "2026-04-30T12:00:00.000Z",
        inputTokens: 100, outputTokens: 50,
        storedCost: 0.10,
        messageId: "msg-rename", requestId: "req-rename",
        cwd: "/Users/test/old-name",
        sessionId: "sess-rename"
    )
    let root = try makeFixtureRoot(withLines: [line])
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])

    let container = try makeInMemoryContainer()
    let coordinator = ScanCoordinator(
        container: container,
        configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
        resolver: resolver
    )

    // First scan: ingest with the original cwd.
    _ = try await coordinator.runOnce()
    let context = ModelContext(container)

    let samplesBefore = try context.fetch(FetchDescriptor<TokenSample>())
    #expect(samplesBefore.count == 1)
    #expect(samplesBefore[0].projectPath == "/Users/test/old-name")

    let projAggsBefore = try context.fetch(FetchDescriptor<ProjectDailyAggregate>())
    #expect(projAggsBefore.count == 1)
    #expect(projAggsBefore[0].projectPath == "/Users/test/old-name")

    // User adds an alias via the manager.
    let manager = ProjectPathAliasManager(context: context)
    try manager.upsert(
        sourcePath: "/Users/test/old-name",
        canonicalPath: "/Users/test/new-name"
    )

    // Next scan picks up the alias fingerprint change and migrates.
    _ = try await coordinator.runOnce()

    let samplesAfter = try ModelContext(container).fetch(FetchDescriptor<TokenSample>())
    #expect(samplesAfter.count == 1)
    #expect(samplesAfter[0].projectPath == "/Users/test/new-name")

    // ProjectDailyAggregate should now be keyed under the new path —
    // the old bucket emptied + recomputer deleted it.
    let projAggsAfter = try ModelContext(container).fetch(FetchDescriptor<ProjectDailyAggregate>())
    #expect(projAggsAfter.count == 1)
    #expect(projAggsAfter[0].projectPath == "/Users/test/new-name")

    // SessionInfo also follows the rename.
    let sessions = try ModelContext(container).fetch(FetchDescriptor<SessionInfo>())
    #expect(sessions.count == 1)
    #expect(sessions[0].projectPath == "/Users/test/new-name")

    // Idempotent: a third scan with no further alias changes is a no-op
    // for path migration — same samples, no double-move.
    let thirdReport = try await coordinator.runOnce()
    #expect(thirdReport.wasFullScan == false)
    let samplesFinal = try ModelContext(container).fetch(FetchDescriptor<TokenSample>())
    #expect(samplesFinal.count == 1)
    #expect(samplesFinal[0].projectPath == "/Users/test/new-name")
}

@MainActor
@Test func coordinatorWithoutOAuthClientDoesNotPoll() async throws {
    // Without an oauthClient the poller is never constructed — verify
    // by running a simple manual cycle and checking no
    // RateLimitSamples appear.
    let line = makeAssistantLine(
        timestamp: "2026-04-30T12:00:00.000Z",
        messageId: "y", requestId: "y"
    )
    let root = try makeFixtureRoot(withLines: [line])
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])

    let container = try makeInMemoryContainer()
    let coordinator = ScanCoordinator(
        container: container,
        configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
        resolver: resolver
        // no oauthClient → no polling
    )
    _ = try await coordinator.runOnce()

    let context = ModelContext(container)
    let count = try context.fetchCount(FetchDescriptor<RateLimitSample>())
    #expect(count == 0)
}
