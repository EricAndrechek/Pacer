import Foundation
import Testing
@testable import PacerCore

/// A rate-limit band never starts below the usage the meter already shows
/// (#273): the value at reset can't be lower than it is now.
@Suite("Rate-limit band floor")
struct RLBandClampTests {

    @Test func theBandStartsAtTheMeterNotAtZero() {
        let band = UsageIntelligenceEngine.clampPct(25...55, floor: 30)
        #expect(band == 30...55)
    }

    @Test func aBandWhollyBelowTheMeterCollapsesOntoIt() {
        #expect(UsageIntelligenceEngine.clampPct(10...20, floor: 30) == 30...30)
    }

    @Test func theCapStillBoundsTheTop() {
        #expect(UsageIntelligenceEngine.clampPct(80...140, floor: 30) == 80...100)
        #expect(UsageIntelligenceEngine.clampPct(80...140, floor: 120) == 100...100)
    }

    @Test func withoutAFloorItIsTheOldZeroToHundredClamp() {
        #expect(UsageIntelligenceEngine.clampPct(-5...105) == 0...100)
    }
}
