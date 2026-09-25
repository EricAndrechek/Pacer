import Foundation
import SwiftData
import Testing
@testable import PacerCore

// A scan cycle marks the rollup buckets it has to rebuild, then rebuilds them.
// Anything that loses those marks in between leaves a rollup wrong for good:
// nothing revisits a bucket that no longer looks dirty. These tests cover the
// two ways that happened (#144) — a project merge landing while a cycle was
// suspended, and a cycle that failed part-way.

private func makeFixtureRoot(withLines lines: [String]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-marks-\(UUID().uuidString)")
    let projectsDir = root.appendingPathComponent("projects/-Users-test-alpha")
    try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    let body = lines.joined(separator: "\n") + "\n"
    try body.write(to: projectsDir.appendingPathComponent("sess-marks.jsonl"),
                   atomically: true, encoding: .utf8)
    return root
}

private func assistantLine(
    at timestamp: String, input: Int, output: Int, cost: Double, id: String
) -> String {
    let fields: [String: Any] = [
        "type": "assistant",
        "timestamp": timestamp,
        "costUSD": cost,
        "requestId": "req-\(id)",
        "cwd": "/Users/test/alpha",
        "sessionId": "sess-marks",
        "message": [
            "model": "claude-opus-4-7",
            "id": "msg-\(id)",
            "usage": [
                "input_tokens": input,
                "output_tokens": output,
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

/// Two turns, 300 input / 130 output tokens between them, in one project and
/// one session — so every rollup has exactly one bucket to get right.
private let twoTurns = [
    assistantLine(at: "2026-04-30T12:00:00.000Z", input: 100, output: 50, cost: 0.10, id: "1"),
    assistantLine(at: "2026-04-30T12:05:00.000Z", input: 200, output: 80, cost: 0.20, id: "2"),
]

@ScanActor
private func makeCoordinator(
    container: ModelContainer, root: URL
) -> ScanCoordinator {
    ScanCoordinator(
        container: container,
        configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
        resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])
    )
}

/// Every rollup the fixture feeds, read from the store — i.e. only what was
/// actually saved.
@ScanActor
private func expectRollups(in container: ModelContainer, projectPath: String) throws {
    let context = ModelContext(container)

    let daily = try context.fetch(FetchDescriptor<DailyAggregate>())
    #expect(daily.count == 1)
    #expect(daily.first?.inputTokens == 300)
    #expect(daily.first?.outputTokens == 130)
    #expect(abs((daily.first?.totalCostUSD ?? 0) - 0.30) < 1e-9)

    let hourly = try context.fetch(FetchDescriptor<HourlyAggregate>())
    #expect(hourly.reduce(0) { $0 + $1.inputTokens } == 300)
    #expect(hourly.reduce(0) { $0 + $1.sampleCount } == 2)

    let projects = try context.fetch(FetchDescriptor<ProjectDailyAggregate>())
    #expect(projects.map(\.projectPath) == [projectPath])
    #expect(projects.first?.inputTokens == 300)
    #expect(projects.first?.outputTokens == 130)

    let sessions = try context.fetch(FetchDescriptor<SessionInfo>())
    #expect(sessions.map(\.projectPath) == [projectPath])
}

private struct InjectedFailure: Error {}

/// Holds the cycle at `beforeRecomputeHook` until the test lets it go.
@ScanActor
private final class Latch {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

@ScanActor
private final class Flag {
    var isSet = false
}

@ScanActor
@Test func failedCycleMarksAreRebuiltByTheNextCycle() async throws {
    let root = try makeFixtureRoot(withLines: twoTurns)
    defer { try? FileManager.default.removeItem(at: root) }
    let container = try PacerStore.makeInMemoryContainer()
    let coordinator = makeCoordinator(container: container, root: root)

    // The turns are inserted and their buckets marked; then the cycle dies
    // before rebuilding anything. The samples stay in the scan context and the
    // dedup set, so no later scan re-reads them — the marks are all that
    // connects them to the rollups.
    coordinator.beforeRecomputeHook = { throw InjectedFailure() }
    do {
        _ = try await coordinator.runOnce()
        Issue.record("the injected failure should have ended the cycle")
    } catch is InjectedFailure {}

    // A clean cycle with nothing new to read.
    coordinator.beforeRecomputeHook = nil
    _ = try await coordinator.runOnce()

    try expectRollups(in: container, projectPath: "/Users/test/alpha")
}

@ScanActor
@Test func projectMergeWaitsForTheCycleInFlight() async throws {
    let root = try makeFixtureRoot(withLines: twoTurns)
    defer { try? FileManager.default.removeItem(at: root) }
    let container = try PacerStore.makeInMemoryContainer()
    let coordinator = makeCoordinator(container: container, root: root)

    let (reached, reachedSignal) = AsyncStream.makeStream(of: Void.self)
    let latch = Latch()
    coordinator.beforeRecomputeHook = {
        reachedSignal.yield()
        await latch.wait()
    }
    let cycle = Task { @ScanActor in try await coordinator.runOnce() }
    for await _ in reached { break }

    // The user merges the project while the cycle is suspended with its
    // buckets marked but not yet rebuilt.
    try ProjectPathAliasManager(context: ModelContext(container)).upsert(
        sourcePath: "/Users/test/alpha", canonicalPath: "/Users/test/beta")
    let mergeFinished = Flag()
    let merge = Task { @ScanActor in
        let report = try await coordinator.runAliasMigrationOnly()
        mergeFinished.isSet = true
        return report
    }

    // Ample time for a merge that doesn't wait to run to completion, which is
    // what the bug needed: it cleared the cycle's marks on its way through.
    try await Task.sleep(for: .milliseconds(200))
    #expect(!mergeFinished.isSet, "the merge must wait for the cycle that holds the marks")

    latch.open()
    _ = try await cycle.value
    let report = try await merge.value
    #expect(report.aliasesChanged)

    // The cycle's rebuild survived, and the merge then moved the project.
    try expectRollups(in: container, projectPath: "/Users/test/beta")
    let paths = try ModelContext(container).fetch(FetchDescriptor<TokenSample>()).map(\.projectPath)
    #expect(paths == ["/Users/test/beta", "/Users/test/beta"])
}

@ScanActor
@Test func unfinishedMarksCarryOverAsPolluted() throws {
    let container = try PacerStore.makeInMemoryContainer()
    let persister = try SamplePersister(context: ModelContext(container))
    try persister.ensurePreloaded()
    let entry = ParsedUsageEntry(
        timestamp: Date(timeIntervalSince1970: 1_756_800_000),
        model: "claude-opus-4-7",
        breakdown: TokenBreakdown(
            inputTokens: 100, outputTokens: 200, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0),
        storedCostUSD: nil,
        dedupKey: "msg:req",
        sessionId: "sess",
        projectPath: "/Users/test/alpha",
        claudeCodeVersion: nil,
        isApiErrorMessage: false
    )
    #expect(try persister.insert(entry))
    #expect(!persister.pendingPairSamples.isEmpty)

    // Nothing committed these marks, so a pass that finds them must rebuild
    // the buckets from their samples — the dead pass may already have added
    // the pending samples to a rollup row, and adding them again would count
    // them twice.
    #expect(persister.carryOverUnfinishedMarks() == 4)
    #expect(persister.dirtyPairs.isSubset(of: persister.pollutedDailyPairs))
    #expect(persister.dirtyHourBuckets.isSubset(of: persister.pollutedHourBuckets))
    #expect(persister.dirtyProjectDates.isSubset(of: persister.pollutedProjectPairs))
    #expect(persister.dirtySessionIds.isSubset(of: persister.pollutedSessionIds))
    #expect(persister.pendingPairSamples.isEmpty)
    #expect(persister.pendingHourSamples.isEmpty)
    #expect(persister.pendingProjectSamples.isEmpty)
    #expect(persister.pendingSessionSamples.isEmpty)

    // Committed marks are cleared, and there is nothing left to carry.
    persister.clearDirtyPairs()
    #expect(persister.carryOverUnfinishedMarks() == 0)
}
