import Testing
import Foundation
@testable import PacerCore

@MainActor
struct RenderReadinessTests {
    @Test func idleWhenNothingPending() async {
        let t = RenderReadinessTracker(isEnabled: true)
        #expect(await t.waitUntilIdle(timeout: .seconds(5), quiet: .milliseconds(20)) == .idle)
    }

    @Test func waitsForPendingLoadThenReturnsIdle() async {
        let t = RenderReadinessTracker(isEnabled: true)
        let token = t.begin("history.projects")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            t.end(token)
        }
        let started = ContinuousClock.now
        #expect(await t.waitUntilIdle(timeout: .seconds(10), quiet: .milliseconds(20)) == .idle)
        #expect(ContinuousClock.now - started >= .milliseconds(140))
        #expect(t.pendingLabels.isEmpty)
    }

    @Test func aLoadStartedDuringTheQuietWindowIsWaitedFor() async {
        let t = RenderReadinessTracker(isEnabled: true)
        let first = t.begin("a")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            t.end(first)
            try? await Task.sleep(for: .milliseconds(30))
            let second = t.begin("b")
            try? await Task.sleep(for: .milliseconds(150))
            t.end(second)
        }
        #expect(await t.waitUntilIdle(timeout: .seconds(10), quiet: .milliseconds(150)) == .idle)
        #expect(t.pendingLabels.isEmpty)
    }

    @Test func timeoutNamesThePendingLoads() async {
        let t = RenderReadinessTracker(isEnabled: true)
        _ = t.begin("history.projects")
        _ = t.begin("pace.series")
        let outcome = await t.waitUntilIdle(timeout: .milliseconds(120), quiet: .milliseconds(20))
        #expect(outcome == .timedOut(pending: ["history.projects", "pace.series"]))
    }
}
