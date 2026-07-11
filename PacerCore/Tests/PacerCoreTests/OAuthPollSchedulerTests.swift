import Foundation
import Testing
@testable import PacerCore

@Suite struct OAuthPollSchedulerTests {

    typealias Lane = OAuthPollScheduler.LaneState
    typealias Decision = OAuthPollScheduler.Decision

    private let sched = OAuthPollScheduler()   // defaults: min300 active150 idle600 window900
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: - First poll

    @Test func neverPolledLanePollsImmediately() {
        let d = sched.decide(lanes: [Lane()], lastActivityAt: nil, now: t0)
        #expect(d == .poll(laneIndex: 0))
    }

    @Test func noUsableLanesWaitsIdle() {
        let d = sched.decide(lanes: [Lane(account: .secondary)], lastActivityAt: at(0), now: t0)
        #expect(d == .wait(seconds: 600))
        let empty = sched.decide(lanes: [], lastActivityAt: nil, now: t0)
        #expect(empty == .wait(seconds: 600))
    }

    // MARK: - Single lane: floors at the per-token invariant

    @Test func singleLaneIdleWaitsIdleInterval() {
        let lanes = [Lane(lastPolledAt: t0, account: .primary)]
        #expect(sched.decide(lanes: lanes, lastActivityAt: nil, now: t0) == .wait(seconds: 600))
    }

    @Test func singleLaneActiveFloorsAtPerTokenMinNotActiveInterval() {
        // One lane can't sustain the 150s active cadence — it must wait
        // the 300s per-token minimum, never 150s.
        let lanes = [Lane(lastPolledAt: t0, account: .primary)]
        #expect(sched.decide(lanes: lanes, lastActivityAt: t0, now: t0) == .wait(seconds: 300))
    }

    // MARK: - Two lanes: interleave to 2.5-min effective, each 5-min

    @Test func twoLanesActiveInterleaveEvery150EachLaneEvery300() {
        // A just polled at t0, B never polled. Active.
        let a0 = Lane(lastPolledAt: t0, account: .primary)
        let b0 = Lane(account: .primary)

        // Not yet due (endpoint cadence 150 from A's poll).
        #expect(sched.decide(lanes: [a0, b0], lastActivityAt: t0, now: t0) == .wait(seconds: 150))

        // At +150: A still within its 300 floor, so poll B.
        #expect(sched.decide(lanes: [a0, b0], lastActivityAt: t0, now: at(150)) == .poll(laneIndex: 1))

        // B polled at +150; A at t0. At +300 A frees; poll A.
        let b150 = Lane(lastPolledAt: at(150), account: .primary)
        #expect(sched.decide(lanes: [a0, b150], lastActivityAt: t0, now: at(150)) == .wait(seconds: 150))
        #expect(sched.decide(lanes: [a0, b150], lastActivityAt: t0, now: at(300)) == .poll(laneIndex: 0))
    }

    @Test func fiveLanesActiveTargetsOneMinute() {
        // 5 usable lanes sustain a 60s endpoint cadence (each lane every
        // 300s). Lane 0 just polled; the target is 300/5 = 60s.
        var lanes = [Lane(lastPolledAt: t0, account: .primary)]
        lanes.append(contentsOf: (0..<4).map { _ in Lane(account: .primary) })
        #expect(sched.decide(lanes: lanes, lastActivityAt: t0, now: t0) == .wait(seconds: 60))
    }

    @Test func moreLanesScaleFasterWithNoFloor() {
        // 10 lanes → 300/10 = 30s, since the default floor is 0.
        var lanes = [Lane(lastPolledAt: t0, account: .primary)]
        lanes.append(contentsOf: (0..<9).map { _ in Lane(account: .primary) })
        #expect(sched.decide(lanes: lanes, lastActivityAt: t0, now: t0) == .wait(seconds: 30))
    }

    @Test func allLanesWithinMinIntervalWaitsUntilEarliestFrees() {
        let a = Lane(lastPolledAt: at(100), account: .primary)   // free at 400
        let b = Lane(lastPolledAt: at(50), account: .primary)    // free at 350
        // Active, endpoint anchor = max(100,50)=100 -> ready at 250, but
        // no lane free until 350 -> wait 200 from now=150.
        #expect(sched.decide(lanes: [a, b], lastActivityAt: t0, now: at(150)) == .wait(seconds: 200))
    }

    // MARK: - Cooldown + foreign exclusion

    @Test func cooldownLaneSkippedInFavorOfEligible() {
        let a = Lane(lastPolledAt: t0, cooldownUntil: at(400), account: .primary) // free at 400
        let b = Lane(account: .primary)                                            // never polled
        #expect(sched.decide(lanes: [a, b], lastActivityAt: t0, now: at(150)) == .poll(laneIndex: 1))
    }

    @Test func secondaryLaneNeverPicked() {
        // A `.secondary` (non-active account) lane is not in the fast pool —
        // the poller sweeps it separately, so the scheduler never picks it.
        let secondary = Lane(lastPolledAt: nil, account: .secondary)
        let primary = Lane(lastPolledAt: nil, account: .primary)
        // Even though secondary is index 0 and never polled, we pick primary.
        #expect(sched.decide(lanes: [secondary, primary], lastActivityAt: t0, now: t0) == .poll(laneIndex: 1))
    }

    @Test func unknownLaneIsEligibleForDiscovery() {
        // An unknown-account lane gets polled (once) so we can learn its org.
        let d = sched.decide(lanes: [Lane(account: .unknown)], lastActivityAt: t0, now: t0)
        #expect(d == .poll(laneIndex: 0))
    }

    // MARK: - Poll-on-wake

    @Test func activityResumingTriggersImmediatePollOncePastPerTokenFloor() {
        // Single lane last polled at t0, idle since. At +300 the per-token
        // floor is met; activity arriving flips target to 150 and it polls.
        let lanes = [Lane(lastPolledAt: t0, account: .primary)]
        // Still idle at +300 would wait (idle cadence 600 not yet met... actually
        // endpoint anchor t0+600 vs lane-free t0+300 -> waits to 600).
        #expect(sched.decide(lanes: lanes, lastActivityAt: nil, now: at(300)) == .wait(seconds: 300))
        // Activity NOW: active target 150, lane free at 300 <= now -> poll.
        #expect(sched.decide(lanes: lanes, lastActivityAt: at(300), now: at(300)) == .poll(laneIndex: 0))
    }

    @Test func wakeStillRespectsPerTokenFloor() {
        // Activity resuming before the per-token floor can't force an early poll.
        let lanes = [Lane(lastPolledAt: t0, account: .primary)]
        #expect(sched.decide(lanes: lanes, lastActivityAt: at(200), now: at(200)) == .wait(seconds: 100))
    }
}
