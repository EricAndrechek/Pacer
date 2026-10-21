import Foundation
@testable import PacerCore

/// Polls `condition` until it holds or `timeout` of wall time has passed, and
/// says which.
///
/// For a test watching something that runs concurrently — a poller's first
/// reading, a cycle reaching its hook. A count of short sleeps is not a
/// deadline: on a loaded CI runner the cooperative pool is saturated for
/// minutes at a stretch, every sleep comes back far later than asked, and the
/// count bounds neither the time nor the outcome. After each sleep the
/// condition is checked before the deadline is, so a test the pool resumed
/// late still sees what has already happened.
///
/// The timeout is generous because it costs nothing when the condition comes
/// true, which is the only case a passing test waits for.
func eventually(
    timeout: Duration = .seconds(60),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        if try await condition() { return true }
        if ContinuousClock.now >= deadline || Task.isCancelled { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Stops `coordinator`, then waits for its `runForever` task, both within
/// `timeout`, and says whether they finished. Rethrows what `runForever`
/// threw.
///
/// The two waits that hung CI (#328's startup order): a `stop()` that waited
/// out the poller's ten-minute nap, and a `runForever` that never returned
/// after a `stop()` during its startup. Through here, a regression of either
/// fails the test that stopped instead of hanging the run.
@ScanActor
func stopAndAwait(
    _ coordinator: ScanCoordinator,
    running run: Task<Void, any Error>,
    timeout: Duration = .seconds(60)
) async throws -> Bool {
    let finished = Finished()
    let stopping = Task { @ScanActor in
        await coordinator.stop()
        _ = await run.result
        finished.value = true
    }
    // Left behind if it never finishes, so the caller fails rather than hangs.
    guard await eventually(timeout: timeout, { finished.value }) else { return false }
    await stopping.value
    try await run.value
    return true
}

@ScanActor
private final class Finished {
    var value = false
}
