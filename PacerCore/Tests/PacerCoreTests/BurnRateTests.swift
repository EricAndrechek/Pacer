import Foundation
import Testing
@testable import PacerCore

@Suite("BurnRate.project")
struct BurnRateTests {

    private func sample(at offsetMin: Double, pct: Double, from origin: Date) -> BurnRate.Sample {
        BurnRate.Sample(
            sampledAt: origin.addingTimeInterval(offsetMin * 60),
            usedPercentage: pct
        )
    }

    @Test func returnsNilWithTooFewSamples() {
        let now = Date()
        let result = BurnRate.project(
            samples: [
                BurnRate.Sample(sampledAt: now.addingTimeInterval(-3600), usedPercentage: 10),
                BurnRate.Sample(sampledAt: now.addingTimeInterval(-1800), usedPercentage: 20),
            ],
            resetsAt: nil,
            parameters: BurnRate.Parameters(minSamples: 3, now: now)
        )
        #expect(result == nil)
    }

    @Test func returnsNilWhenSpanTooShort() {
        let now = Date()
        let samples = (0..<5).map { i in
            sample(at: -Double(i) * 0.5, pct: 10 + Double(i) * 2, from: now)
        }
        // Span = 2 minutes; minWindow = 5 minutes → reject.
        let result = BurnRate.project(
            samples: samples,
            resetsAt: nil,
            parameters: BurnRate.Parameters(now: now)
        )
        #expect(result == nil)
    }

    @Test func returnsSlopeButNoProjectionWhenDecreasing() throws {
        let now = Date()
        // 30% → 20% → 10% over 30 minutes; slope is negative.
        let samples = [
            sample(at: -30, pct: 30, from: now),
            sample(at: -15, pct: 20, from: now),
            sample(at: 0, pct: 10, from: now),
        ]
        let result = try #require(BurnRate.project(
            samples: samples,
            resetsAt: nil,
            parameters: BurnRate.Parameters(now: now)
        ))
        #expect(result.slopePercentPerHour < 0)
        #expect(result.projectedFullAt == nil)
        #expect(result.willHitLimitBeforeReset == false)
    }

    @Test func projectsFullAtCorrectTimeWithLinearSlope() throws {
        let now = Date()
        // 20% → 30% over 30 minutes = 20%/hr. 70% remaining → 3.5h.
        let samples = [
            sample(at: -30, pct: 20, from: now),
            sample(at: -15, pct: 25, from: now),
            sample(at: 0, pct: 30, from: now),
        ]
        // Reset is 5h away — projection lands well before, so it sticks.
        let resetsAt = now.addingTimeInterval(5 * 3600)
        let result = try #require(BurnRate.project(
            samples: samples,
            resetsAt: resetsAt,
            parameters: BurnRate.Parameters(now: now)
        ))
        // 20%/hr
        #expect(abs(result.slopePercentPerHour - 20) < 0.01)
        let etaSeconds = try #require(result.etaSeconds)
        // 70% / 20%/hr = 3.5 hours = 12,600s
        #expect(abs(etaSeconds - 12_600) < 1.0)
        #expect(result.willHitLimitBeforeReset)
    }

    @Test func suppressesProjectionWhenResetComesFirst() throws {
        let now = Date()
        // 10%/hr; 80% remaining → 8 hours projected. But reset is in 4h.
        let samples = [
            sample(at: -60, pct: 10, from: now),
            sample(at: -30, pct: 15, from: now),
            sample(at: 0, pct: 20, from: now),
        ]
        let resetsAt = now.addingTimeInterval(4 * 3600)
        let result = try #require(BurnRate.project(
            samples: samples,
            resetsAt: resetsAt,
            parameters: BurnRate.Parameters(now: now)
        ))
        #expect(result.slopePercentPerHour > 0)
        #expect(result.projectedFullAt == nil)
        #expect(result.willHitLimitBeforeReset == false)
    }

    @Test func ignoresSamplesOlderThanLookback() throws {
        let now = Date()
        // 8h-old samples (outside default lookback) plus a fresh
        // 3-sample series. The old ones must not skew the slope.
        let mixed: [BurnRate.Sample] = [
            sample(at: -480, pct: 95, from: now),   // 8h ago — excluded
            sample(at: -465, pct: 0,  from: now),   // 7.75h ago — excluded
            sample(at: -60, pct: 30,  from: now),
            sample(at: -30, pct: 35,  from: now),
            sample(at: 0,   pct: 40,  from: now),
        ]
        let result = try #require(BurnRate.project(
            samples: mixed,
            resetsAt: now.addingTimeInterval(5 * 3600),
            parameters: BurnRate.Parameters(now: now)
        ))
        // 10% over 1h → 10%/hr; the old outliers would otherwise
        // produce a wildly different slope.
        #expect(abs(result.slopePercentPerHour - 10) < 0.1)
    }

    @Test func unorderedInputIsHandled() throws {
        let now = Date()
        // Same data as projectsFullAtCorrectTimeWithLinearSlope but
        // shuffled — verify the internal sort works.
        let shuffled = [
            sample(at: 0, pct: 30, from: now),
            sample(at: -30, pct: 20, from: now),
            sample(at: -15, pct: 25, from: now),
        ]
        let result = try #require(BurnRate.project(
            samples: shuffled,
            resetsAt: now.addingTimeInterval(5 * 3600),
            parameters: BurnRate.Parameters(now: now)
        ))
        #expect(abs(result.slopePercentPerHour - 20) < 0.01)
    }

    @Test func at100PercentReturnsSlopeButNoEta() throws {
        let now = Date()
        let samples = [
            sample(at: -30, pct: 95, from: now),
            sample(at: -15, pct: 98, from: now),
            sample(at: 0, pct: 100, from: now),
        ]
        let result = try #require(BurnRate.project(
            samples: samples,
            resetsAt: now.addingTimeInterval(3600),
            parameters: BurnRate.Parameters(now: now)
        ))
        #expect(result.slopePercentPerHour > 0)
        #expect(result.projectedFullAt == nil)
    }

    // MARK: - warrantsWarning

    /// Build a projection that hits the limit before reset (or not) without
    /// going through `project` — `warrantsWarning` only reads the two fields.
    private func projection(hitsBeforeReset: Bool) -> BurnRate.Projection {
        BurnRate.Projection(
            slopePercentPerHour: 10,
            projectedFullAt: hitsBeforeReset ? Date() : nil,
            etaSeconds: hitsBeforeReset ? 3600 : nil
        )
    }

    @Test func warnsWhenHittingLimitAndPastFloor() {
        #expect(BurnRate.warrantsWarning(projection(hitsBeforeReset: true), usedPct: 60) == true)
    }

    @Test func doesNotWarnBelowFloorEvenIfHitting() {
        // Steep early-window slope, but only 30% used — suppress as noise.
        #expect(BurnRate.warrantsWarning(projection(hitsBeforeReset: true), usedPct: 30) == false)
    }

    @Test func doesNotWarnWhenResetComesFirst() {
        // High usage but the window resets before the projection lands.
        #expect(BurnRate.warrantsWarning(projection(hitsBeforeReset: false), usedPct: 90) == false)
    }

    @Test func warnsExactlyAtFloor() {
        #expect(BurnRate.warrantsWarning(projection(hitsBeforeReset: true), usedPct: 50) == true)
    }
}
