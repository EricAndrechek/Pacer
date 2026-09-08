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

    /// An announced poll that has already passed says nothing about the future
    /// and must not pin the lane forever.
    @Test("a stale external time is ignored")
    func staleExternalIgnored() {
        let d = decide(.init(lastPolledAt: now.addingTimeInterval(-floor),
                             externalNextPollAt: now.addingTimeInterval(-60),
                             account: .primary))
        #expect(d == .poll(laneIndex: 0))
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
