import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// While an upgrade's long first cycle runs (#328): usage readings keep
/// coming, the rebuild says what it is doing, and starting the watcher first
/// doesn't cost the startup cycle its catch-up walk.
@Suite struct UpgradeReadingsTests {

    /// State a hook writes and the test reads; both on the scan actor.
    @ScanActor final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func root(files: [String: [String]]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-upgrade-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("projects/-tmp-upgrade")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, lines) in files {
            try (lines.joined(separator: "\n") + "\n").write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func line(_ id: String, at timestamp: String) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","requestId":"r-\(id)","sessionId":"s-\(id)",\
        "cwd":"/tmp/upgrade","message":{"id":"m-\(id)","model":"claude-opus-4-7","stop_reason":"end_turn",\
        "usage":{"input_tokens":10,"output_tokens":20}}}
        """
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((text + "\n").utf8))
    }

    private func stubClient() throws -> OAuthClient {
        let blob = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "stub",
                "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
            ],
        ])
        let body = #"{"five_hour":{"utilization":11,"resets_at":"2026-05-06T17:00:00Z"},"seven_day":{"utilization":22,"resets_at":"2026-05-13T00:00:00Z"}}"#
        return OAuthClient(keychain: KeychainOAuth(rawReader: { .success(blob) }), transport: { _ in
            (Data(body.utf8), HTTPURLResponse(url: OAuthClient.endpoint, statusCode: 200,
                                              httpVersion: "HTTP/1.1", headerFields: [:])!)
        })
    }

    @MainActor
    private func step(of coordinator: ScanCoordinator) -> HistoryRebuildStatus.Step? {
        HistoryRebuildStatus.shared.step(for: coordinator.rebuildStatusSource)
    }

    /// Before #328 the poller started after the first cycle, so an upgrade's
    /// minutes-long cycle was a gap in every rate-limit series. Held open
    /// before its rollups, the first cycle must already see readings.
    @ScanActor
    @Test func theOAuthPollerReadsWhileTheFirstCycleRuns() async throws {
        let r = try root(files: ["a.jsonl": [line("1", at: "2026-04-30T12:00:00.000Z")]])
        defer { try? FileManager.default.removeItem(at: r) }
        let container = try PacerStore.makeInMemoryContainer()
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": r.path]),
            oauthClient: try stubClient())
        let readings = Box(0), cycles = Box(0), released = Box(false)
        coordinator.beforeRecomputeHook = {
            cycles.value += 1
            guard cycles.value == 1 else { return }
            defer { released.value = true }
            // Holds the first cycle open until a reading lands, or gives up.
            _ = await eventually {
                readings.value = (try? ModelContext(container)
                    .fetchCount(FetchDescriptor<RateLimitSample>())) ?? 0
                return readings.value > 0
            }
        }
        let run = Task { try await coordinator.runForever() }
        let reachedHook = await eventually { released.value }
        let stopped = try await stopAndAwait(coordinator, running: run)
        #expect(stopped, "stop() or runForever didn't return")
        #expect(reachedHook, "the first cycle never reached its rollups")
        #expect(readings.value > 0, "no rate-limit reading landed while the first cycle ran")
    }

    /// `stop()` can land anywhere in `runForever`'s startup — the app's quit
    /// can come that early, and with the poller, the watcher and a main-actor
    /// hop now ahead of the first cycle there are more places for it to land.
    /// Wherever it does, `runForever` returns and leaves no poller running. A
    /// stop before `triggers()` used to leave it waiting on a stream nothing
    /// would end, and a poller started after the stop ran on.
    @ScanActor
    @Test func aStopAnywhereInStartupIsHonoured() async throws {
        let r = try root(files: ["a.jsonl": [line("1", at: "2026-04-30T12:00:00.000Z")]])
        defer { try? FileManager.default.removeItem(at: r) }
        func make() throws -> ScanCoordinator {
            ScanCoordinator(
                container: try PacerStore.makeInMemoryContainer(),
                configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
                resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": r.path]),
                oauthClient: try stubClient())
        }

        // Stopped before it ever ran. Nothing is running for this `stop()` to
        // wait on; the question is whether `runForever` then returns by itself.
        let early = try make()
        await early.stop()
        let earlyReturned = Box(false)
        let earlyRun = Task {
            try await early.runForever()
            earlyReturned.value = true
        }
        let returned = await eventually(timeout: .seconds(30)) { earlyReturned.value }
        #expect(returned, "runForever after a stop() waited on a stream nothing would end")
        // Left behind on a failure, so the test fails rather than hangs.
        if returned { try await earlyRun.value }

        // Each pass lets the startup run a few more steps before the stop.
        for yields in 0..<12 {
            let coordinator = try make()
            let run = Task { try await coordinator.runForever() }
            for _ in 0..<yields { await Task.yield() }
            let stopped = try await stopAndAwait(coordinator, running: run, timeout: .seconds(30))
            #expect(stopped, "stop() or runForever didn't return after a stop \(yields) yield(s) in")
            guard stopped else { continue }
            let poller = try #require(coordinator.oauthPollerForTesting)
            #expect(await !poller.isLoopRunningForTesting,
                    "the poller ran on after a stop \(yields) yield(s) in")
        }
    }

    /// A rebuild publishes its steps while it runs and clears them when it
    /// ends — whether it ends well or not. An ordinary cycle publishes none.
    @ScanActor
    @Test func aRebuildSaysSoWhileItRunsAndClearsAfter() async throws {
        let r = try root(files: ["a.jsonl": [line("1", at: "2026-04-30T12:00:00.000Z")]])
        defer { try? FileManager.default.removeItem(at: r) }
        let container = try PacerStore.makeInMemoryContainer()
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": r.path]))

        // A fresh store: the first cycle is a full read, so a rebuild.
        let during = Box<HistoryRebuildStatus.Step?>(nil)
        coordinator.beforeRecomputeHook = { during.value = await self.step(of: coordinator) }
        try await coordinator.runOnce()
        #expect(during.value != nil)
        #expect(await step(of: coordinator) == nil)

        // The next one is incremental: nothing to say.
        during.value = .preparing
        try await coordinator.runOnce()
        #expect(during.value == nil)

        // A rebuild that fails part-way still clears.
        struct Boom: Error {}
        let failing = ScanCoordinator(
            container: try PacerStore.makeInMemoryContainer(),
            configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": r.path]))
        failing.beforeRecomputeHook = {
            during.value = await self.step(of: failing)
            throw Boom()
        }
        await #expect(throws: Boom.self) { try await failing.runOnce() }
        #expect(during.value != nil)
        #expect(await step(of: failing) == nil)
    }

    /// The watcher now starts before the startup cycle, so it may already
    /// have heard a write. That cycle must still walk every file: it is what
    /// catches up on everything written while Pacer wasn't running.
    @ScanActor
    @Test func theStartupCycleWalksEveryFileWhateverTheWatcherHeard() async throws {
        let r = try root(files: [
            "a.jsonl": [line("a1", at: "2026-04-30T12:00:00.000Z")],
            "b.jsonl": [line("b1", at: "2026-04-30T12:01:00.000Z")],
        ])
        defer { try? FileManager.default.removeItem(at: r) }
        let resolver = ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": r.path])
        let container = try PacerStore.makeInMemoryContainer()
        let config = ScanCoordinator.Configuration(
            costMode: .display, watcherMode: .manual, probeStatsCache: false)
        try await ScanCoordinator(container: container, configuration: config, resolver: resolver).runOnce()

        // Written while "Pacer was closed"; the next launch's watcher hears
        // only one of them before its first cycle.
        let dir = r.appendingPathComponent("projects/-tmp-upgrade")
        try append(line("a2", at: "2026-04-30T13:00:00.000Z"), to: dir.appendingPathComponent("a.jsonl"))
        try append(line("b2", at: "2026-04-30T13:01:00.000Z"), to: dir.appendingPathComponent("b.jsonl"))
        let relaunched = ScanCoordinator(container: container, configuration: config, resolver: resolver)
        await relaunched.watcherForTesting.noteChangedPathsForTesting(
            [dir.appendingPathComponent("a.jsonl").path])
        let startupDone = Box(false)
        relaunched.beforeRecomputeHook = { startupDone.value = true }
        let run = Task { try await relaunched.runForever() }
        let reachedHook = await eventually { startupDone.value }
        let stopped = try await stopAndAwait(relaunched, running: run)

        #expect(stopped, "stop() or runForever didn't return")
        #expect(reachedHook, "the startup cycle never reached its rollups")
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TokenSample>()) == 4)
    }
}
