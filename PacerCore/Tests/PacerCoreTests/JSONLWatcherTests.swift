import Foundation
import Testing
@testable import PacerCore

/// Tests use `.manual` mode so we don't depend on the real
/// FSEventStream / 60s timer cadence. The live path is exercised
/// implicitly via the M3.5 ScanCoordinator integration test against
/// the user's real ~/.claude/projects/ tree.

@Test func manualTriggerEmitsOnStream() async throws {
    let watcher = JSONLWatcher(mode: .manual)
    let stream = await watcher.triggers()
    await watcher.start(roots: [])

    Task {
        // Small delay to make sure the iterator is parked before we yield.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await watcher.manualTrigger()
    }

    // Race the trigger against a 1s safety timeout so a miss fails
    // loudly rather than hanging the suite.
    let received = await withTaskGroup(of: Date?.self) { group in
        group.addTask {
            for await date in stream {
                return date
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
    #expect(received != nil)
    await watcher.stop()
}

@Test func stopFinishesStream() async throws {
    let watcher = JSONLWatcher(mode: .manual)
    let stream = await watcher.triggers()
    await watcher.start(roots: [])

    Task {
        try? await Task.sleep(nanoseconds: 100_000_000)
        await watcher.stop()
    }

    var received = 0
    for await _ in stream {
        received += 1
    }
    // After stop, the for-await loop terminates. Zero events is fine
    // — the test asserts the loop returns at all (no hang).
    #expect(received >= 0)
}

@Test func liveModeStartIsNoOpWithEmptyRoots() async {
    // Sanity: starting live mode with no paths must not crash. Comes up
    // when ClaudePathResolver returns nothing (e.g. fresh install with
    // no Claude Code config yet) and the daemon decides to start anyway.
    let watcher = JSONLWatcher(mode: .live(latencySeconds: 0.1, backstopInterval: 60))
    _ = await watcher.triggers()
    await watcher.start(roots: [])
    await watcher.stop()
}
