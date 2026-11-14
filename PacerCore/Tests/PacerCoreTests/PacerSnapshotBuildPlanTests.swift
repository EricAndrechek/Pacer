import Foundation
import Testing
@testable import PacerCore

@Suite("Snapshot build plan")
struct PacerSnapshotBuildPlanTests {
    typealias Plan = PacerSnapshotBuildPlan
    /// Awake seconds.
    private let t0: TimeInterval = 5_000

    /// Runs the build a step scheduled, from `start` for `duration`, and
    /// returns what the plan does next.
    private func build(_ plan: inout Plan, _ step: Plan.Step, start: TimeInterval,
                       duration: TimeInterval) -> (urgent: Bool?, next: Plan.Step) {
        guard case let .schedule(token, _, _) = step else {
            Issue.record("expected a scheduled build, got \(step)")
            return (nil, .none)
        }
        let urgent = plan.begin(token: token)
        let next = plan.finish(startedAt: start, endedAt: start + duration,
                               now: start + duration, proceed: true)
        return (urgent, next)
    }

    @Test func firstRequestBuildsAtOnce() {
        var plan = Plan()
        #expect(plan.request(urgent: false, now: t0) == .schedule(token: 1, delay: 0, replacing: nil))
        #expect(plan.scheduled == 1)
    }

    @Test func requestsDuringARestAreFoldedIntoTheScheduledBuild() {
        var plan = Plan()
        let first = plan.request(urgent: false, now: t0)
        let after = build(&plan, first, start: t0, duration: 10).next
        #expect(after == .none)
        // A 10 s build rests 30 s: the next one is scheduled behind it.
        let scheduled = plan.request(urgent: false, now: t0 + 10)
        #expect(scheduled == .schedule(token: 2, delay: 30, replacing: nil))
        #expect(plan.request(urgent: false, now: t0 + 15) == .none)
        #expect(plan.request(urgent: false, now: t0 + 20) == .none)
        #expect(plan.begin(token: 2) == false)
    }

    /// The finding: an urgent request during a rest used to wait it out.
    @Test func anUrgentRequestReplacesTheScheduledBuild() {
        var plan = Plan()
        let first = plan.request(urgent: false, now: t0)
        _ = build(&plan, first, start: t0, duration: 20)
        let waiting = plan.request(urgent: false, now: t0 + 20)
        #expect(waiting == .schedule(token: 2, delay: PacerSnapshotSpacing.maximumRest, replacing: nil))

        let urgent = plan.request(urgent: true, now: t0 + 25)
        #expect(urgent == .schedule(token: 3, delay: 0, replacing: 2))
        // The replaced timer, if its cancel came too late, builds nothing.
        #expect(plan.begin(token: 2) == nil)
        #expect(plan.begin(token: 3) == true)
        #expect(plan.isBuilding)
    }

    @Test func anUrgentRequestDuringABuildFollowsItAtOnce() {
        var plan = Plan()
        guard case let .schedule(token, _, _) = plan.request(urgent: false, now: t0) else {
            Issue.record("no build scheduled")
            return
        }
        #expect(plan.begin(token: token) == false)
        // Never two at once: running, so the request waits for the end.
        #expect(plan.request(urgent: true, now: t0 + 1) == .none)
        #expect(plan.request(urgent: false, now: t0 + 2) == .none)
        let next = plan.finish(startedAt: t0, endedAt: t0 + 15, now: t0 + 15, proceed: true)
        // A 15 s build would rest 45 s; the urgent request skips it.
        #expect(next == .schedule(token: 2, delay: 0, replacing: nil))
        #expect(plan.begin(token: 2) == true)
    }

    @Test func aNormalRequestDuringABuildFollowsItAfterTheRest() {
        var plan = Plan()
        guard case let .schedule(token, _, _) = plan.request(urgent: false, now: t0) else {
            Issue.record("no build scheduled")
            return
        }
        _ = plan.begin(token: token)
        #expect(plan.request(urgent: false, now: t0 + 1) == .none)
        let next = plan.finish(startedAt: t0, endedAt: t0 + 4, now: t0 + 4, proceed: true)
        #expect(next == .schedule(token: 2, delay: 12, replacing: nil))
    }

    @Test func nothingFollowsABuildNobodyAskedAfter() {
        var plan = Plan()
        let first = plan.request(urgent: false, now: t0)
        let next = build(&plan, first, start: t0, duration: 1).next
        #expect(next == .none)
        #expect(!plan.isBuilding)
        #expect(plan.scheduled == nil)
    }

    @Test func resetDropsTheScheduledBuildAndEveryRequest() {
        var plan = Plan()
        let first = plan.request(urgent: false, now: t0)
        _ = build(&plan, first, start: t0, duration: 10)
        _ = plan.request(urgent: true, now: t0 + 10)
        let dropped = plan.scheduled
        #expect(plan.reset() == dropped)
        #expect(plan.begin(token: dropped ?? 0) == nil)
        #expect(!plan.pending && !plan.pendingUrgent)
        // The spacing starts over: the next first build is immediate.
        #expect(plan.request(urgent: false, now: t0 + 11) == .schedule(token: 3, delay: 0, replacing: nil))
    }

    @Test func aBuildRunningThroughAStopSchedulesNothing() {
        var plan = Plan()
        guard case let .schedule(token, _, _) = plan.request(urgent: false, now: t0) else {
            Issue.record("no build scheduled")
            return
        }
        _ = plan.begin(token: token)
        _ = plan.request(urgent: false, now: t0 + 1)
        #expect(plan.reset() == nil)
        #expect(plan.finish(startedAt: t0, endedAt: t0 + 3, now: t0 + 3, proceed: false) == .none)
        #expect(!plan.isBuilding && !plan.pending)
    }

    /// Stop then start while a build still runs: the start's request waits
    /// for that build, which then schedules it.
    @Test func aRestartDuringABuildIsServedWhenItEnds() {
        var plan = Plan()
        guard case let .schedule(token, _, _) = plan.request(urgent: false, now: t0) else {
            Issue.record("no build scheduled")
            return
        }
        _ = plan.begin(token: token)
        _ = plan.reset()
        #expect(plan.request(urgent: false, now: t0 + 1) == .none)
        let next = plan.finish(startedAt: t0, endedAt: t0 + 2, now: t0 + 2, proceed: true)
        #expect(next == .schedule(token: 2, delay: 6, replacing: nil))
    }
}
