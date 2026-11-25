import Testing
import Foundation
@testable import PacerCore

/// Nonisolated on purpose: the tracker has no actor, so nothing here depends on
/// the main actor's schedule (parallel @MainActor suites starved it in CI).
struct RenderReadinessTests {
    @Test func idleWhenNothingPending() async {
        let t = RenderReadinessTracker(isEnabled: true)
        #expect(await t.waitUntilIdle(timeout: .seconds(30), quiet: .milliseconds(20)) == .idle)
    }

    @Test func waitsForPendingLoadThenReturnsIdle() async {
        let t = RenderReadinessTracker(isEnabled: true)
        let ended = Mutex2(false)
        let token = t.begin("history.projects")
        Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            ended.set(true)
            t.end(token)
        }
        #expect(await t.waitUntilIdle(timeout: .seconds(60), quiet: .milliseconds(20)) == .idle)
        #expect(ended.get())
    }

    /// "b" begins 300 ms after "a" ends: long enough that a waiter polling
    /// every 10 ms sees the idle gap (so a wait without a quiet window would
    /// return early), and far inside the 10 s quiet window, so only a sleep
    /// overrunning by more than 9 s could make "b" miss it. (An earlier version
    /// used a 2 s window and failed under a full parallel run.) The waiter
    /// records whether "b" had ended when it returned.
    @Test func aLoadStartedDuringTheQuietWindowIsWaitedFor() async {
        let t = RenderReadinessTracker(isEnabled: true)
        let secondEnded = Mutex2(false)
        let first = t.begin("a")
        let waiter = Task.detached {
            let outcome = await t.waitUntilIdle(timeout: .seconds(300), quiet: .seconds(10), poll: .milliseconds(10))
            return (outcome, secondEnded.get())
        }
        try? await Task.sleep(for: .milliseconds(100))   // let the waiter start polling
        t.end(first)
        try? await Task.sleep(for: .milliseconds(300))   // the idle gap a poll sees
        let second = t.begin("b")
        try? await Task.sleep(for: .milliseconds(500))
        secondEnded.set(true)
        t.end(second)
        let (outcome, sawSecondEnd) = await waiter.value
        #expect(outcome == .idle)
        #expect(sawSecondEnd, "the wait returned while the load that began in its quiet window was still pending")
    }

    @Test func timeoutNamesThePendingLoads() async {
        let t = RenderReadinessTracker(isEnabled: true)
        _ = t.begin("history.projects")
        _ = t.begin("pace.series")
        let outcome = await t.waitUntilIdle(timeout: .milliseconds(120), quiet: .milliseconds(20))
        #expect(outcome == .timedOut(pending: ["history.projects", "pace.series"]))
    }

    @Test(arguments: [true, false])
    func taskNeverTouchesTheMainThread(enabled: Bool) async {
        let t = RenderReadinessTracker(isEnabled: enabled)
        // Called from a nonisolated context, as `askEngine` does.
        let callerOnMain = Task.detached { onMainThread() }
        #expect(await callerOnMain.value == false)
        let ranOnMain = await Task.detached { () -> Bool in
            let load = t.task("probe") { onMainThread() }
            return await load.value
        }.value
        #expect(ranOnMain == false)
        #expect(t.pendingLabels.isEmpty)
    }

    @Test func enabledTaskIsPendingUntilItFinishes() async {
        let t = RenderReadinessTracker(isEnabled: true)
        let gate = AsyncGate()
        let load = t.task("slow") { await gate.wait(); return 7 }
        #expect(t.pendingLabels == ["slow"])
        gate.open()
        #expect(await load.value == 7)
        #expect(t.pendingLabels.isEmpty)
    }
}

private func onMainThread() -> Bool { Thread.isMainThread }

private final class Mutex2: @unchecked Sendable {
    private let lock = NSLock(); private var value: Bool
    init(_ v: Bool) { value = v }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock(); private var opened = false
    func open() { lock.lock(); opened = true; lock.unlock() }
    func isOpen() -> Bool { lock.lock(); defer { lock.unlock() }; return opened }
    func wait() async {
        while true {
            if isOpen() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
