import Foundation
import Testing
@testable import PacerCore

/// Tests use `.manual` mode so we don't depend on the real
/// FSEventStream / 60s timer cadence. The live path is exercised
/// implicitly via the M3.5 ScanCoordinator integration test against
/// the user's real ~/.claude/projects/ tree.

/// The trigger is yielded *before* anything iterates, on purpose.
///
/// `triggers()` builds its stream with `.bufferingNewest(1)`, so a yield with
/// no reader waiting is held rather than dropped — which means this test needs
/// no second task, no delay, and no timeout. It is a plain sequence of awaits.
///
/// It used to race the trigger against a five-second `Task.sleep` and assert
/// that the trigger won. That is a wall clock, and a wall clock measures the
/// CI runner rather than the watcher: the sleeping task needs no thread until
/// it fires, while the task consuming the stream needs one immediately, so
/// under a loaded pool the timeout wins a race the watcher never lost. It
/// failed twice in a row on `main` that way, each run taking 46 seconds to
/// decide, while passing locally in 53 ms — a red build that said nothing
/// about the code under test.
///
/// The time limit is only so a genuine regression fails instead of hanging
/// forever on an iterator nobody will ever feed.
@Test(.timeLimit(.minutes(1)))
func manualTriggerEmitsOnStream() async throws {
    let watcher = JSONLWatcher(mode: .manual)
    let stream = await watcher.triggers()
    await watcher.start(roots: [])

    await watcher.manualTrigger()

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() != nil)
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
