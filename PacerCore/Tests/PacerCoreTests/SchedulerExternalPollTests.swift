import Foundation
import Testing
@testable import PacerCore

/// Anthropic budgets the usage endpoint per *token*, and Pacer is not the only
/// client holding these — `cswap` polls the same credentials. Two clients each
/// respecting `perTokenMinInterval` on their own still land requests seconds
/// apart and both take 429s. `externalNextPollAt` is how the scheduler is told
/// about the other one.
///
/// These test the property that matters — spacing on the token — rather than a
/// particular cadence, because the cadence is supposed to fall out of the
/// scheduler's existing logic (lane count, backoff) and not be dictated.
@Suite("Scheduling around another client on the same token")
struct SchedulerExternalPollTests {

    private let floor: TimeInterval = 300
    private var tuning: OAuthPollScheduler.Tuning {
        .init(perTokenMinInterval: floor, activeInterval: 0, idleInterval: 600,
              activeWindow: 900, minWait: 1)
    }
    private let now = Date(timeIntervalSince1970: 100_000)

    private func decide(_ lane: OAuthPollScheduler.LaneState) -> OAuthPollScheduler.Decision {
        OAuthPollScheduler(tuning: tuning)
            .decide(lanes: [lane], lastActivityAt: now, now: now)
    }

    /// Plenty of room before the other client goes: Pacer polls now, at its own
    /// floor. Knowing about cswap must not make Pacer *slower* when there is
    /// space.
    @Test("a distant external poll does not hold Pacer back")
    func roomInFront() {
        let d = decide(.init(lastPolledAt: now.addingTimeInterval(-floor),
                             externalNextPollAt: now.addingTimeInterval(floor * 3),
                             account: .primary))
        #expect(d == .poll(laneIndex: 0))
    }

    /// The other client goes in a minute. Polling now would put two requests on
    /// one token a minute apart, which is what was producing 429s from both.
    @Test("Pacer waits rather than crowding an imminent external poll")
    func crowdedByExternal() {
        let d = decide(.init(lastPolledAt: now.addingTimeInterval(-floor),
                             externalNextPollAt: now.addingTimeInterval(60),
                             account: .primary))
        guard case .wait(let seconds) = d else {
            Issue.record("expected a wait, got \(d)"); return
        }
        // Clear of the other request by a full interval.
        #expect(seconds >= 60 + floor - 1)
    }

    /// This test used to assert the opposite — that a past time is ignored —
    /// and that was wrong in the direction that matters. A client whose next
    /// poll is overdue is a client that keeps failing to make it, which is
    /// exactly when the token's budget should be left alone. Observed for
    /// real: cswap ran 24 minutes overdue taking 429 after 429 while Pacer,
    /// reading a stale timestamp as "nothing scheduled", kept polling.
    ///
    /// It cannot pin the lane forever: the moment cswap succeeds it publishes a
    /// fresh `nextPollAt` in the future, and the room reappears.
    @Test("an overdue external poll still holds Pacer off")
    func overdueExternalStillYields() {
        let d = decide(.init(lastPolledAt: now.addingTimeInterval(-floor),
                             externalNextPollAt: now.addingTimeInterval(-60),
                             account: .primary))
        guard case .wait = d else {
            Issue.record("polled over a client that is overdue and failing"); return
        }
    }

    /// Nothing else polling: unchanged behaviour, which is the common case for
    /// anyone not running a switcher.
    @Test("with no external client the decision is untouched")
    func noExternal() {
        #expect(decide(.init(lastPolledAt: now.addingTimeInterval(-floor), account: .primary))
                == .poll(laneIndex: 0))
    }

    /// The feature this must not undo: more tokens still means a faster
    /// cadence, external client or not.
    @Test("multi-token spreading survives")
    func multiTokenStillSpreads() {
        let lanes: [OAuthPollScheduler.LaneState] = (0..<5).map { i in
            .init(lastPolledAt: now.addingTimeInterval(-floor - Double(i)),
                  externalNextPollAt: now.addingTimeInterval(floor * 4),
                  account: .primary)
        }
        let d = OAuthPollScheduler(tuning: tuning)
            .decide(lanes: lanes, lastActivityAt: now, now: now)
        // Five tokens sustain a one-minute endpoint cadence; all are past
        // their own floor, so one is due now.
        #expect(d == .poll(laneIndex: 4))
    }
}

/// The overdue case, separated out because it is the one that inverts the
/// intent: when the other client is *behind*, it is failing, and that is when
/// it most needs the token's budget left alone.
@Suite("Yielding to a client that has fallen behind")
struct SchedulerOverdueExternalTests {

    private let floor: TimeInterval = 300
    private let now = Date(timeIntervalSince1970: 200_000)

    private func decide(externalNextPollAt: Date?) -> OAuthPollScheduler.Decision {
        OAuthPollScheduler(tuning: .init(
            perTokenMinInterval: floor, activeInterval: 0, idleInterval: 600,
            activeWindow: 900, minWait: 1)
        ).decide(
            lanes: [.init(lastPolledAt: now.addingTimeInterval(-floor),
                          externalNextPollAt: externalNextPollAt, account: .primary)],
            lastActivityAt: now, now: now)
    }

    @Test("an overdue external poll is treated as imminent, not as absent")
    func overdueYields() {
        guard case .wait = decide(externalNextPollAt: now.addingTimeInterval(-1400)) else {
            Issue.record("polled over a client that is overdue and failing"); return
        }
    }

    @Test("a future external poll with room still lets Pacer through")
    func futureWithRoomStillPolls() {
        #expect(decide(externalNextPollAt: now.addingTimeInterval(floor * 3))
                == .poll(laneIndex: 0))
    }
}

/// The bound on standing aside.
///
/// Deferring to cswap is right while it works — its answer is on disk and costs
/// none of the token's budget. But it cannot be unconditional: both clients
/// spent fifty minutes locked out of the same token, cswap retrying and
/// failing, and an unbounded yield would have left Pacer's own reading aging
/// with no way back. The floor guarantees a poll of Pacer's own eventually.
@Suite("Never yielding forever")
struct SchedulerProbeFloorTests {

    private let floor: TimeInterval = 300
    private let yieldMax: TimeInterval = 900
    private let now = Date(timeIntervalSince1970: 500_000)

    private func decide(_ lane: OAuthPollScheduler.LaneState) -> OAuthPollScheduler.Decision {
        OAuthPollScheduler(tuning: .init(
            perTokenMinInterval: floor, activeInterval: 0, idleInterval: 600,
            activeWindow: 900, minWait: 1, externalYieldMax: yieldMax)
        ).decide(lanes: [lane], lastActivityAt: now, now: now)
    }

    /// The state actually observed: cswap asking every couple of minutes,
    /// never succeeding, its next poll permanently overdue. Every external
    /// signal says "wait", and waiting forever is not an answer.
    @Test("a client that asks constantly and never succeeds cannot pin a lane")
    func probeFloorBreaksThePin() {
        #expect(decide(.init(lastPolledAt: now.addingTimeInterval(-yieldMax - 1),
                             externalNextPollAt: now.addingTimeInterval(-60),
                             externalLastPollAt: now.addingTimeInterval(-30),
                             account: .primary)) == .poll(laneIndex: 0))
    }

    /// Inside the floor the yield stands — this is the ordinary cooperative
    /// case and it must not be weakened by the escape hatch.
    @Test("inside the floor Pacer still stands aside")
    func insideTheFloorStillYields() {
        guard case .wait = decide(.init(lastPolledAt: now.addingTimeInterval(-floor),
                                        externalNextPollAt: now.addingTimeInterval(-60),
                                        externalLastPollAt: now.addingTimeInterval(-30),
                                        account: .primary)) else {
            Issue.record("stopped yielding well before the floor"); return
        }
    }

    /// A throttled token is not helped by asking again, so the floor overrides
    /// another client's schedule but never Pacer's own cooldown.
    @Test("the floor does not override a cooldown")
    func floorRespectsCooldown() {
        guard case .wait = decide(.init(lastPolledAt: now.addingTimeInterval(-yieldMax - 1),
                                        cooldownUntil: now.addingTimeInterval(600),
                                        externalNextPollAt: now.addingTimeInterval(-60),
                                        externalLastPollAt: now.addingTimeInterval(-30),
                                        account: .primary)) else {
            Issue.record("polled a lane that is still cooling from a 429"); return
        }
    }

    /// With nothing else on the token the floor is inert — it must not make a
    /// solo lane poll faster than the per-token invariant allows.
    @Test("with no other client the floor changes nothing")
    func inertWithoutAnExternalClient() {
        guard case .wait = decide(.init(lastPolledAt: now.addingTimeInterval(-floor + 30),
                                        account: .primary)) else {
            Issue.record("broke the per-token invariant on a lane nobody shares"); return
        }
    }

    /// Another client's requests count against the shared budget, which is the
    /// whole point: Pacer's own interval has elapsed, but the token was used
    /// thirty seconds ago by someone else.
    @Test("an external request holds the lane off even when Pacer's interval is up")
    func externalRequestCountsAgainstTheInterval() {
        guard case .wait = decide(.init(lastPolledAt: now.addingTimeInterval(-floor - 1),
                                        externalLastPollAt: now.addingTimeInterval(-30),
                                        account: .primary)) else {
            Issue.record("polled a token another client used thirty seconds ago"); return
        }
    }
}
