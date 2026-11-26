import Foundation
import SwiftData
import Testing
@testable import PacerCore

// `ScanCoordinator.stop()` waits for the pass in flight (#475). It used to
// return with a cycle still running, and that cycle saved after the quit had
// replied, by when a second Pacer could have the store open. These hold a
// cycle part-way (`beforeRecomputeHook`, after the scan, before the rollups and
// the terminal save), stop the coordinator, and watch every save made on the
// coordinator's container.

private func makeFixtureRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-stop-drain-\(UUID().uuidString)")
    let projectsDir = root.appendingPathComponent("projects/-Users-test-alpha")
    try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    let lines = [
        assistantLine(at: "2026-04-30T12:00:00.000Z", input: 100, output: 50, id: "1"),
        assistantLine(at: "2026-04-30T12:05:00.000Z", input: 200, output: 80, id: "2"),
    ]
    try (lines.joined(separator: "\n") + "\n").write(
        to: projectsDir.appendingPathComponent("sess-stop.jsonl"), atomically: true, encoding: .utf8)
    return root
}

private func assistantLine(at timestamp: String, input: Int, output: Int, id: String) -> String {
    let fields: [String: Any] = [
        "type": "assistant",
        "timestamp": timestamp,
        "costUSD": 0.1,
        "requestId": "req-\(id)",
        "cwd": "/Users/test/alpha",
        "sessionId": "sess-stop",
        "message": [
            "model": "claude-opus-4-7",
            "id": "msg-\(id)",
            "stop_reason": "end_turn",
            "usage": [
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_input_tokens": 0,
                "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0],
            ],
        ] as [String: Any],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
}

@ScanActor
private func makeCoordinator(container: ModelContainer, root: URL) -> ScanCoordinator {
    ScanCoordinator(
        container: container,
        configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
        resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]))
}

/// Holds the cycle at the hook until the test lets it go.
@ScanActor
private final class Latch {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var reached = false

    func wait() async {
        reached = true
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

/// Every save of a context on one container, and how many came after a mark.
private final class SaveLog: @unchecked Sendable {
    private let lock = NSLock()
    private var saves = 0
    private var savesAfterMark = 0
    private var marked = false
    private var observer: NSObjectProtocol?

    init(container: ModelContainer) {
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { [weak self] note in
            // Other tests save too, in parallel: count only this container's.
            guard let context = note.object as? ModelContext, context.container === container else { return }
            self?.record()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func record() {
        lock.withLock {
            saves += 1
            if marked { savesAfterMark += 1 }
        }
    }

    func mark() { lock.withLock { marked = true } }
    var total: Int { lock.withLock { saves } }
    var afterMark: Int { lock.withLock { savesAfterMark } }
}

@ScanActor
private func waitUntil(_ condition: @ScanActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(120)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

@Suite("Scan stop drains the pass in flight", .serialized)
struct ScanStopDrainTests {

    @ScanActor
    @Test func aCycleInFlightFinishesBeforeStopReturnsAndNothingSavesAfter() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try PacerStore.makeInMemoryContainer()
        let coordinator = makeCoordinator(container: container, root: root)
        // Far past anything a loaded test run takes, so only the cycle can end
        // the wait.
        coordinator.stopDrainBoundForTesting = .seconds(600)
        let latch = Latch()
        coordinator.beforeRecomputeHook = { await latch.wait() }
        let saves = SaveLog(container: container)

        let cycle = Task { @ScanActor in try await coordinator.runOnce() }
        await waitUntil { latch.reached }
        #expect(latch.reached, "the cycle reached the hook")

        var stopReturned = false
        let stop = Task { @ScanActor in
            let drained = await coordinator.stop()
            stopReturned = true
            saves.mark()
            return drained
        }
        // The cycle is held part-way, with its rollups and cursors not yet
        // committed: stop must still be waiting for it.
        try await Task.sleep(for: .milliseconds(200))
        #expect(!stopReturned, "stop returned with the cycle still to save")

        latch.open()
        let drained = await stop.value
        #expect(drained)
        _ = try await cycle.value

        // The held cycle's work landed before stop returned.
        let context = ModelContext(container)
        let daily = try context.fetch(FetchDescriptor<DailyAggregate>())
        #expect(daily.reduce(0) { $0 + $1.inputTokens } == 300)
        #expect(try context.fetchCount(FetchDescriptor<JSONLFileCursor>()) == 1)
        let savedBeforeStopReturned = saves.total
        #expect(savedBeforeStopReturned > 0)

        // Any pass asked for after the stop does nothing, and saves nothing.
        await #expect(throws: ScanCoordinator.ScanStopped.self) { try await coordinator.runOnce() }
        await #expect(throws: ScanCoordinator.ScanStopped.self) { try await coordinator.runAliasMigrationOnly() }
        await coordinator.followLoginChange(.config)
        try await Task.sleep(for: .milliseconds(100))
        #expect(saves.afterMark == 0, "\(saves.afterMark) save(s) after stop returned")
    }

    @ScanActor
    @Test func withNothingInFlightStopReturnsAtOnce() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try PacerStore.makeInMemoryContainer()
        let coordinator = makeCoordinator(container: container, root: root)
        _ = try await coordinator.runOnce()
        // A wait for a pass would run to this bound: nothing near it means
        // there was none.
        coordinator.stopDrainBoundForTesting = .seconds(600)
        let started = ContinuousClock.now
        #expect(await coordinator.stop())
        #expect(ContinuousClock.now - started < .seconds(60))
    }

    /// Past the bound a quit stops waiting: the cycle is left to the process
    /// ending under it (`QuitExitGuard`), and stop says it did not drain.
    @ScanActor
    @Test func stopGivesUpAtItsBound() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try PacerStore.makeInMemoryContainer()
        let coordinator = makeCoordinator(container: container, root: root)
        coordinator.stopDrainBoundForTesting = .milliseconds(150)
        let latch = Latch()
        coordinator.beforeRecomputeHook = { await latch.wait() }

        let cycle = Task { @ScanActor in try await coordinator.runOnce() }
        await waitUntil { latch.reached }
        let started = ContinuousClock.now
        let drained = await coordinator.stop()
        #expect(!drained)
        #expect(ContinuousClock.now - started < .seconds(60))
        latch.open()
        _ = try? await cycle.value
    }
}
