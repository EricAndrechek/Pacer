import Foundation
import Testing
@testable import PacerCore

/// `BurnRate` is now just the warning contract (the projection math lives in
/// the intelligence engine); these tests pin the warning decision.
@Suite("BurnRate warning decision")
struct BurnRateTests {

    private func projection(hit: Bool) -> BurnRate.Projection {
        BurnRate.Projection(
            slopePercentPerHour: 8,
            projectedFullAt: hit ? Date().addingTimeInterval(3600) : nil,
            etaSeconds: hit ? 3600 : nil
        )
    }

    @Test func warnsOnlyWhenHitProjectedAndPastFloor() {
        // Projected hit + past the floor → warn.
        #expect(BurnRate.warrantsWarning(projection(hit: true), usedPct: 65))
        // Projected hit but still early in the window → no warning (a brief
        // burst at 15% almost always flattens out).
        #expect(!BurnRate.warrantsWarning(projection(hit: true), usedPct: 15))
        // No projected hit → never warn, however full the window is.
        #expect(!BurnRate.warrantsWarning(projection(hit: false), usedPct: 95))
    }

    @Test func floorBoundaryIsInclusive() {
        #expect(BurnRate.warrantsWarning(projection(hit: true), usedPct: BurnRate.warningUsedFloor))
        #expect(!BurnRate.warrantsWarning(projection(hit: true), usedPct: BurnRate.warningUsedFloor - 0.1))
    }

    @Test func willHitMirrorsProjectedFullAt() {
        #expect(projection(hit: true).willHitLimitBeforeReset)
        #expect(!projection(hit: false).willHitLimitBeforeReset)
    }
}
