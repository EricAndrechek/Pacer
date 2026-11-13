import Foundation
import Testing
@testable import PacerCore

@Suite("Snapshot build spacing")
struct PacerSnapshotSpacingTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func firstBuildStartsAtOnce() {
        #expect(PacerSnapshotSpacing().delay(now: t0) == 0)
    }

    @Test func quickBuildKeepsTheTwoSecondRest() {
        var s = PacerSnapshotSpacing()
        s.buildFinished(startedAt: t0, endedAt: t0.addingTimeInterval(0.3))
        let end = t0.addingTimeInterval(0.3)
        #expect(s.delay(now: end) == 2)
        #expect(abs(s.delay(now: end.addingTimeInterval(0.5)) - 1.5) < 1e-9)
        #expect(s.delay(now: end.addingTimeInterval(2)) == 0)
    }

    @Test func slowBuildRestsThreeTimesItsLength() {
        var s = PacerSnapshotSpacing()
        s.buildFinished(startedAt: t0, endedAt: t0.addingTimeInterval(36))
        let end = t0.addingTimeInterval(36)
        // The old rule (2 s after the start) would have said 0 here.
        #expect(s.delay(now: end) == 108)
        #expect(abs(s.delay(now: end.addingTimeInterval(100)) - 8) < 1e-9)
        #expect(s.delay(now: end.addingTimeInterval(108)) == 0)
    }

    @Test func spacingFollowsTheLatestBuild() {
        var s = PacerSnapshotSpacing()
        s.buildFinished(startedAt: t0, endedAt: t0.addingTimeInterval(30))
        let next = t0.addingTimeInterval(200)
        s.buildFinished(startedAt: next, endedAt: next.addingTimeInterval(0.5))
        #expect(s.delay(now: next.addingTimeInterval(0.5)) == 2)
    }

    @Test func scanRequestsBuildOnlyWhenPressureIsNormal() {
        #expect(PacerSnapshotSpacing.scanRequestMayBuild(pressure: .normal))
        #expect(!PacerSnapshotSpacing.scanRequestMayBuild(pressure: .warning))
        #expect(!PacerSnapshotSpacing.scanRequestMayBuild(pressure: .critical))
    }
}
