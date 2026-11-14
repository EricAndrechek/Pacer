import Foundation
import Testing
@testable import PacerCore

@Suite("Snapshot build spacing")
struct PacerSnapshotSpacingTests {
    /// Awake seconds, as `PacerSnapshotSpacing.awakeNow()` gives them.
    private let t0: TimeInterval = 1_000_000

    @Test func firstBuildStartsAtOnce() {
        #expect(PacerSnapshotSpacing().delay(now: t0) == 0)
    }

    @Test func quickBuildKeepsTheTwoSecondRest() {
        var s = PacerSnapshotSpacing()
        s.buildFinished(startedAt: t0, endedAt: t0 + 0.3)
        let end = t0 + 0.3
        #expect(s.delay(now: end) == 2)
        #expect(abs(s.delay(now: end + 0.5) - 1.5) < 1e-9)
        #expect(s.delay(now: end + 2) == 0)
    }

    @Test func slowBuildRestsThreeTimesItsLength() {
        var s = PacerSnapshotSpacing()
        s.buildFinished(startedAt: t0, endedAt: t0 + 12)
        let end = t0 + 12
        // The old rule (2 s after the start) would have said 0 here.
        #expect(s.delay(now: end) == 36)
        #expect(abs(s.delay(now: end + 30) - 6) < 1e-9)
        #expect(s.delay(now: end + 36) == 0)
    }

    /// A build the Mac slept through measured the night on the wall clock:
    /// 8 h became a 24 h rest. The awake clock does not see the sleep, and
    /// whatever a build measures, the rest stops at the cap.
    @Test func restNeverExceedsTheCap() {
        for duration: TimeInterval in [20, 36, 8 * 3600, 30 * 86_400] {
            var s = PacerSnapshotSpacing()
            s.buildFinished(startedAt: t0, endedAt: t0 + duration)
            #expect(s.delay(now: t0 + duration) == PacerSnapshotSpacing.maximumRest,
                    "a \(duration) s build")
            #expect(s.delay(now: t0 + duration + PacerSnapshotSpacing.maximumRest) == 0)
        }
        #expect(PacerSnapshotSpacing.rest(afterBuildOf: .greatestFiniteMagnitude)
                == PacerSnapshotSpacing.maximumRest)
    }

    @Test func aClockBeforeTheLastEndWaitsNoLongerThanTheRest() {
        var s = PacerSnapshotSpacing()
        s.buildFinished(startedAt: t0, endedAt: t0 + 1)
        #expect(s.delay(now: t0 - 3600) == 3)
    }

    @Test func awakeClockMovesForward() {
        let a = PacerSnapshotSpacing.awakeNow()
        let b = PacerSnapshotSpacing.awakeNow()
        #expect(a > 0)
        #expect(b >= a)
    }

    @Test func spacingFollowsTheLatestBuild() {
        var s = PacerSnapshotSpacing()
        s.buildFinished(startedAt: t0, endedAt: t0 + 30)
        let next = t0 + 200
        s.buildFinished(startedAt: next, endedAt: next + 0.5)
        #expect(s.delay(now: next + 0.5) == 2)
    }

    @Test func scanRequestsBuildOnlyWhenPressureIsNormal() {
        #expect(PacerSnapshotSpacing.scanRequestMayBuild(pressure: .normal))
        #expect(!PacerSnapshotSpacing.scanRequestMayBuild(pressure: .warning))
        #expect(!PacerSnapshotSpacing.scanRequestMayBuild(pressure: .critical))
    }
}
