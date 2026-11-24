import Foundation
import Testing
@testable import PacerCore

extension Trait where Self == TimeLimitTrait {
    /// For a suite whose tests wait on background work (the arena's scorer
    /// and live lane, a poller's loop): a test still waiting after this long
    /// is named in the log as over its time limit, rather than the run
    /// sitting silent until somebody kills it (#431). Far past the slowest
    /// pass seen in a full `make test` beside other builders (287 s): it is a
    /// backstop for a hang, not a deadline for slow work.
    static var hangBackstop: Self { .timeLimit(.minutes(20)) }
}

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
/// true, which is the only case a passing test waits for. A minute was not
/// enough: on CI a poller's reading has landed more than 60 s after the test
/// began waiting for it, with the pool saturated throughout.
func eventually(
    timeout: Duration = .seconds(300),
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

/// Polls `condition` until it holds, giving up only once `progress` has
/// stood still for `stall` of wall time, and says which.
///
/// For work of many steps (hours of a poller's loop on a virtual clock),
/// where a fixed deadline measures the machine rather than the code: in a
/// full `make test` beside other builders, the stagger test's loop took 287 s
/// of a 300 s `eventually` and then ran out (#431), every step of it still
/// advancing. What a hang looks like is no step at all, so that is what this
/// waits out.
func eventually<Progress: Equatable>(
    progressing progress: () async -> Progress,
    stall: Duration = .seconds(300),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    var last = await progress()
    var deadline = ContinuousClock.now + stall
    while true {
        if try await condition() { return true }
        let now = await progress()
        if now != last {
            last = now
            deadline = ContinuousClock.now + stall
        } else if ContinuousClock.now >= deadline || Task.isCancelled {
            return false
        }
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
/// fails the test that stopped instead of hanging the run. Five minutes, like
/// `eventually`, against a hang that was ten.
@ScanActor
func stopAndAwait(
    _ coordinator: ScanCoordinator,
    running run: Task<Void, any Error>,
    timeout: Duration = .seconds(300)
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
