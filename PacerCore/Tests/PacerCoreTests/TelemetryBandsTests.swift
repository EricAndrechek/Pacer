import Testing
@testable import PacerCore

@Suite struct TelemetryBandsTests {

    @Test func percentBandsAreTenPointsAndClamped() {
        #expect(TelemetryBands.percentBand(0) == 0)
        #expect(TelemetryBands.percentBand(9.9) == 0)
        #expect(TelemetryBands.percentBand(10) == 10)
        #expect(TelemetryBands.percentBand(87.4) == 80)
        #expect(TelemetryBands.percentBand(100) == 100)
        #expect(TelemetryBands.percentBand(140) == 100)
        #expect(TelemetryBands.percentBand(-5) == 0)
        #expect(TelemetryBands.percentBand(.nan) == 0)
    }

    @Test func powerOfTwoBuckets() {
        #expect(TelemetryBands.powerOfTwoBucket(0) == 0)
        #expect(TelemetryBands.powerOfTwoBucket(0.2) == 1)
        #expect(TelemetryBands.powerOfTwoBucket(1) == 1)
        #expect(TelemetryBands.powerOfTwoBucket(3) == 4)
        #expect(TelemetryBands.powerOfTwoBucket(300) == 512)
        #expect(TelemetryBands.megabytesBucket(bytes: 5 * 1_048_576) == 8)
        #expect(TelemetryBands.gigabytesBucket(bytes: 100 * 1_073_741_824) == 128)
    }

    @Test func magnitudeIsOrderOfTen() {
        #expect(TelemetryBands.magnitude(0) == "0")
        #expect(TelemetryBands.magnitude(7) == "e0")
        #expect(TelemetryBands.magnitude(10) == "e1")
        #expect(TelemetryBands.magnitude(999_999) == "e5")
        #expect(TelemetryBands.magnitude(1_000_000) == "e6")
    }

    @Test func countBuckets() {
        #expect(TelemetryBands.countBucket(0) == 0)
        #expect(TelemetryBands.countBucket(7) == 7)
        #expect(TelemetryBands.countBucket(11) == 20)
        #expect(TelemetryBands.countBucket(1_701) == 2_000)
    }

    @Test func thinningKeepsOrderAndBound() {
        let values = Array(0..<1000)
        let out = TelemetryBands.thinned(values, limit: 500)
        #expect(out.count == 500)
        #expect(out == out.sorted())
        #expect(TelemetryBands.thinned([1, 2, 3], limit: 500) == [1, 2, 3])
        #expect(TelemetryBands.thinned([1, 2, 3], limit: 0).isEmpty)
    }
}
